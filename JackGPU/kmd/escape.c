/*
 * escape.c — DxgkDdiEscape handler for JackGPU KMD
 *
 * Translates escape commands from the JackGPU ICD (userspace)
 * into virtio-gpu virtqueue commands to the host.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "jackgpu_kmd.h"

/* ── Bounce buffer helpers ───────────────────────────────────── */

/* Allocate physically contiguous memory for virtqueue I/O */
static PVOID alloc_bounce(SIZE_T size, PHYSICAL_ADDRESS *phys)
{
    PHYSICAL_ADDRESS low = {0}, high = {0};
    high.QuadPart = 0xFFFFFFFFFFFFFFFF;
    PHYSICAL_ADDRESS boundary = {0};

    PVOID buf = MmAllocateContiguousMemorySpecifyCache(
        size, low, high, boundary, MmNonCached);

    if (buf) {
        RtlZeroMemory(buf, size);
        if (phys) *phys = MmGetPhysicalAddress(buf);
    }
    return buf;
}

static void free_bounce(PVOID buf)
{
    if (buf) MmFreeContiguousMemory(buf);
}

/* ── Escape: GET_CAPSET ──────────────────────────────────────── */

static NTSTATUS escape_get_capset(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct jackgpu_escape_capset {
        struct jackgpu_escape_header hdr;
        UINT32 capset_id;
        UINT32 capset_size;
    } *esc = (struct jackgpu_escape_capset *)data;

    UINT32 capset_id = esc->capset_id;
    UINT32 capset_data_size = esc->capset_size;

    /* Build virtio-gpu GET_CAPSET command */
    struct virtio_gpu_cmd_get_capset cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = 0x0108; /* VIRTIO_GPU_CMD_GET_CAPSET */
    cmd.capset_id = capset_id;
    cmd.capset_version = 0;

    /* Response: header + capset data */
    SIZE_T resp_size = sizeof(struct virtio_gpu_ctrl_hdr) + capset_data_size;
    PVOID resp = alloc_bounce(resp_size, NULL);
    PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);

    if (!resp || !cmd_bounce) {
        free_bounce(resp);
        free_bounce(cmd_bounce);
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));

    NTSTATUS status = jackgpu_vq_send_command(
        ext, &ext->controlq, cmd_bounce, sizeof(cmd), resp, (UINT32)resp_size);

    if (NT_SUCCESS(status)) {
        /* Copy capset data back to userspace buffer */
        UINT8 *capset_out = (UINT8 *)data + sizeof(struct jackgpu_escape_capset);
        UINT8 *capset_resp = (UINT8 *)resp + sizeof(struct virtio_gpu_ctrl_hdr);
        UINT32 copy_size = capset_data_size;
        if (size - sizeof(struct jackgpu_escape_capset) < copy_size)
            copy_size = size - sizeof(struct jackgpu_escape_capset);

        __try {
            RtlCopyMemory(capset_out, capset_resp, copy_size);
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            status = STATUS_ACCESS_VIOLATION;
        }
        esc->hdr.result = 0;
    } else {
        esc->hdr.result = -1;
    }

    free_bounce(cmd_bounce);
    free_bounce(resp);
    return status;
}

/* ── Escape: CREATE_CONTEXT ──────────────────────────────────── */

static NTSTATUS escape_create_context(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 capset_id;
        UINT32 num_rings;
        UINT32 context_id;
    } *esc = data;

    /* Find a free context slot */
    UINT32 ctx_id = 0;
    for (UINT32 i = 0; i < 64; i++) {
        if (!ext->contexts[i].active) {
            ctx_id = ext->next_context_id++;
            ext->contexts[i].context_id = ctx_id;
            ext->contexts[i].capset_id = esc->capset_id;
            ext->contexts[i].num_rings = esc->num_rings;
            ext->contexts[i].active = TRUE;
            break;
        }
    }

    if (ctx_id == 0) {
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    /* Build virtio-gpu CTX_CREATE command */
    struct virtio_gpu_cmd_ctx_create cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = VIRTIO_GPU_CMD_CTX_CREATE;
    cmd.hdr.ctx_id = ctx_id;
    cmd.nlen = 7;
    cmd.context_init = esc->capset_id; /* capset_id as context_init for Venus */
    RtlCopyMemory(cmd.debug_name, "JackGPU", 7);

    struct virtio_gpu_ctrl_hdr resp;
    RtlZeroMemory(&resp, sizeof(resp));

    PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(resp), NULL);

    if (!cmd_bounce || !resp_bounce) {
        free_bounce(cmd_bounce);
        free_bounce(resp_bounce);
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));

    NTSTATUS status = jackgpu_vq_send_command(
        ext, &ext->controlq, cmd_bounce, sizeof(cmd), resp_bounce, sizeof(resp));

    if (NT_SUCCESS(status)) {
        esc->context_id = ctx_id;
        esc->hdr.result = 0;
        JACKGPU_KMD_LOG("created context %u (capset=%u)", ctx_id, esc->capset_id);
    } else {
        esc->hdr.result = -1;
    }

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);
    return status;
}

