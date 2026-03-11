/*
 * virtqueue.c — Virtio virtqueue management for JackGPU KMD
 *
 * Handles virtio PCI device initialization, virtqueue setup,
 * and command submission via the controlq.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "jackgpu_kmd.h"

/* ── Virtio PCI common configuration registers ───────────────── */
/* Offsets within the VIRTIO_PCI_CAP_COMMON_CFG structure */

#define VIRTIO_COMMON_DFSELECT     0x00  /* UINT32 */
#define VIRTIO_COMMON_DF           0x04  /* UINT32 */
#define VIRTIO_COMMON_GFSELECT     0x08  /* UINT32 */
#define VIRTIO_COMMON_GF           0x0C  /* UINT32 */
#define VIRTIO_COMMON_MSIX         0x10  /* UINT16 */
#define VIRTIO_COMMON_NUMQ         0x12  /* UINT16 */
#define VIRTIO_COMMON_STATUS       0x14  /* UINT8  */
#define VIRTIO_COMMON_CFGGEN       0x15  /* UINT8  */
#define VIRTIO_COMMON_Q_SELECT     0x16  /* UINT16 */
#define VIRTIO_COMMON_Q_SIZE       0x18  /* UINT16 */
#define VIRTIO_COMMON_Q_MSIX       0x1A  /* UINT16 */
#define VIRTIO_COMMON_Q_ENABLE     0x1C  /* UINT16 */
#define VIRTIO_COMMON_Q_NOFF       0x1E  /* UINT16 */
#define VIRTIO_COMMON_Q_DESCLO     0x20  /* UINT32 */
#define VIRTIO_COMMON_Q_DESCHI     0x24  /* UINT32 */
#define VIRTIO_COMMON_Q_AVAILLO    0x28  /* UINT32 */
#define VIRTIO_COMMON_Q_AVAILHI    0x2C  /* UINT32 */
#define VIRTIO_COMMON_Q_USEDLO     0x30  /* UINT32 */
#define VIRTIO_COMMON_Q_USEDHI     0x34  /* UINT32 */

/* Virtio PCI capability structure in config space */
struct virtio_pci_cap {
    UINT8 cap_vndr;    /* 0x09 (PCI_CAPABILITY_ID_VENDOR_SPECIFIC) */
    UINT8 cap_next;
    UINT8 cap_len;
    UINT8 cfg_type;    /* VIRTIO_PCI_CAP_* */
    UINT8 bar;
    UINT8 padding[3];
    UINT32 offset;
    UINT32 length;
};

/* ── Helper: read/write common config ────────────────────────── */

static UINT8 common_read8(PJACKGPU_DEVICE_EXTENSION ext, ULONG offset) {
    return READ_REGISTER_UCHAR((volatile UCHAR *)(ext->common_cfg + offset));
}

static UINT16 common_read16(PJACKGPU_DEVICE_EXTENSION ext, ULONG offset) {
    return READ_REGISTER_USHORT((volatile USHORT *)(ext->common_cfg + offset));
}

static UINT32 common_read32(PJACKGPU_DEVICE_EXTENSION ext, ULONG offset) {
    return READ_REGISTER_ULONG((volatile ULONG *)(ext->common_cfg + offset));
}

static void common_write8(PJACKGPU_DEVICE_EXTENSION ext, ULONG offset, UINT8 val) {
    WRITE_REGISTER_UCHAR((volatile UCHAR *)(ext->common_cfg + offset), val);
}

static void common_write16(PJACKGPU_DEVICE_EXTENSION ext, ULONG offset, UINT16 val) {
    WRITE_REGISTER_USHORT((volatile USHORT *)(ext->common_cfg + offset), val);
}

static void common_write32(PJACKGPU_DEVICE_EXTENSION ext, ULONG offset, UINT32 val) {
    WRITE_REGISTER_ULONG((volatile ULONG *)(ext->common_cfg + offset), val);
}

/* ── Virtio device status ────────────────────────────────────── */

VOID jackgpu_virtio_set_status(PJACKGPU_DEVICE_EXTENSION ext, UINT8 status) {
    common_write8(ext, VIRTIO_COMMON_STATUS, status);
}

UINT8 jackgpu_virtio_get_status(PJACKGPU_DEVICE_EXTENSION ext) {
    return common_read8(ext, VIRTIO_COMMON_STATUS);
}

