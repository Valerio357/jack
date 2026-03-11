/*
 * d3dkmt.h — Windows D3DKMT interface for virtio-gpu communication
 *
 * On Windows, userspace talks to the WDDM kernel driver via D3DKMTEscape.
 * This layer wraps those calls into virtio-gpu operations.
 *
 * On non-Windows platforms, provides stubs for development.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_D3DKMT_H
#define JACKGPU_D3DKMT_H

#include "transport/virtgpu.h"

/* ── Escape command types (userspace → kernel driver) ─────── */

enum jackgpu_escape_cmd {
    JACKGPU_ESCAPE_GET_CAPSET       = 0x01,
    JACKGPU_ESCAPE_CREATE_CONTEXT   = 0x02,
    JACKGPU_ESCAPE_DESTROY_CONTEXT  = 0x03,
    JACKGPU_ESCAPE_CREATE_BLOB      = 0x04,
    JACKGPU_ESCAPE_MAP_BLOB         = 0x05,
    JACKGPU_ESCAPE_UNMAP_BLOB       = 0x06,
    JACKGPU_ESCAPE_DESTROY_RESOURCE = 0x07,
    JACKGPU_ESCAPE_EXECBUFFER       = 0x08,
    JACKGPU_ESCAPE_CREATE_RING      = 0x09,
    JACKGPU_ESCAPE_DESTROY_RING     = 0x0A,
    JACKGPU_ESCAPE_NOTIFY_RING      = 0x0B,
    JACKGPU_ESCAPE_SET_REPLY_STREAM = 0x0C,
};

/* ── Escape data structures ───────────────────────────────── */

struct jackgpu_escape_header {
    uint32_t cmd;       /* jackgpu_escape_cmd */
    uint32_t size;      /* Total size including header */
    int32_t  result;    /* Return code (0 = success) */
};

struct jackgpu_escape_capset {
    struct jackgpu_escape_header hdr;
    uint32_t capset_id;
    uint32_t capset_size;
    /* capset data follows */
};

struct jackgpu_escape_create_context {
    struct jackgpu_escape_header hdr;
    uint32_t capset_id;
    uint32_t num_rings;
    uint32_t context_id;   /* output */
};

struct jackgpu_escape_create_blob_params {
    struct jackgpu_escape_header hdr;
    uint32_t blob_mem;
    uint32_t blob_flags;
    uint64_t size;
    uint64_t blob_id;
    uint32_t handle;       /* output */
};

struct jackgpu_escape_map_blob_params {
    struct jackgpu_escape_header hdr;
    uint32_t handle;
    uint64_t mapped_addr;  /* output */
};

struct jackgpu_escape_execbuffer_params {
    struct jackgpu_escape_header hdr;
    uint32_t ring_idx;
    uint32_t data_size;
    /* command data follows */
};

/* ── D3DKMT wrapper functions ─────────────────────────────── */

/* Open the JackGPU adapter via D3DKMTEnumAdapters */
VkResult jackgpu_d3dkmt_open_device(jackgpu_transport *tp);
void     jackgpu_d3dkmt_close_device(jackgpu_transport *tp);

/* Create/destroy Venus context */
VkResult jackgpu_d3dkmt_create_context(jackgpu_transport *tp, uint32_t capset_id);
void     jackgpu_d3dkmt_destroy_context(jackgpu_transport *tp);

/* Get capset data from host */
VkResult jackgpu_d3dkmt_get_capset(jackgpu_transport *tp, uint32_t capset_id,
                                    void *data, size_t size);

/* Blob resource management */
VkResult jackgpu_d3dkmt_create_blob(jackgpu_transport *tp,
                                     struct jackgpu_blob *blob,
                                     uint32_t blob_mem, uint32_t blob_flags);
VkResult jackgpu_d3dkmt_map_blob(jackgpu_transport *tp,
                                  struct jackgpu_blob *blob);
void     jackgpu_d3dkmt_unmap_blob(jackgpu_transport *tp,
                                    struct jackgpu_blob *blob);
void     jackgpu_d3dkmt_destroy_resource(jackgpu_transport *tp,
                                          uint32_t handle);

/* Submit command buffer */
VkResult jackgpu_d3dkmt_execbuffer(jackgpu_transport *tp,
                                    const void *data, size_t size,
                                    uint32_t ring_idx);

/* Ring management */
VkResult jackgpu_d3dkmt_create_ring(jackgpu_transport *tp,
                                     struct jackgpu_blob *ring_blob,
                                     const struct jackgpu_ring_layout *layout);
void     jackgpu_d3dkmt_destroy_ring(jackgpu_transport *tp);
void     jackgpu_d3dkmt_notify_ring(jackgpu_transport *tp);
VkResult jackgpu_d3dkmt_set_reply_stream(jackgpu_transport *tp,
                                          struct jackgpu_blob *reply_blob);

#endif /* JACKGPU_D3DKMT_H */