/* ── Escape: DESTROY_CONTEXT ─────────────────────────────────── */

static NTSTATUS escape_destroy_context(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct jackgpu_escape_header *esc = data;

    /* Find and deactivate context */
    /* TODO: context_id should be passed in the escape data */
    for (UINT32 i = 0; i < 64; i++) {
        if (ext->contexts[i].active) {
            struct virtio_gpu_ctrl_hdr cmd;
            RtlZeroMemory(&cmd, sizeof(cmd));
            cmd.type = VIRTIO_GPU_CMD_CTX_DESTROY;
            cmd.ctx_id = ext->contexts[i].context_id;

            struct virtio_gpu_ctrl_hdr resp;
            RtlZeroMemory(&resp, sizeof(resp));

            PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);
            PVOID resp_bounce = alloc_bounce(sizeof(resp), NULL);

            if (cmd_bounce && resp_bounce) {
                RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));
                jackgpu_vq_send_command(ext, &ext->controlq,
                    cmd_bounce, sizeof(cmd), resp_bounce, sizeof(resp));
            }

            free_bounce(cmd_bounce);
            free_bounce(resp_bounce);

            ext->contexts[i].active = FALSE;
            break;
        }
    }

    esc->result = 0;
    return STATUS_SUCCESS;
}

/* ── Escape: CREATE_BLOB ─────────────────────────────────────── */

