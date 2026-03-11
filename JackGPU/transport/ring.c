/*
 * ring.c — Venus ring buffer protocol implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "transport/ring.h"

#ifdef _WIN32
#include <windows.h>
/* Use InterlockedCompareExchange for atomic loads on Windows */
#define atomic_load_u32(ptr) \
    (uint32_t)InterlockedCompareExchange((volatile LONG *)(ptr), 0, 0)
#define atomic_store_u32(ptr, val) \
    InterlockedExchange((volatile LONG *)(ptr), (LONG)(val))
#define memory_barrier() MemoryBarrier()
#define cpu_relax() YieldProcessor()
#else
/* POSIX / development builds */
#include <stdatomic.h>
#define atomic_load_u32(ptr) \
    __atomic_load_n((volatile uint32_t *)(ptr), __ATOMIC_SEQ_CST)
#define atomic_store_u32(ptr, val) \
    __atomic_store_n((volatile uint32_t *)(ptr), (val), __ATOMIC_SEQ_CST)
#define memory_barrier() __atomic_thread_fence(__ATOMIC_SEQ_CST)
#define cpu_relax() __builtin_ia32_pause()
#endif

/* Alignment for ring sections (cache line) */
#define RING_ALIGN 64

void jackgpu_ring_layout_init(struct jackgpu_ring_layout *layout,
                              size_t buffer_size, size_t extra_size) {
    /* buffer_size must be power of 2 */
    assert(buffer_size && (buffer_size & (buffer_size - 1)) == 0);

    size_t offset = 0;

    layout->head_offset = offset;
    offset += RING_ALIGN;

    layout->tail_offset = offset;
    offset += RING_ALIGN;

    layout->status_offset = offset;
    offset += RING_ALIGN;

    layout->buffer_offset = offset;
    layout->buffer_size = buffer_size;
    offset += buffer_size;

    layout->extra_offset = JACKGPU_ALIGN(offset, RING_ALIGN);
    layout->extra_size = extra_size;
    offset = layout->extra_offset + extra_size;

    layout->shmem_size = JACKGPU_ALIGN(offset, 4096);
}

void jackgpu_ring_init(jackgpu_ring *ring, void *shmem,
                       const struct jackgpu_ring_layout *layout) {
    uint8_t *base = (uint8_t *)shmem;

    ring->head   = (volatile uint32_t *)(base + layout->head_offset);
    ring->tail   = (volatile uint32_t *)(base + layout->tail_offset);
    ring->status = (volatile uint32_t *)(base + layout->status_offset);
    ring->buffer = base + layout->buffer_offset;
    ring->extra  = base + layout->extra_offset;

    ring->buffer_size = layout->buffer_size;
    ring->buffer_mask = layout->buffer_size - 1;
    ring->extra_size = layout->extra_size;

    ring->shmem = shmem;
    ring->shmem_size = layout->shmem_size;

    /* Initialize to 0 */
    ring->cur = 0;
    atomic_store_u32(ring->head, 0);
    atomic_store_u32(ring->tail, 0);
    atomic_store_u32(ring->status, 0);

    /* Commands smaller than buffer/16 go directly into ring */
    ring->direct_order = 4;
}

/* Wait until there's enough space in the ring */
static void ring_wait_space(jackgpu_ring *ring, size_t size) {
    uint32_t head;
    for (;;) {
        head = atomic_load_u32(ring->head);
        /* Space available: cur + size - head <= buffer_size */
        if ((uint32_t)(ring->cur + (uint32_t)size - head) <= (uint32_t)ring->buffer_size)
            return;

        /* Check for fatal error */
        if (jackgpu_ring_is_fatal(ring)) {
            JACKGPU_ERR("ring fatal error detected");
            return;
        }

        cpu_relax();
    }
}

/* Write data into circular buffer, handling wraparound */
static void ring_write(jackgpu_ring *ring, const void *data, size_t size) {
    const uint8_t *src = (const uint8_t *)data;
    size_t offset = ring->cur & ring->buffer_mask;
    size_t first = ring->buffer_size - offset;

    if (first >= size) {
        /* No wrap */
        memcpy(ring->buffer + offset, src, size);
    } else {
        /* Wrap around */
        memcpy(ring->buffer + offset, src, first);
        memcpy(ring->buffer, src + first, size - first);
    }

    ring->cur += (uint32_t)size;
}

uint32_t jackgpu_ring_submit(jackgpu_ring *ring, const void *data, size_t size) {
    /* Align size to 4 bytes */
    size = JACKGPU_ALIGN(size, 4);

    /* Wait for space */
    ring_wait_space(ring, size);

    /* Write command */
    ring_write(ring, data, size);

    /* Update tail with full memory barrier */
    memory_barrier();
    atomic_store_u32(ring->tail, ring->cur);

    return ring->cur; /* sequence number */
}

void jackgpu_ring_wait(jackgpu_ring *ring, uint32_t seqno) {
    for (;;) {
        uint32_t head = atomic_load_u32(ring->head);
        /* Wraparound-aware comparison: head has advanced past seqno */
        if ((int32_t)(head - seqno) >= 0)
            return;

        if (jackgpu_ring_is_fatal(ring))
            return;

        cpu_relax();
    }
}

bool jackgpu_ring_is_fatal(jackgpu_ring *ring) {
    return (atomic_load_u32(ring->status) & JACKGPU_RING_STATUS_FATAL) != 0;
}

bool jackgpu_ring_is_idle(jackgpu_ring *ring) {
    return (atomic_load_u32(ring->status) & JACKGPU_RING_STATUS_IDLE) != 0;
}

uint32_t jackgpu_ring_get_status(jackgpu_ring *ring) {
    return atomic_load_u32(ring->status);
}