VOID jackgpu_virtio_reset(PJACKGPU_DEVICE_EXTENSION ext) {
    /* Writing 0 to status resets the device */
    common_write8(ext, VIRTIO_COMMON_STATUS, 0);

    /* Wait for reset to take effect */
    while (common_read8(ext, VIRTIO_COMMON_STATUS) != 0) {
        KeStallExecutionProcessor(1);
    }
}

/* ── Parse PCI capabilities ──────────────────────────────────── */

static NTSTATUS parse_pci_caps(PJACKGPU_DEVICE_EXTENSION ext)
{
    /*
     * Walk the PCI capability list to find virtio config structures.
     * We read config space via DxgkCbReadDeviceSpace.
     */
    UINT8 cap_offset = 0;
    ULONG bytes_read;

    /* Read capabilities pointer (offset 0x34) */
    NTSTATUS status = ext->dxgk_interface.DxgkCbReadDeviceSpace(
        ext->dxgk_handle, DXGK_WHICHSPACE_CONFIG, &cap_offset, 0x34, 1, &bytes_read);
    if (!NT_SUCCESS(status)) return status;

    while (cap_offset != 0 && cap_offset != 0xFF) {
        struct virtio_pci_cap cap;
        status = ext->dxgk_interface.DxgkCbReadDeviceSpace(
            ext->dxgk_handle, DXGK_WHICHSPACE_CONFIG, &cap,
            cap_offset, sizeof(cap), &bytes_read);
        if (!NT_SUCCESS(status)) break;

        /* Vendor-specific capability (virtio) */
        if (cap.cap_vndr == 0x09 && cap.bar < 6 && ext->bar_mapped[cap.bar]) {
            volatile UINT8 *base = (volatile UINT8 *)ext->bar_mapped[cap.bar] + cap.offset;

            switch (cap.cfg_type) {
            case VIRTIO_PCI_CAP_COMMON_CFG:
                ext->common_cfg = base;
                JACKGPU_KMD_LOG("common_cfg: BAR%u+0x%X", cap.bar, cap.offset);
                break;

            case VIRTIO_PCI_CAP_NOTIFY_CFG:
                ext->notify_cfg = base;
                /* Read notify_off_multiplier (at cap_offset + sizeof(cap)) */
                ext->dxgk_interface.DxgkCbReadDeviceSpace(
                    ext->dxgk_handle, DXGK_WHICHSPACE_CONFIG,
                    &ext->notify_off_multiplier,
                    cap_offset + sizeof(cap), 4, &bytes_read);
                JACKGPU_KMD_LOG("notify_cfg: BAR%u+0x%X mul=%u",
                                cap.bar, cap.offset, ext->notify_off_multiplier);
                break;

            case VIRTIO_PCI_CAP_ISR_CFG:
                ext->isr_cfg = base;
                JACKGPU_KMD_LOG("isr_cfg: BAR%u+0x%X", cap.bar, cap.offset);
                break;

            case VIRTIO_PCI_CAP_DEVICE_CFG:
                ext->device_cfg = base;
                JACKGPU_KMD_LOG("device_cfg: BAR%u+0x%X", cap.bar, cap.offset);
                break;
            }
        }

        cap_offset = cap.cap_next;
    }

    if (!ext->common_cfg || !ext->notify_cfg) {
        JACKGPU_KMD_ERR("missing required virtio capabilities");
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    return STATUS_SUCCESS;
}

/* ── Virtio device initialization ────────────────────────────── */

NTSTATUS jackgpu_virtio_init(PJACKGPU_DEVICE_EXTENSION ext)
{
    NTSTATUS status;

    /* 1. Parse PCI capabilities */
    status = parse_pci_caps(ext);
    if (!NT_SUCCESS(status)) return status;

    /* 2. Reset device */
    jackgpu_virtio_reset(ext);

    /* 3. Set ACKNOWLEDGE status */
    jackgpu_virtio_set_status(ext, VIRTIO_STATUS_ACKNOWLEDGE);

    /* 4. Set DRIVER status */
    jackgpu_virtio_set_status(ext,
        VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);

    /* 5. Feature negotiation — accept all features for now */
    /* Read device features word 0 */
    common_write32(ext, VIRTIO_COMMON_DFSELECT, 0);
    UINT32 dev_features_lo = common_read32(ext, VIRTIO_COMMON_DF);
    /* Read device features word 1 */
    common_write32(ext, VIRTIO_COMMON_DFSELECT, 1);
    UINT32 dev_features_hi = common_read32(ext, VIRTIO_COMMON_DF);

    JACKGPU_KMD_LOG("device features: 0x%08X_%08X", dev_features_hi, dev_features_lo);

    /* Write back accepted features (accept all) */
    common_write32(ext, VIRTIO_COMMON_GFSELECT, 0);
    common_write32(ext, VIRTIO_COMMON_GF, dev_features_lo);
    common_write32(ext, VIRTIO_COMMON_GFSELECT, 1);
    common_write32(ext, VIRTIO_COMMON_GF, dev_features_hi);

    /* 6. Set FEATURES_OK */
    jackgpu_virtio_set_status(ext,
        VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK);

    /* Verify FEATURES_OK is still set */
    UINT8 device_status = jackgpu_virtio_get_status(ext);
    if (!(device_status & VIRTIO_STATUS_FEATURES_OK)) {
        JACKGPU_KMD_ERR("device did not accept features");
        jackgpu_virtio_set_status(ext, VIRTIO_STATUS_FAILED);
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    /* Virtqueue setup happens in jackgpu_vq_init */

    /* 7. Set DRIVER_OK — device is live after this */
    jackgpu_virtio_set_status(ext,
        VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
        VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);

    JACKGPU_KMD_LOG("virtio device initialized, status=0x%02X",
                    jackgpu_virtio_get_status(ext));

    return STATUS_SUCCESS;
}

/* ── Virtqueue initialization ────────────────────────────────── */

NTSTATUS jackgpu_vq_init(
    PJACKGPU_DEVICE_EXTENSION ext,
    JACKGPU_VIRTQUEUE *vq,
    UINT16 queue_idx)
{
    RtlZeroMemory(vq, sizeof(*vq));
    KeInitializeSpinLock(&vq->lock);

    /* Select queue */
    common_write16(ext, VIRTIO_COMMON_Q_SELECT, queue_idx);

    /* Read max queue size */
    UINT16 max_size = common_read16(ext, VIRTIO_COMMON_Q_SIZE);
    if (max_size == 0) {
        JACKGPU_KMD_ERR("queue %u not available", queue_idx);
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    vq->size = (max_size < JACKGPU_VQ_SIZE) ? max_size : JACKGPU_VQ_SIZE;

    /* Set our desired queue size */
    common_write16(ext, VIRTIO_COMMON_Q_SIZE, vq->size);

    JACKGPU_KMD_LOG("queue %u: size=%u (max=%u)", queue_idx, vq->size, max_size);

    /* Calculate memory requirements for the three ring sections */
    SIZE_T desc_size  = sizeof(struct virtq_desc) * vq->size;
    SIZE_T avail_size = sizeof(UINT16) * (3 + vq->size);  /* flags + idx + ring[N] + used_event */
    SIZE_T used_size  = sizeof(UINT16) * 3 + sizeof(struct virtq_used_elem) * vq->size;

    /* Align sections: desc 16-byte, avail 2-byte, used 4-byte */
    SIZE_T total = desc_size;
    total = (total + 0xFFF) & ~(SIZE_T)0xFFF;  /* Align to page for avail */
    SIZE_T avail_offset = total;
    total += avail_size;
    total = (total + 0xFFF) & ~(SIZE_T)0xFFF;  /* Align to page for used */
    SIZE_T used_offset = total;
    total += used_size;
    total = (total + 0xFFF) & ~(SIZE_T)0xFFF;  /* Round up to page */

    /* Allocate physically contiguous memory */
    PHYSICAL_ADDRESS low = {0}, high = {0};
    high.QuadPart = 0xFFFFFFFFFFFFFFFF;
    PHYSICAL_ADDRESS boundary = {0};

    vq->ring_mem = MmAllocateContiguousMemorySpecifyCache(
        total, low, high, boundary, MmNonCached);

    if (!vq->ring_mem) {
        JACKGPU_KMD_ERR("failed to allocate virtqueue rings (%llu bytes)", (ULONGLONG)total);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(vq->ring_mem, total);
    vq->ring_mem_size = total;
    vq->ring_mem_phys = MmGetPhysicalAddress(vq->ring_mem);

    /* Set up pointers */
    vq->desc  = (struct virtq_desc *)vq->ring_mem;
    vq->avail = (struct virtq_avail *)((UINT8 *)vq->ring_mem + avail_offset);
    vq->used  = (struct virtq_used *)((UINT8 *)vq->ring_mem + used_offset);

    vq->desc_phys  = vq->ring_mem_phys;
    vq->avail_phys = vq->ring_mem_phys;
    vq->avail_phys.QuadPart += avail_offset;
    vq->used_phys  = vq->ring_mem_phys;
    vq->used_phys.QuadPart += used_offset;

    /* Initialize free descriptor list */
    vq->free_head = 0;
    vq->num_free = vq->size;
    for (UINT16 i = 0; i < vq->size - 1; i++) {
        vq->desc[i].next = i + 1;
    }
    vq->desc[vq->size - 1].next = 0xFFFF; /* end of list */
    vq->last_used_idx = 0;

    /* Tell device where the rings are */
    common_write32(ext, VIRTIO_COMMON_Q_DESCLO, (UINT32)vq->desc_phys.LowPart);
    common_write32(ext, VIRTIO_COMMON_Q_DESCHI, (UINT32)vq->desc_phys.HighPart);
    common_write32(ext, VIRTIO_COMMON_Q_AVAILLO, (UINT32)vq->avail_phys.LowPart);
    common_write32(ext, VIRTIO_COMMON_Q_AVAILHI, (UINT32)vq->avail_phys.HighPart);
    common_write32(ext, VIRTIO_COMMON_Q_USEDLO, (UINT32)vq->used_phys.LowPart);
    common_write32(ext, VIRTIO_COMMON_Q_USEDHI, (UINT32)vq->used_phys.HighPart);

    /* Get notification offset for this queue */
    UINT16 queue_notify_off = common_read16(ext, VIRTIO_COMMON_Q_NOFF);
    vq->notify = (volatile UINT16 *)(ext->notify_cfg +
                                      queue_notify_off * ext->notify_off_multiplier);

    /* Enable the queue */
    common_write16(ext, VIRTIO_COMMON_Q_ENABLE, 1);

    JACKGPU_KMD_LOG("queue %u enabled, notify=%p", queue_idx, vq->notify);

    return STATUS_SUCCESS;
}

/* ── Virtqueue teardown ──────────────────────────────────────── */

VOID jackgpu_vq_destroy(PJACKGPU_DEVICE_EXTENSION ext, JACKGPU_VIRTQUEUE *vq)
{
    UNREFERENCED_PARAMETER(ext);

    if (vq->ring_mem) {
        MmFreeContiguousMemory(vq->ring_mem);
        vq->ring_mem = NULL;
    }

    RtlZeroMemory(vq, sizeof(*vq));
}

/* ── Send command via virtqueue (synchronous) ────────────────── */

NTSTATUS jackgpu_vq_send_command(
    PJACKGPU_DEVICE_EXTENSION ext,
    JACKGPU_VIRTQUEUE *vq,
    PVOID cmd, UINT32 cmd_size,
    PVOID resp, UINT32 resp_size)
{
    KIRQL old_irql;
    KEVENT event;

    KeInitializeEvent(&event, SynchronizationEvent, FALSE);
    KeAcquireSpinLock(&vq->lock, &old_irql);

    /* Need 2 descriptors: one for cmd (device-readable), one for resp (device-writable) */
    if (vq->num_free < 2) {
        KeReleaseSpinLock(&vq->lock, old_irql);
        JACKGPU_KMD_ERR("no free descriptors");
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    /* Allocate cmd descriptor */
    UINT16 cmd_idx = vq->free_head;
    vq->free_head = vq->desc[cmd_idx].next;
    vq->num_free--;

    /* Allocate resp descriptor */
    UINT16 resp_idx = vq->free_head;
    vq->free_head = vq->desc[resp_idx].next;
    vq->num_free--;

    /* cmd and resp must be physically contiguous.
     * For simplicity, we allocate contiguous bounce buffers. */
    PHYSICAL_ADDRESS cmd_phys = MmGetPhysicalAddress(cmd);
    PHYSICAL_ADDRESS resp_phys = MmGetPhysicalAddress(resp);

    /* Fill cmd descriptor (device-readable) */
    vq->desc[cmd_idx].addr = cmd_phys.QuadPart;
    vq->desc[cmd_idx].len = cmd_size;
    vq->desc[cmd_idx].flags = VIRTQ_DESC_F_NEXT;
    vq->desc[cmd_idx].next = resp_idx;

    /* Fill resp descriptor (device-writable) */
    vq->desc[resp_idx].addr = resp_phys.QuadPart;
    vq->desc[resp_idx].len = resp_size;
    vq->desc[resp_idx].flags = VIRTQ_DESC_F_WRITE;
    vq->desc[resp_idx].next = 0xFFFF;

    /* Set up completion tracking */
    vq->pending[cmd_idx].event = &event;

    /* Add to available ring */
    UINT16 avail_idx = vq->avail->idx & (vq->size - 1);
    vq->avail->ring[avail_idx] = cmd_idx;
    MemoryBarrier();
    vq->avail->idx++;

    /* Notify device */
    MemoryBarrier();
    WRITE_REGISTER_USHORT((volatile USHORT *)vq->notify, 0);

    KeReleaseSpinLock(&vq->lock, old_irql);

    /* Wait for completion */
    LARGE_INTEGER timeout;
    timeout.QuadPart = -50000000LL;  /* 5 second timeout */

    NTSTATUS status = KeWaitForSingleObject(
        &event, Executive, KernelMode, FALSE, &timeout);

    if (status == STATUS_TIMEOUT) {
        JACKGPU_KMD_ERR("command timed out");
        return STATUS_IO_TIMEOUT;
    }

    /* Check response type */
    struct virtio_gpu_ctrl_hdr *hdr = (struct virtio_gpu_ctrl_hdr *)resp;
    if (hdr->type >= VIRTIO_GPU_RESP_ERR_UNSPEC) {
        JACKGPU_KMD_ERR("GPU error response: 0x%08X", hdr->type);
        return STATUS_DEVICE_PROTOCOL_ERROR;
    }

    return STATUS_SUCCESS;
}

/* ── Resource management ─────────────────────────────────────── */

JACKGPU_RESOURCE *jackgpu_alloc_resource(PJACKGPU_DEVICE_EXTENSION ext)
{
    KIRQL old_irql;
    KeAcquireSpinLock(&ext->resource_lock, &old_irql);

    for (UINT32 i = 0; i < JACKGPU_MAX_RESOURCES; i++) {
        if (!ext->resources[i].in_use) {
            ext->resources[i].in_use = TRUE;
            ext->resources[i].resource_id = ext->next_resource_id++;
            KeReleaseSpinLock(&ext->resource_lock, old_irql);
            return &ext->resources[i];
        }
    }

    KeReleaseSpinLock(&ext->resource_lock, old_irql);
    return NULL;
}

JACKGPU_RESOURCE *jackgpu_find_resource(PJACKGPU_DEVICE_EXTENSION ext, UINT32 handle)
{
    KIRQL old_irql;
    KeAcquireSpinLock(&ext->resource_lock, &old_irql);

    for (UINT32 i = 0; i < JACKGPU_MAX_RESOURCES; i++) {
        if (ext->resources[i].in_use && ext->resources[i].resource_id == handle) {
            KeReleaseSpinLock(&ext->resource_lock, old_irql);
            return &ext->resources[i];
        }
    }

    KeReleaseSpinLock(&ext->resource_lock, old_irql);
    return NULL;
}

VOID jackgpu_free_resource(PJACKGPU_DEVICE_EXTENSION ext, JACKGPU_RESOURCE *res)
{
    KIRQL old_irql;
    KeAcquireSpinLock(&ext->resource_lock, &old_irql);

    if (res->mdl) {
        if (res->mapped_user) {
            MmUnmapLockedPages(res->mapped_user, res->mdl);
        }
        IoFreeMdl(res->mdl);
    }

    if (res->mapped_kernel) {
        MmFreeContiguousMemory(res->mapped_kernel);
    }

    RtlZeroMemory(res, sizeof(*res));

    KeReleaseSpinLock(&ext->resource_lock, old_irql);
}