static NTSTATUS escape_create_blob(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 blob_mem;
        UINT32 blob_flags;
        UINT64 size;
        UINT64 blob_id;
        UINT32 handle;
    } *esc = data;

    JACKGPU_RESOURCE *res = jackgpu_alloc_resource(ext);
    if (!res) {
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    res->size = esc->size;
    res->blob_id = esc->blob_id;
    res->blob_mem = esc->blob_mem;
    res->blob_flags = esc->blob_flags;

    /* Allocate backing memory (physically contiguous for DMA) */
    res->mapped_kernel = alloc_bounce((SIZE_T)esc->size, &res->phys);
    if (!res->mapped_kernel) {
        jackgpu_free_resource(ext, res);
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    /* Send RESOURCE_CREATE_BLOB to host */
    struct virtio_gpu_resource_create_blob cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB;
    cmd.resource_id = res->resource_id;
    cmd.blob_mem = esc->blob_mem;
    cmd.blob_flags = esc->blob_flags;
    cmd.blob_id = esc->blob_id;
    cmd.size = esc->size;
    cmd.nr_entries = 1; /* One physically contiguous region */

    /* For blob resources with backing, we need to attach the physical address.
     * This is done via scatter-gather entries following the command.
     * We build a combined buffer: command + sg entry */
    struct {
        struct virtio_gpu_resource_create_blob cmd;
        UINT64 addr;
        UINT32 length;
        UINT32 padding;
    } *cmd_with_sg;

    PVOID cmd_bounce = alloc_bounce(sizeof(*cmd_with_sg), NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(struct virtio_gpu_ctrl_hdr), NULL);

    if (!cmd_bounce || !resp_bounce) {
        free_bounce(cmd_bounce);
        free_bounce(resp_bounce);
        jackgpu_free_resource(ext, res);
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    cmd_with_sg = cmd_bounce;
    cmd_with_sg->cmd = cmd;
    cmd_with_sg->addr = res->phys.QuadPart;
    cmd_with_sg->length = (UINT32)esc->size;
    cmd_with_sg->padding = 0;

    NTSTATUS status = jackgpu_vq_send_command(
        ext, &ext->controlq, cmd_bounce, sizeof(*cmd_with_sg),
        resp_bounce, sizeof(struct virtio_gpu_ctrl_hdr));

    if (NT_SUCCESS(status)) {
        esc->handle = res->resource_id;
        esc->hdr.result = 0;
        JACKGPU_KMD_LOG("created blob resource %u, size=%llu",
                        res->resource_id, esc->size);
    } else {
        jackgpu_free_resource(ext, res);
        esc->hdr.result = -1;
    }

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);
    return status;
}

/* ── Escape: MAP_BLOB ────────────────────────────────────────── */

static NTSTATUS escape_map_blob(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 handle;
        UINT64 mapped_addr;
    } *esc = data;

    JACKGPU_RESOURCE *res = jackgpu_find_resource(ext, esc->handle);
    if (!res || !res->mapped_kernel) {
        esc->hdr.result = -1;
        return STATUS_NOT_FOUND;
    }

    /* Create MDL and map into user address space */
    res->mdl = IoAllocateMdl(res->mapped_kernel, (ULONG)res->size, FALSE, FALSE, NULL);
    if (!res->mdl) {
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    MmBuildMdlForNonPagedPool(res->mdl);

    __try {
        res->mapped_user = MmMapLockedPagesSpecifyCache(
            res->mdl, UserMode, MmNonCached, NULL, FALSE, NormalPagePriority);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        IoFreeMdl(res->mdl);
        res->mdl = NULL;
        esc->hdr.result = -1;
        return STATUS_ACCESS_VIOLATION;
    }

    esc->mapped_addr = (UINT64)(ULONG_PTR)res->mapped_user;
    esc->hdr.result = 0;

    JACKGPU_KMD_LOG("mapped blob %u at user VA %p", esc->handle, res->mapped_user);
    return STATUS_SUCCESS;
}

/* ── Escape: UNMAP_BLOB ──────────────────────────────────────── */

static NTSTATUS escape_unmap_blob(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 handle;
    } *esc = data;

    JACKGPU_RESOURCE *res = jackgpu_find_resource(ext, esc->handle);
    if (!res) {
        esc->hdr.result = -1;
        return STATUS_NOT_FOUND;
    }

    if (res->mapped_user && res->mdl) {
        MmUnmapLockedPages(res->mapped_user, res->mdl);
        res->mapped_user = NULL;
    }
    if (res->mdl) {
        IoFreeMdl(res->mdl);
        res->mdl = NULL;
    }

    esc->hdr.result = 0;
    return STATUS_SUCCESS;
}

/* ── Escape: DESTROY_RESOURCE ────────────────────────────────── */

static NTSTATUS escape_destroy_resource(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 handle;
    } *esc = data;

    JACKGPU_RESOURCE *res = jackgpu_find_resource(ext, esc->handle);
    if (!res) {
        esc->hdr.result = -1;
        return STATUS_NOT_FOUND;
    }

    /* Send RESOURCE_UNREF to host */
    struct {
        struct virtio_gpu_ctrl_hdr hdr;
        UINT32 resource_id;
        UINT32 padding;
    } cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = VIRTIO_GPU_CMD_RESOURCE_UNREF;
    cmd.resource_id = res->resource_id;

    struct virtio_gpu_ctrl_hdr resp;
    RtlZeroMemory(&resp, sizeof(resp));

    PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(resp), NULL);

    if (cmd_bounce && resp_bounce) {
        RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));
        jackgpu_vq_send_command(ext, &ext->controlq,
            cmd_bounce, sizeof(cmd), resp_bounce, sizeof(resp));
    }

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);

    jackgpu_free_resource(ext, res);
    esc->hdr.result = 0;
    return STATUS_SUCCESS;
}

/* ── Escape: EXECBUFFER (submit 3D command) ──────────────────── */

