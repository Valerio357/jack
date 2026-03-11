/*
 * d3dkmt.c — D3DKMT escape interface implementation
 *
 * On Windows: loads gdi32.dll dynamically and uses D3DKMTEscape
 * to communicate with the JackGPU WDDM kernel driver.
 *
 * On other platforms: stub implementation for development/testing.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "transport/d3dkmt.h"

#ifdef _WIN32
/* ══════════════════════════════════════════════════════════════
 *  Windows implementation — D3DKMTEscape
 * ══════════════════════════════════════════════════════════════ */

#include <windows.h>

/* D3DKMT types (from d3dkmthk.h — we define them here to avoid WDK dependency) */
typedef UINT D3DKMT_HANDLE;

typedef struct _D3DKMT_ENUMADAPTERS2 {
    ULONG          NumAdapters;
    void          *pAdapters;   /* D3DKMT_ADAPTERINFO* */
} D3DKMT_ENUMADAPTERS2;

typedef struct _D3DKMT_ADAPTERINFO {
    D3DKMT_HANDLE  hAdapter;
    LUID           AdapterLuid;
    ULONG          NumOfSources;
    BOOL           bPrecisePresentRegionsPreferred;
} D3DKMT_ADAPTERINFO;

typedef struct _D3DKMT_ESCAPE {
    D3DKMT_HANDLE  hAdapter;
    D3DKMT_HANDLE  hDevice;
    UINT           Type;          /* D3DKMT_ESCAPE_DRIVERPRIVATE = 0 */
    UINT           Flags;
    void          *pPrivateDriverData;
    UINT           PrivateDriverDataSize;
    D3DKMT_HANDLE  hContext;
} D3DKMT_ESCAPE;

/* D3DKMT function pointers */
typedef LONG (WINAPI *PFN_D3DKMTEnumAdapters2)(D3DKMT_ENUMADAPTERS2 *);
typedef LONG (WINAPI *PFN_D3DKMTEscape)(D3DKMT_ESCAPE *);

static HMODULE s_gdi32 = NULL;
static PFN_D3DKMTEnumAdapters2 s_pfnEnumAdapters2 = NULL;
static PFN_D3DKMTEscape s_pfnEscape = NULL;

