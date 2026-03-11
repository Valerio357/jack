/*
 * ring.h — Venus ring buffer protocol
 *
 * Shared memory ring buffer for guest→host Vulkan command submission.
 * Matches Mesa's vn_ring implementation.
 *
 * Layout (all offsets 64-byte aligned):
 *   +0x00: head   (uint32) — written by host (consumer)
 *   +0x40: tail   (uint32) — written by guest (producer)
 *   +0x80: status (uint32) — written by host
 *   +0xC0: buffer[N]       — circular command buffer
 *   +0xC0+N: extra[M]      — auxiliary data
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_RING_H
#define JACKGPU_RING_H

#include "driver/jackgpu.h"

/* Ring status flags (set by host/renderer) */
#define JACKGPU_RING_STATUS_IDLE   0x1  /* Renderer idle, needs wake */
#define JACKGPU_RING_STATUS_FATAL  0x2  /* Unrecoverable error */
#define JACKGPU_RING_STATUS_ALIVE  0x4  /* Renderer is alive */

/* Ring layout — matches VkRingCreateInfoMESA */
struct jackgpu_ring_layout {
    size_t head_offset;
    size_t tail_offset;
    size_t status_offset;
    size_t buffer_offset;
    size_t buffer_size;      /* Must be power of 2 */
    size_t extra_offset;
    size_t extra_size;
    size_t shmem_size;       /* Total shared memory size */
};

/* Ring state */
struct jackgpu_ring {
    /* Mapped shared memory */
    volatile uint32_t *head;
    volatile uint32_t *tail;
    volatile uint32_t *status;
    uint8_t           *buffer;
    uint8_t           *extra;

    /* Configuration */
    size_t buffer_size;
    size_t buffer_mask;      /* buffer_size - 1 */
    size_t extra_size;

    /* Local state */
    uint32_t cur;            /* Current write position (local tail) */

    /* Backing shared memory (transport-specific handle) */
    void *shmem;
    size_t shmem_size;

    /* Direct order: commands smaller than buffer_size >> direct_order
     * go directly into the ring. Larger ones use indirect submission. */
    uint32_t direct_order;
};

/* Initialize ring layout with given buffer and extra sizes */
void jackgpu_ring_layout_init(struct jackgpu_ring_layout *layout,
                              size_t buffer_size, size_t extra_size);

/* Initialize ring from mapped shared memory */
void jackgpu_ring_init(jackgpu_ring *ring, void *shmem,
                       const struct jackgpu_ring_layout *layout);

/* Write command data into the ring buffer.
 * Returns the sequence number (tail position after write).
 * Blocks if ring is full (busy-waits on head). */
uint32_t jackgpu_ring_submit(jackgpu_ring *ring, const void *data, size_t size);

/* Wait until the host has consumed up to the given sequence number */
void jackgpu_ring_wait(jackgpu_ring *ring, uint32_t seqno);

/* Check if the renderer reported a fatal error */
bool jackgpu_ring_is_fatal(jackgpu_ring *ring);

/* Check if the renderer needs a wake notification */
bool jackgpu_ring_is_idle(jackgpu_ring *ring);

/* Get ring status */
uint32_t jackgpu_ring_get_status(jackgpu_ring *ring);

#endif /* JACKGPU_RING_H */