static NTSTATUS escape_execbuffer(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 ring_idx;
        UINT32 data_size;
    } *esc = data;

    UINT32 cmd_data_size = esc->data_size;
    UINT8 *cmd_data = (UINT8 *)data + sizeof(*esc);

    /* Validate sizes */
    if (sizeof(*esc) + cmd_data_size > size) {
        esc->hdr.result = -1;
        return STATUS_INVALID_PARAMETER;
    }

    /* Build SUBMIT_3D command.
     * The command data is appended after the header. */
    SIZE_T submit_size = sizeof(struct virtio_gpu_cmd_submit_3d) + cmd_data_size;
    PVOID cmd_bounce = alloc_bounce(submit_size, NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(struct virtio_gpu_ctrl_hdr), NULL);

    if (!cmd_bounce || !resp_bounce) {
        free_bounce(cmd_bounce);
        free_bounce(resp_bounce);
        esc->hdr.result = -1;
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    struct virtio_gpu_cmd_submit_3d *submit = cmd_bounce;
    RtlZeroMemory(submit, sizeof(*submit));
    submit->hdr.type = VIRTIO_GPU_CMD_SUBMIT_3D;
    submit->hdr.ring_idx = esc->ring_idx;
    submit->size = cmd_data_size;

    /* Find active context for ctx_id */
    for (UINT32 i = 0; i < 64; i++) {
        if (ext->contexts[i].active) {
            submit->hdr.ctx_id = ext->contexts[i].context_id;
            break;
        }
    }

    /* Copy Venus command data after submit header */
    __try {
        RtlCopyMemory((UINT8 *)cmd_bounce + sizeof(*submit), cmd_data, cmd_data_size);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        free_bounce(cmd_bounce);
        free_bounce(resp_bounce);
        esc->hdr.result = -1;
        return STATUS_ACCESS_VIOLATION;
    }

    NTSTATUS status = jackgpu_vq_send_command(
        ext, &ext->controlq, cmd_bounce, (UINT32)submit_size,
        resp_bounce, sizeof(struct virtio_gpu_ctrl_hdr));

    esc->hdr.result = NT_SUCCESS(status) ? 0 : -1;

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);
    return status;
}

/* ── Escape: CREATE_RING ─────────────────────────────────────── */

static NTSTATUS escape_create_ring(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 blob_handle;
        UINT32 buffer_offset;
        UINT32 buffer_size;
        UINT32 head_offset;
        UINT32 tail_offset;
        UINT32 status_offset;
        UINT32 extra_offset;
        UINT32 extra_size;
    } *esc = data;

    JACKGPU_RESOURCE *res = jackgpu_find_resource(ext, esc->blob_handle);
    if (!res || !res->mapped_kernel) {
        esc->hdr.result = -1;
        return STATUS_NOT_FOUND;
    }

    /*
     * The ring blob is already created and mapped. The host side
     * needs to know the ring layout so it can consume commands.
     * This is done by attaching the resource to the context and
     * submitting a Venus ring creation command.
     *
     * For now, attach the blob resource to the active context.
     */
    struct {
        struct virtio_gpu_ctrl_hdr hdr;
        UINT32 resource_id;
        UINT32 padding;
    } cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE;
    cmd.resource_id = res->resource_id;

    /* Use active context */
    for (UINT32 i = 0; i < 64; i++) {
        if (ext->contexts[i].active) {
            cmd.hdr.ctx_id = ext->contexts[i].context_id;
            break;
        }
    }

    struct virtio_gpu_ctrl_hdr resp;
    RtlZeroMemory(&resp, sizeof(resp));

    PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(resp), NULL);

    NTSTATUS status = STATUS_SUCCESS;
    if (cmd_bounce && resp_bounce) {
        RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));
        status = jackgpu_vq_send_command(ext, &ext->controlq,
            cmd_bounce, sizeof(cmd), resp_bounce, sizeof(resp));
    }

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);

    esc->hdr.result = NT_SUCCESS(status) ? 0 : -1;
    return status;
}

/* ── Escape: SET_REPLY_STREAM ────────────────────────────────── */

static NTSTATUS escape_set_reply_stream(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct {
        struct jackgpu_escape_header hdr;
        UINT32 blob_handle;
        UINT64 size;
    } *esc = data;

    JACKGPU_RESOURCE *res = jackgpu_find_resource(ext, esc->blob_handle);
    if (!res) {
        esc->hdr.result = -1;
        return STATUS_NOT_FOUND;
    }

    /* Attach reply blob to context */
    struct {
        struct virtio_gpu_ctrl_hdr hdr;
        UINT32 resource_id;
        UINT32 padding;
    } cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE;
    cmd.resource_id = res->resource_id;

    for (UINT32 i = 0; i < 64; i++) {
        if (ext->contexts[i].active) {
            cmd.hdr.ctx_id = ext->contexts[i].context_id;
            break;
        }
    }

    struct virtio_gpu_ctrl_hdr resp;
    RtlZeroMemory(&resp, sizeof(resp));

    PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(resp), NULL);

    NTSTATUS status = STATUS_SUCCESS;
    if (cmd_bounce && resp_bounce) {
        RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));
        status = jackgpu_vq_send_command(ext, &ext->controlq,
            cmd_bounce, sizeof(cmd), resp_bounce, sizeof(resp));
    }

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);

    esc->hdr.result = NT_SUCCESS(status) ? 0 : -1;
    return status;
}