static VkResult load_d3dkmt(void) {
    if (s_gdi32) return VK_SUCCESS;

    s_gdi32 = LoadLibraryA("gdi32.dll");
    if (!s_gdi32) {
        JACKGPU_ERR("failed to load gdi32.dll");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    s_pfnEnumAdapters2 = (PFN_D3DKMTEnumAdapters2)
        GetProcAddress(s_gdi32, "D3DKMTEnumAdapters2");
    s_pfnEscape = (PFN_D3DKMTEscape)
        GetProcAddress(s_gdi32, "D3DKMTEscape");

    if (!s_pfnEnumAdapters2 || !s_pfnEscape) {
        JACKGPU_ERR("failed to get D3DKMT function pointers");
        FreeLibrary(s_gdi32);
        s_gdi32 = NULL;
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    return VK_SUCCESS;
}

/* Send escape command to kernel driver */
static VkResult send_escape(jackgpu_transport *tp, void *data, size_t size) {
    D3DKMT_ESCAPE escape = {0};
    escape.hAdapter = (D3DKMT_HANDLE)tp->device_handle;
    escape.Type = 0; /* D3DKMT_ESCAPE_DRIVERPRIVATE */
    escape.Flags = 1; /* HardwareAccess */
    escape.pPrivateDriverData = data;
    escape.PrivateDriverDataSize = (UINT)size;

    LONG status = s_pfnEscape(&escape);
    if (status != 0) {
        JACKGPU_ERR("D3DKMTEscape failed: 0x%lx", status);
        return VK_ERROR_DEVICE_LOST;
    }

    struct jackgpu_escape_header *hdr = (struct jackgpu_escape_header *)data;
    if (hdr->result != 0) {
        JACKGPU_ERR("escape command %u failed: %d", hdr->cmd, hdr->result);
        return VK_ERROR_DEVICE_LOST;
    }

    return VK_SUCCESS;
}

VkResult jackgpu_d3dkmt_open_device(jackgpu_transport *tp) {
    VkResult result = load_d3dkmt();
    if (result != VK_SUCCESS) return result;

    /* Enumerate adapters to find our virtio-gpu device */
    D3DKMT_ENUMADAPTERS2 enum_adapters = {0};

    /* First call: get count */
    s_pfnEnumAdapters2(&enum_adapters);
    if (enum_adapters.NumAdapters == 0) {
        JACKGPU_ERR("no display adapters found");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    D3DKMT_ADAPTERINFO *adapters = (D3DKMT_ADAPTERINFO *)
        calloc(enum_adapters.NumAdapters, sizeof(D3DKMT_ADAPTERINFO));
    enum_adapters.pAdapters = adapters;

    LONG status = s_pfnEnumAdapters2(&enum_adapters);
    if (status != 0) {
        free(adapters);
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    /* TODO: identify JackGPU adapter by vendor ID or driver name.
     * For now, use the first adapter. */
    tp->device_handle = (uint64_t)adapters[0].hAdapter;

    JACKGPU_LOG("opened adapter handle: 0x%llx", tp->device_handle);
    free(adapters);
    return VK_SUCCESS;
}

void jackgpu_d3dkmt_close_device(jackgpu_transport *tp) {
    tp->device_handle = 0;
}

VkResult jackgpu_d3dkmt_create_context(jackgpu_transport *tp, uint32_t capset_id) {
    struct jackgpu_escape_create_context cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_CREATE_CONTEXT;
    cmd.hdr.size = sizeof(cmd);
    cmd.capset_id = capset_id;
    cmd.num_rings = 64;

    VkResult result = send_escape(tp, &cmd, sizeof(cmd));
    if (result == VK_SUCCESS) {
        tp->context_id = cmd.context_id;
        JACKGPU_LOG("created Venus context: %u", tp->context_id);
    }
    return result;
}

void jackgpu_d3dkmt_destroy_context(jackgpu_transport *tp) {
    struct jackgpu_escape_header cmd = {0};
    cmd.cmd = JACKGPU_ESCAPE_DESTROY_CONTEXT;
    cmd.size = sizeof(cmd);
    send_escape(tp, &cmd, sizeof(cmd));
    tp->context_id = 0;
}

VkResult jackgpu_d3dkmt_get_capset(jackgpu_transport *tp, uint32_t capset_id,
                                    void *data, size_t size) {
    size_t total = sizeof(struct jackgpu_escape_capset) + size;
    uint8_t *buf = (uint8_t *)calloc(1, total);

    struct jackgpu_escape_capset *cmd = (struct jackgpu_escape_capset *)buf;
    cmd->hdr.cmd = JACKGPU_ESCAPE_GET_CAPSET;
    cmd->hdr.size = (uint32_t)total;
    cmd->capset_id = capset_id;
    cmd->capset_size = (uint32_t)size;

    VkResult result = send_escape(tp, buf, total);
    if (result == VK_SUCCESS) {
        memcpy(data, buf + sizeof(struct jackgpu_escape_capset), size);
    }

    free(buf);
    return result;
}

VkResult jackgpu_d3dkmt_create_blob(jackgpu_transport *tp,
                                     struct jackgpu_blob *blob,
                                     uint32_t blob_mem, uint32_t blob_flags) {
    struct jackgpu_escape_create_blob_params cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_CREATE_BLOB;
    cmd.hdr.size = sizeof(cmd);
    cmd.blob_mem = blob_mem;
    cmd.blob_flags = blob_flags;
    cmd.size = (uint64_t)blob->size;
    cmd.blob_id = blob->blob_id;

    VkResult result = send_escape(tp, &cmd, sizeof(cmd));
    if (result == VK_SUCCESS) {
        blob->handle = cmd.handle;
    }
    return result;
}

VkResult jackgpu_d3dkmt_map_blob(jackgpu_transport *tp,
                                  struct jackgpu_blob *blob) {
    struct jackgpu_escape_map_blob_params cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_MAP_BLOB;
    cmd.hdr.size = sizeof(cmd);
    cmd.handle = blob->handle;

    VkResult result = send_escape(tp, &cmd, sizeof(cmd));
    if (result == VK_SUCCESS) {
        blob->mapped = (void *)(uintptr_t)cmd.mapped_addr;
    }
    return result;
}

void jackgpu_d3dkmt_unmap_blob(jackgpu_transport *tp,
                                struct jackgpu_blob *blob) {
    struct jackgpu_escape_map_blob_params cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_UNMAP_BLOB;
    cmd.hdr.size = sizeof(cmd);
    cmd.handle = blob->handle;
    send_escape(tp, &cmd, sizeof(cmd));
    blob->mapped = NULL;
}

void jackgpu_d3dkmt_destroy_resource(jackgpu_transport *tp, uint32_t handle) {
    struct {
        struct jackgpu_escape_header hdr;
        uint32_t handle;
    } cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_DESTROY_RESOURCE;
    cmd.hdr.size = sizeof(cmd);
    cmd.handle = handle;
    send_escape(tp, &cmd, sizeof(cmd));
}

VkResult jackgpu_d3dkmt_execbuffer(jackgpu_transport *tp,
                                    const void *data, size_t size,
                                    uint32_t ring_idx) {
    size_t total = sizeof(struct jackgpu_escape_execbuffer_params) + size;
    uint8_t *buf = (uint8_t *)calloc(1, total);

    struct jackgpu_escape_execbuffer_params *cmd =
        (struct jackgpu_escape_execbuffer_params *)buf;
    cmd->hdr.cmd = JACKGPU_ESCAPE_EXECBUFFER;
    cmd->hdr.size = (uint32_t)total;
    cmd->ring_idx = ring_idx;
    cmd->data_size = (uint32_t)size;
    memcpy(buf + sizeof(*cmd), data, size);

    VkResult result = send_escape(tp, buf, total);
    free(buf);
    return result;
}

VkResult jackgpu_d3dkmt_create_ring(jackgpu_transport *tp,
                                     struct jackgpu_blob *ring_blob,
                                     const struct jackgpu_ring_layout *layout) {
    struct {
        struct jackgpu_escape_header hdr;
        uint32_t blob_handle;
        uint32_t buffer_offset;
        uint32_t buffer_size;
        uint32_t head_offset;
        uint32_t tail_offset;
        uint32_t status_offset;
        uint32_t extra_offset;
        uint32_t extra_size;
    } cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_CREATE_RING;
    cmd.hdr.size = sizeof(cmd);
    cmd.blob_handle = ring_blob->handle;
    cmd.buffer_offset = (uint32_t)layout->buffer_offset;
    cmd.buffer_size = (uint32_t)layout->buffer_size;
    cmd.head_offset = (uint32_t)layout->head_offset;
    cmd.tail_offset = (uint32_t)layout->tail_offset;
    cmd.status_offset = (uint32_t)layout->status_offset;
    cmd.extra_offset = (uint32_t)layout->extra_offset;
    cmd.extra_size = (uint32_t)layout->extra_size;
    return send_escape(tp, &cmd, sizeof(cmd));
}

void jackgpu_d3dkmt_destroy_ring(jackgpu_transport *tp) {
    struct jackgpu_escape_header cmd = {0};
    cmd.cmd = JACKGPU_ESCAPE_DESTROY_RING;
    cmd.size = sizeof(cmd);
    send_escape(tp, &cmd, sizeof(cmd));
}

void jackgpu_d3dkmt_notify_ring(jackgpu_transport *tp) {
    struct jackgpu_escape_header cmd = {0};
    cmd.cmd = JACKGPU_ESCAPE_NOTIFY_RING;
    cmd.size = sizeof(cmd);
    send_escape(tp, &cmd, sizeof(cmd));
}

VkResult jackgpu_d3dkmt_set_reply_stream(jackgpu_transport *tp,
                                          struct jackgpu_blob *reply_blob) {
    struct {
        struct jackgpu_escape_header hdr;
        uint32_t blob_handle;
        uint64_t size;
    } cmd = {0};
    cmd.hdr.cmd = JACKGPU_ESCAPE_SET_REPLY_STREAM;
    cmd.hdr.size = sizeof(cmd);
    cmd.blob_handle = reply_blob->handle;
    cmd.size = (uint64_t)reply_blob->size;
    return send_escape(tp, &cmd, sizeof(cmd));
}

#else
/* ══════════════════════════════════════════════════════════════
 *  Stub implementation (macOS/Linux development)
 * ══════════════════════════════════════════════════════════════ */

VkResult jackgpu_d3dkmt_open_device(jackgpu_transport *tp) {
    JACKGPU_LOG("STUB: open_device");
    tp->device_handle = 1;
    return VK_SUCCESS;
}

void jackgpu_d3dkmt_close_device(jackgpu_transport *tp) {
    JACKGPU_LOG("STUB: close_device");
    tp->device_handle = 0;
}

VkResult jackgpu_d3dkmt_create_context(jackgpu_transport *tp, uint32_t capset_id) {
    JACKGPU_LOG("STUB: create_context capset=%u", capset_id);
    tp->context_id = 1;
    return VK_SUCCESS;
}

void jackgpu_d3dkmt_destroy_context(jackgpu_transport *tp) {
    JACKGPU_LOG("STUB: destroy_context");
    tp->context_id = 0;
}

VkResult jackgpu_d3dkmt_get_capset(jackgpu_transport *tp, uint32_t capset_id,
                                    void *data, size_t size) {
    JACKGPU_LOG("STUB: get_capset id=%u", capset_id);
    memset(data, 0, size);
    struct venus_capset *cap = (struct venus_capset *)data;
    cap->wire_format_version = 1;
    cap->vk_xml_version = VK_MAKE_API_VERSION(0, 1, 3, 0);
    return VK_SUCCESS;
}

VkResult jackgpu_d3dkmt_create_blob(jackgpu_transport *tp,
                                     struct jackgpu_blob *blob,
                                     uint32_t blob_mem, uint32_t blob_flags) {
    JACKGPU_LOG("STUB: create_blob size=%zu", blob->size);
    static uint32_t next_handle = 100;
    blob->handle = next_handle++;
    return VK_SUCCESS;
}

VkResult jackgpu_d3dkmt_map_blob(jackgpu_transport *tp,
                                  struct jackgpu_blob *blob) {
    JACKGPU_LOG("STUB: map_blob handle=%u size=%zu", blob->handle, blob->size);
    blob->mapped = calloc(1, blob->size);
    return blob->mapped ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY;
}

void jackgpu_d3dkmt_unmap_blob(jackgpu_transport *tp,
                                struct jackgpu_blob *blob) {
    JACKGPU_LOG("STUB: unmap_blob handle=%u", blob->handle);
    free(blob->mapped);
    blob->mapped = NULL;
}

void jackgpu_d3dkmt_destroy_resource(jackgpu_transport *tp, uint32_t handle) {
    JACKGPU_LOG("STUB: destroy_resource handle=%u", handle);
}

VkResult jackgpu_d3dkmt_execbuffer(jackgpu_transport *tp,
                                    const void *data, size_t size,
                                    uint32_t ring_idx) {
    JACKGPU_LOG("STUB: execbuffer size=%zu ring=%u", size, ring_idx);
    return VK_SUCCESS;
}

VkResult jackgpu_d3dkmt_create_ring(jackgpu_transport *tp,
                                     struct jackgpu_blob *ring_blob,
                                     const struct jackgpu_ring_layout *layout) {
    JACKGPU_LOG("STUB: create_ring");
    return VK_SUCCESS;
}

void jackgpu_d3dkmt_destroy_ring(jackgpu_transport *tp) {
    JACKGPU_LOG("STUB: destroy_ring");
}

void jackgpu_d3dkmt_notify_ring(jackgpu_transport *tp) {
    JACKGPU_LOG("STUB: notify_ring");
}

VkResult jackgpu_d3dkmt_set_reply_stream(jackgpu_transport *tp,
                                          struct jackgpu_blob *reply_blob) {
    JACKGPU_LOG("STUB: set_reply_stream");
    return VK_SUCCESS;
}

#endif /* _WIN32 */
