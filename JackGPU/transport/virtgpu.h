/*
 * virtgpu.h — Virtio-GPU device communication
 *
 * Abstracts virtio-gpu device access from Windows userspace.
 * On Windows, uses D3DKMTEscape to communicate with our WDDM kernel driver.
 * On other platforms (dev/test), uses a stub or vtest socket.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_VIRTGPU_H
#define JACKGPU_VIRTGPU_H

#include "driver/jackgpu.h"
#include "transport/ring.h"

/* ── Virtio-GPU capset (Venus) ────────────────────────────── */

#define VIRTGPU_CAPSET_VENUS 5

/* Venus capability set — returned by host */
struct venus_capset {
    uint32_t wire_format_version;
    uint32_t vk_xml_version;
    uint32_t vk_ext_command_serialization_spec_version;
    uint32_t vk_mesa_venus_protocol_spec_version;

    /* Supported Vulkan extensions (bitfield) */
    uint32_t vk_extension_mask1[16];

    /* Feature flags */
    uint32_t supports_blob_id_0 : 1;
    uint32_t allow_vk_wait_syncs : 1;
    uint32_t supports_multiple_timelines : 1;
    uint32_t use_guest_vram : 1;
    uint32_t reserved_flags : 28;
};

/* ── Blob resource ────────────────────────────────────────── */

#define VIRTGPU_BLOB_MEM_GUEST       0x0001
#define VIRTGPU_BLOB_MEM_HOST3D      0x0002
#define VIRTGPU_BLOB_MEM_GUEST_VRAM  0x0004

#define VIRTGPU_BLOB_FLAG_MAPPABLE    0x0001
#define VIRTGPU_BLOB_FLAG_SHAREABLE   0x0002
#define VIRTGPU_BLOB_FLAG_CROSS_DEV   0x0004

struct jackgpu_blob {
    uint32_t handle;       /* Resource handle from kernel driver */
    void    *mapped;       /* Mapped guest address (NULL if not mapped) */
    size_t   size;         /* Blob size */
    uint64_t blob_id;      /* Host-side blob identifier */
};

/* ── Transport interface ──────────────────────────────────── */

struct jackgpu_transport {
    /* Device handle (D3DKMT adapter handle on Windows) */
    uint64_t device_handle;

    /* Venus capset from host */
    struct venus_capset capset;

    /* Ring buffer for Vulkan commands */
    jackgpu_ring ring;
    struct jackgpu_blob ring_blob;

    /* Reply shared memory */
    struct jackgpu_blob reply_blob;
    void *reply_shmem;
    size_t reply_size;

    /* Command scratch buffer */
    struct jackgpu_blob cmd_blob;
    void *cmd_shmem;
    size_t cmd_size;

    /* Object ID counter */
    uint64_t next_object_id;

    /* Context ID assigned by kernel driver */
    uint32_t context_id;
};

/* ── Transport API ────────────────────────────────────────── */

/* Open the virtio-gpu device and initialize Venus context */
VkResult jackgpu_transport_init(jackgpu_transport *tp);

/* Shutdown transport */
void jackgpu_transport_fini(jackgpu_transport *tp);

/* Get Venus capset */
VkResult jackgpu_transport_get_capset(jackgpu_transport *tp);

/* Create a blob resource (shared memory) */
VkResult jackgpu_transport_create_blob(jackgpu_transport *tp,
                                       struct jackgpu_blob *blob,
                                       uint32_t blob_mem,
                                       uint32_t blob_flags,
                                       size_t size,
                                       uint64_t blob_id);

/* Map a blob resource into guest address space */
VkResult jackgpu_transport_map_blob(jackgpu_transport *tp,
                                    struct jackgpu_blob *blob);

/* Unmap and destroy a blob resource */
void jackgpu_transport_destroy_blob(jackgpu_transport *tp,
                                    struct jackgpu_blob *blob);

/* Submit a command buffer to the host (execbuffer) */
VkResult jackgpu_transport_execbuffer(jackgpu_transport *tp,
                                      const void *data, size_t size,
                                      uint32_t ring_idx);

/* Submit command via ring and wait for reply */
VkResult jackgpu_transport_submit_cmd(jackgpu_transport *tp,
                                      const void *cmd, size_t cmd_size,
                                      void *reply, size_t reply_size);

/* Submit command via ring, no reply expected */
VkResult jackgpu_transport_submit_cmd_no_reply(jackgpu_transport *tp,
                                               const void *cmd, size_t cmd_size);

/* Notify host that ring has new data (when renderer is idle) */
void jackgpu_transport_notify_ring(jackgpu_transport *tp);

/* Allocate a new object ID */
static inline venus_object_id jackgpu_transport_alloc_id(jackgpu_transport *tp) {
    return ++tp->next_object_id;
}

#endif /* JACKGPU_VIRTGPU_H */