/* ── Escape: NOTIFY_RING ─────────────────────────────────────── */

static NTSTATUS escape_notify_ring(
    PJACKGPU_DEVICE_EXTENSION ext,
    PVOID data, UINT32 size)
{
    struct jackgpu_escape_header *esc = data;

    /*
     * The ICD calls this when the host renderer was idle.
     * We need to kick the host to process the ring.
     * This is done via a SUBMIT_3D with zero-length data
     * (a "ping" to wake up the renderer).
     */
    struct virtio_gpu_cmd_submit_3d cmd;
    RtlZeroMemory(&cmd, sizeof(cmd));
    cmd.hdr.type = VIRTIO_GPU_CMD_SUBMIT_3D;
    cmd.size = 0; /* zero-length = just wake up */

    for (UINT32 i = 0; i < 64; i++) {
        if (ext->contexts[i].active) {
            cmd.hdr.ctx_id = ext->contexts[i].context_id;
            break;
        }
    }

    struct virtio_gpu_ctrl_hdr resp;
    RtlZeroMemory(&resp, sizeof(resp));

    PVOID cmd_bounce = alloc_bounce(sizeof(cmd), NULL);
    PVOID resp_bounce = alloc_bounce(sizeof(resp), NULL);

    if (cmd_bounce && resp_bounce) {
        RtlCopyMemory(cmd_bounce, &cmd, sizeof(cmd));
        jackgpu_vq_send_command(ext, &ext->controlq,
            cmd_bounce, sizeof(cmd), resp_bounce, sizeof(resp));
    }

    free_bounce(cmd_bounce);
    free_bounce(resp_bounce);

    esc->result = 0;
    return STATUS_SUCCESS;
}

/* ── DxgkDdiEscape — Main dispatch ───────────────────────────── */

NTSTATUS jackgpu_ddi_escape(
    _In_ PVOID MiniportDeviceContext,
    _In_ CONST DXGKARG_ESCAPE *pEscape)
{
    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)MiniportDeviceContext;

    if (!pEscape || !pEscape->pPrivateDriverData ||
        pEscape->PrivateDriverDataSize < sizeof(struct jackgpu_escape_header)) {
        return STATUS_INVALID_PARAMETER;
    }

    struct jackgpu_escape_header *hdr =
        (struct jackgpu_escape_header *)pEscape->pPrivateDriverData;
    UINT32 total_size = pEscape->PrivateDriverDataSize;

    JACKGPU_KMD_LOG("escape cmd=0x%02X size=%u", hdr->cmd, total_size);

    switch (hdr->cmd) {
    case JACKGPU_ESCAPE_GET_CAPSET:
        return escape_get_capset(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_CREATE_CONTEXT:
        return escape_create_context(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_DESTROY_CONTEXT:
        return escape_destroy_context(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_CREATE_BLOB:
        return escape_create_blob(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_MAP_BLOB:
        return escape_map_blob(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_UNMAP_BLOB:
        return escape_unmap_blob(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_DESTROY_RESOURCE:
        return escape_destroy_resource(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_EXECBUFFER:
        return escape_execbuffer(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_CREATE_RING:
        return escape_create_ring(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_DESTROY_RING:
        /* Just ack — ring cleanup happens on context destroy */
        hdr->result = 0;
        return STATUS_SUCCESS;

    case JACKGPU_ESCAPE_NOTIFY_RING:
        return escape_notify_ring(ext, pEscape->pPrivateDriverData, total_size);

    case JACKGPU_ESCAPE_SET_REPLY_STREAM:
        return escape_set_reply_stream(ext, pEscape->pPrivateDriverData, total_size);

    default:
        JACKGPU_KMD_ERR("unknown escape cmd: 0x%02X", hdr->cmd);
        hdr->result = -1;
        return STATUS_NOT_IMPLEMENTED;
    }
}
