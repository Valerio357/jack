/*
 * virtgpu.c — Virtio-GPU transport implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "transport/virtgpu.h"
#include "transport/d3dkmt.h"

/* Ring buffer sizes */
#define RING_BUFFER_SIZE    (128 * 1024)   /* 128 KB command ring */
#define RING_EXTRA_SIZE     (4 * 1024)     /* 4 KB extra region */
#define REPLY_SHMEM_SIZE    (1024 * 1024)  /* 1 MB reply buffer */
#define CMD_SHMEM_SIZE      (8 * 1024 * 1024) /* 8 MB command pool */

VkResult jackgpu_transport_init(jackgpu_transport *tp) {
    VkResult result;

    memset(tp, 0, sizeof(*tp));

    /* 1. Open virtio-gpu device via D3DKMT */
    result = jackgpu_d3dkmt_open_device(tp);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to open virtio-gpu device");
        return result;
    }

    /* 2. Create Venus context */
    result = jackgpu_d3dkmt_create_context(tp, VIRTGPU_CAPSET_VENUS);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to create Venus context");
        return result;
    }

    /* 3. Get Venus capset */
    result = jackgpu_transport_get_capset(tp);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to get Venus capset");
        return result;
    }

    JACKGPU_LOG("Venus capset: wire_format=%u, vk_xml=%u",
                tp->capset.wire_format_version,
                tp->capset.vk_xml_version);

    /* 4. Create ring buffer shared memory */
    struct jackgpu_ring_layout layout;
    jackgpu_ring_layout_init(&layout, RING_BUFFER_SIZE, RING_EXTRA_SIZE);

    result = jackgpu_transport_create_blob(tp, &tp->ring_blob,
                                           VIRTGPU_BLOB_MEM_GUEST,
                                           VIRTGPU_BLOB_FLAG_MAPPABLE,
                                           layout.shmem_size, 0);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to create ring blob");
        return result;
    }

    result = jackgpu_transport_map_blob(tp, &tp->ring_blob);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to map ring blob");
        return result;
    }

    /* 5. Initialize ring buffer */
    jackgpu_ring_init(&tp->ring, tp->ring_blob.mapped, &layout);

    /* 6. Create ring on host (via execbuffer, not through ring itself) */
    result = jackgpu_d3dkmt_create_ring(tp, &tp->ring_blob, &layout);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to create ring on host");
        return result;
    }

    /* 7. Create reply shared memory */
    result = jackgpu_transport_create_blob(tp, &tp->reply_blob,
                                           VIRTGPU_BLOB_MEM_GUEST,
                                           VIRTGPU_BLOB_FLAG_MAPPABLE,
                                           REPLY_SHMEM_SIZE, 0);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to create reply blob");
        return result;
    }

    result = jackgpu_transport_map_blob(tp, &tp->reply_blob);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to map reply blob");
        return result;
    }
    tp->reply_shmem = tp->reply_blob.mapped;
    tp->reply_size = REPLY_SHMEM_SIZE;

    /* 8. Create command scratch buffer */
    result = jackgpu_transport_create_blob(tp, &tp->cmd_blob,
                                           VIRTGPU_BLOB_MEM_GUEST,
                                           VIRTGPU_BLOB_FLAG_MAPPABLE,
                                           CMD_SHMEM_SIZE, 0);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to create command blob");
        return result;
    }

    result = jackgpu_transport_map_blob(tp, &tp->cmd_blob);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to map command blob");
        return result;
    }
    tp->cmd_shmem = tp->cmd_blob.mapped;
    tp->cmd_size = CMD_SHMEM_SIZE;

    /* 9. Tell renderer where to write replies */
    result = jackgpu_d3dkmt_set_reply_stream(tp, &tp->reply_blob);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to set reply stream");
        return result;
    }

    tp->next_object_id = 0;

    JACKGPU_LOG("transport initialized successfully");
    return VK_SUCCESS;
}

void jackgpu_transport_fini(jackgpu_transport *tp) {
    /* Destroy ring on host */
    jackgpu_d3dkmt_destroy_ring(tp);

    /* Unmap and destroy blobs */
    jackgpu_transport_destroy_blob(tp, &tp->cmd_blob);
    jackgpu_transport_destroy_blob(tp, &tp->reply_blob);
    jackgpu_transport_destroy_blob(tp, &tp->ring_blob);

    /* Destroy context and close device */
    jackgpu_d3dkmt_destroy_context(tp);
    jackgpu_d3dkmt_close_device(tp);

    JACKGPU_LOG("transport finalized");
}

VkResult jackgpu_transport_get_capset(jackgpu_transport *tp) {
    return jackgpu_d3dkmt_get_capset(tp, VIRTGPU_CAPSET_VENUS,
                                     &tp->capset, sizeof(tp->capset));
}

VkResult jackgpu_transport_create_blob(jackgpu_transport *tp,
                                       struct jackgpu_blob *blob,
                                       uint32_t blob_mem,
                                       uint32_t blob_flags,
                                       size_t size,
                                       uint64_t blob_id) {
    memset(blob, 0, sizeof(*blob));
    blob->size = JACKGPU_ALIGN(size, 4096);
    blob->blob_id = blob_id;
    return jackgpu_d3dkmt_create_blob(tp, blob, blob_mem, blob_flags);
}

VkResult jackgpu_transport_map_blob(jackgpu_transport *tp,
                                    struct jackgpu_blob *blob) {
    return jackgpu_d3dkmt_map_blob(tp, blob);
}

void jackgpu_transport_destroy_blob(jackgpu_transport *tp,
                                    struct jackgpu_blob *blob) {
    if (blob->mapped) {
        jackgpu_d3dkmt_unmap_blob(tp, blob);
        blob->mapped = NULL;
    }
    if (blob->handle) {
        jackgpu_d3dkmt_destroy_resource(tp, blob->handle);
        blob->handle = 0;
    }
}

VkResult jackgpu_transport_execbuffer(jackgpu_transport *tp,
                                      const void *data, size_t size,
                                      uint32_t ring_idx) {
    return jackgpu_d3dkmt_execbuffer(tp, data, size, ring_idx);
}

VkResult jackgpu_transport_submit_cmd(jackgpu_transport *tp,
                                      const void *cmd, size_t cmd_size,
                                      void *reply, size_t reply_size) {
    /* Submit command to ring */
    uint32_t seqno = jackgpu_ring_submit(&tp->ring, cmd, cmd_size);

    /* Wake renderer if idle */
    if (jackgpu_ring_is_idle(&tp->ring)) {
        jackgpu_transport_notify_ring(tp);
    }

    /* Wait for completion */
    jackgpu_ring_wait(&tp->ring, seqno);

    /* Check for fatal error */
    if (jackgpu_ring_is_fatal(&tp->ring)) {
        JACKGPU_ERR("ring fatal error after submit");
        return VK_ERROR_DEVICE_LOST;
    }

    /* Copy reply if requested */
    if (reply && reply_size > 0) {
        size_t copy = reply_size < tp->reply_size ? reply_size : tp->reply_size;
        memcpy(reply, tp->reply_shmem, copy);
    }

    return VK_SUCCESS;
}

VkResult jackgpu_transport_submit_cmd_no_reply(jackgpu_transport *tp,
                                               const void *cmd, size_t cmd_size) {
    uint32_t seqno = jackgpu_ring_submit(&tp->ring, cmd, cmd_size);

    if (jackgpu_ring_is_idle(&tp->ring)) {
        jackgpu_transport_notify_ring(tp);
    }

    /* Don't wait — fire and forget */
    JACKGPU_UNUSED(seqno);
    return VK_SUCCESS;
}

void jackgpu_transport_notify_ring(jackgpu_transport *tp) {
    jackgpu_d3dkmt_notify_ring(tp);
}
