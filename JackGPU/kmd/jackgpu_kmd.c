/*
 * jackgpu_kmd.c — JackGPU WDDM KMDOD Driver Entry and DDI Callbacks
 *
 * Registers as a Display-Only driver via DxgkInitializeDisplayOnlyDriver.
 * Initializes virtio-gpu PCI device and handles DXGK callbacks.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "jackgpu_kmd.h"

/* ── DriverEntry ─────────────────────────────────────────────── */

NTSTATUS DriverEntry(
    _In_ PDRIVER_OBJECT  DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    JACKGPU_KMD_LOG("DriverEntry");

    KMDDOD_INITIALIZATION_DATA init_data = {0};
    init_data.Version = DXGKDDI_INTERFACE_VERSION;

    /* Required DDI callbacks */
    init_data.DxgkDdiAddDevice              = jackgpu_ddi_add_device;
    init_data.DxgkDdiStartDevice            = jackgpu_ddi_start_device;
    init_data.DxgkDdiStopDevice             = jackgpu_ddi_stop_device;
    init_data.DxgkDdiRemoveDevice           = jackgpu_ddi_remove_device;

    init_data.DxgkDdiInterruptRoutine       = jackgpu_ddi_interrupt_routine;
    init_data.DxgkDdiDpcRoutine             = jackgpu_ddi_dpc_routine;

    init_data.DxgkDdiQueryChildRelations    = jackgpu_ddi_query_child_relations;
    init_data.DxgkDdiQueryChildStatus       = jackgpu_ddi_query_child_status;
    init_data.DxgkDdiQueryDeviceDescriptor  = jackgpu_ddi_query_device_descriptor;

    init_data.DxgkDdiSetPowerState          = jackgpu_ddi_set_power_state;

    init_data.DxgkDdiEscape                 = jackgpu_ddi_escape;

    init_data.DxgkDdiUnload                 = jackgpu_ddi_unload;

    NTSTATUS status = DxgkInitializeDisplayOnlyDriver(
        DriverObject, RegistryPath, &init_data);

    if (!NT_SUCCESS(status)) {
        JACKGPU_KMD_ERR("DxgkInitializeDisplayOnlyDriver failed: 0x%08X", status);
    }

    return status;
}

/* ── DxgkDdiAddDevice ────────────────────────────────────────── */

NTSTATUS jackgpu_ddi_add_device(
    _In_  CONST PDEVICE_OBJECT PhysicalDeviceObject,
    _Out_ PVOID MiniportDeviceContext,
    _Out_ PVOID *DeviceContext)
{
    UNREFERENCED_PARAMETER(PhysicalDeviceObject);
    UNREFERENCED_PARAMETER(MiniportDeviceContext);

    JACKGPU_KMD_LOG("DxgkDdiAddDevice");

    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)
        ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(JACKGPU_DEVICE_EXTENSION), JACKGPU_TAG);

    if (!ext) {
        JACKGPU_KMD_ERR("failed to allocate device extension");
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(ext, sizeof(*ext));
    KeInitializeSpinLock(&ext->resource_lock);
    KeInitializeSpinLock(&ext->cmd_lock);
    KeInitializeEvent(&ext->cmd_complete_event, SynchronizationEvent, FALSE);

    ext->next_resource_id = 1;
    ext->next_context_id = 1;

    *DeviceContext = ext;
    return STATUS_SUCCESS;
}

/* ── DxgkDdiStartDevice ─────────────────────────────────────── */

NTSTATUS jackgpu_ddi_start_device(
    _In_ PVOID MiniportDeviceContext,
    _In_ PDXGK_START_INFO DxgkStartInfo,
    _In_ PDXGKRNL_INTERFACE DxgkInterface,
    _Out_ PULONG NumberOfVideoPresentSources,
    _Out_ PULONG NumberOfChildren)
{
    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)MiniportDeviceContext;

    JACKGPU_KMD_LOG("DxgkDdiStartDevice");

    /* Save DXGK interface */
    ext->dxgk_handle = DxgkStartInfo->DeviceHandle;
    RtlCopyMemory(&ext->dxgk_interface, DxgkInterface, sizeof(DXGKRNL_INTERFACE));

    /* Map PCI BARs */
    DXGK_DEVICE_INFO device_info;
    NTSTATUS status = ext->dxgk_interface.DxgkCbGetDeviceInformation(
        ext->dxgk_handle, &device_info);

    if (!NT_SUCCESS(status)) {
        JACKGPU_KMD_ERR("DxgkCbGetDeviceInformation failed: 0x%08X", status);
        return status;
    }

    /* Map each BAR reported by the framework */
    for (ULONG i = 0; i < device_info.TranslatedResourceList->List[0].PartialResourceList.Count; i++) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR res =
            &device_info.TranslatedResourceList->List[0].PartialResourceList.PartialDescriptors[i];

        if (res->Type == CmResourceTypeMemory) {
            PHYSICAL_ADDRESS phys = res->u.Memory.Start;
            SIZE_T length = res->u.Memory.Length;

            /* Find the first available BAR slot */
            for (ULONG bar = 0; bar < 6; bar++) {
                if (!ext->bar_mapped[bar]) {
                    ext->bar_mapped[bar] = MmMapIoSpace(phys, length, MmNonCached);
                    ext->bar_size[bar] = length;
                    JACKGPU_KMD_LOG("BAR%lu mapped: phys=0x%llX size=0x%lX va=%p",
                                    bar, phys.QuadPart, (ULONG)length, ext->bar_mapped[bar]);
                    break;
                }
            }
        }
    }

    /* Parse PCI capabilities to find virtio config structures */
    status = jackgpu_virtio_init(ext);
    if (!NT_SUCCESS(status)) {
        JACKGPU_KMD_ERR("virtio init failed: 0x%08X", status);
        return status;
    }

    /* Initialize controlq for GPU commands */
    status = jackgpu_vq_init(ext, &ext->controlq, VIRTGPU_VQ_CONTROLQ);
    if (!NT_SUCCESS(status)) {
        JACKGPU_KMD_ERR("controlq init failed: 0x%08X", status);
        return status;
    }

    /* Display-only: 1 source, 1 child (monitor) */
    *NumberOfVideoPresentSources = 1;
    *NumberOfChildren = 1;

    /* Connect interrupt */
    DXGK_DEVICE_INFO interrupt_info;
    ext->interrupt_connected = TRUE;

    JACKGPU_KMD_LOG("device started successfully");
    return STATUS_SUCCESS;
}

/* ── DxgkDdiStopDevice ───────────────────────────────────────── */

NTSTATUS jackgpu_ddi_stop_device(
    _In_ PVOID MiniportDeviceContext)
{
    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)MiniportDeviceContext;

    JACKGPU_KMD_LOG("DxgkDdiStopDevice");

    /* Reset virtio device */
    jackgpu_virtio_reset(ext);

    /* Destroy virtqueues */
    jackgpu_vq_destroy(ext, &ext->controlq);

    /* Unmap BARs */
    for (ULONG i = 0; i < 6; i++) {
        if (ext->bar_mapped[i]) {
            MmUnmapIoSpace(ext->bar_mapped[i], ext->bar_size[i]);
            ext->bar_mapped[i] = NULL;
        }
    }

    return STATUS_SUCCESS;
}

/* ── DxgkDdiRemoveDevice ─────────────────────────────────────── */

NTSTATUS jackgpu_ddi_remove_device(
    _In_ PVOID MiniportDeviceContext)
{
    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)MiniportDeviceContext;

    JACKGPU_KMD_LOG("DxgkDdiRemoveDevice");

    if (ext) {
        ExFreePoolWithTag(ext, JACKGPU_TAG);
    }

    return STATUS_SUCCESS;
}

/* ── DxgkDdiInterruptRoutine ─────────────────────────────────── */

BOOLEAN jackgpu_ddi_interrupt_routine(
    _In_ PVOID MiniportDeviceContext,
    _In_ ULONG MessageNumber)
{
    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)MiniportDeviceContext;
    UNREFERENCED_PARAMETER(MessageNumber);

    if (!ext->isr_cfg) return FALSE;

    /* Read ISR status to acknowledge interrupt */
    UINT8 isr = READ_REGISTER_UCHAR((volatile UCHAR *)ext->isr_cfg);
    if (isr == 0) return FALSE;

    /* Schedule DPC for actual work */
    ext->dxgk_interface.DxgkCbQueueDpc(ext->dxgk_handle);

    return TRUE;
}

/* ── DxgkDdiDpcRoutine ───────────────────────────────────────── */

VOID jackgpu_ddi_dpc_routine(
    _In_ PVOID MiniportDeviceContext)
{
    PJACKGPU_DEVICE_EXTENSION ext = (PJACKGPU_DEVICE_EXTENSION)MiniportDeviceContext;

    /* Process completed commands in controlq */
    JACKGPU_VIRTQUEUE *vq = &ext->controlq;
    KIRQL old_irql;

    KeAcquireSpinLock(&vq->lock, &old_irql);

    while (vq->last_used_idx != vq->used->idx) {
        UINT16 idx = vq->last_used_idx & (vq->size - 1);
        struct virtq_used_elem *used = &vq->used->ring[idx];

        /* Signal completion event if pending */
        UINT16 desc_idx = (UINT16)used->id;
        if (desc_idx < vq->size && vq->pending[desc_idx].event) {
            KeSetEvent(vq->pending[desc_idx].event, IO_NO_INCREMENT, FALSE);
            vq->pending[desc_idx].event = NULL;
        }

        /* Return descriptor to free list */
        vq->desc[desc_idx].next = vq->free_head;
        vq->free_head = desc_idx;
        vq->num_free++;

        vq->last_used_idx++;
    }

    KeReleaseSpinLock(&vq->lock, old_irql);

    /* Signal cmd_complete for synchronous waits */
    KeSetEvent(&ext->cmd_complete_event, IO_NO_INCREMENT, FALSE);
}

/* ── DxgkDdiQueryChildRelations ──────────────────────────────── */

NTSTATUS jackgpu_ddi_query_child_relations(
    _In_ PVOID MiniportDeviceContext,
    _Inout_ PDXGK_CHILD_DESCRIPTOR ChildRelations,
    _In_ ULONG ChildRelationsSize)
{
    UNREFERENCED_PARAMETER(MiniportDeviceContext);

    if (ChildRelationsSize < sizeof(DXGK_CHILD_DESCRIPTOR))
        return STATUS_BUFFER_TOO_SMALL;

    /* One child: the display output */
    ChildRelations[0].ChildDeviceType = TypeVideoOutput;
    ChildRelations[0].ChildCapabilities.HpdAwareness = HpdAwarenessAlwaysConnected;
    ChildRelations[0].ChildCapabilities.Type.VideoOutput.InterfaceTechnology = D3DKMDT_VOT_OTHER;
    ChildRelations[0].ChildCapabilities.Type.VideoOutput.MonitorOrientationAwareness =
        D3DKMDT_MOA_NONE;
    ChildRelations[0].ChildCapabilities.Type.VideoOutput.SupportsSdtvModes = FALSE;
    ChildRelations[0].AcpiUid = 0;
    ChildRelations[0].ChildUid = 1;

    return STATUS_SUCCESS;
}

/* ── DxgkDdiQueryChildStatus ─────────────────────────────────── */

NTSTATUS jackgpu_ddi_query_child_status(
    _In_ PVOID MiniportDeviceContext,
    _Inout_ PDXGK_CHILD_STATUS ChildStatus,
    _In_ BOOLEAN NonDestructiveOnly)
{
    UNREFERENCED_PARAMETER(MiniportDeviceContext);
    UNREFERENCED_PARAMETER(NonDestructiveOnly);

    if (ChildStatus->ChildUid == 1) {
        ChildStatus->Type = StatusConnection;
        ChildStatus->HotPlug.Connected = TRUE;
        return STATUS_SUCCESS;
    }

    return STATUS_INVALID_PARAMETER;
}

/* ── DxgkDdiQueryDeviceDescriptor ────────────────────────────── */

NTSTATUS jackgpu_ddi_query_device_descriptor(
    _In_    PVOID MiniportDeviceContext,
    _In_    ULONG ChildUid,
    _Inout_ PDXGK_DEVICE_DESCRIPTOR DeviceDescriptor)
{
    UNREFERENCED_PARAMETER(MiniportDeviceContext);
    UNREFERENCED_PARAMETER(ChildUid);
    UNREFERENCED_PARAMETER(DeviceDescriptor);

    /* No EDID — the framework will use a default mode */
    return STATUS_MONITOR_NO_DESCRIPTOR;
}

/* ── DxgkDdiSetPowerState ────────────────────────────────────── */

NTSTATUS jackgpu_ddi_set_power_state(
    _In_ PVOID MiniportDeviceContext,
    _In_ ULONG HardwareUid,
    _In_ DEVICE_POWER_STATE DevicePowerState,
    _In_ POWER_ACTION ActionType)
{
    UNREFERENCED_PARAMETER(MiniportDeviceContext);
    UNREFERENCED_PARAMETER(HardwareUid);
    UNREFERENCED_PARAMETER(DevicePowerState);
    UNREFERENCED_PARAMETER(ActionType);

    return STATUS_SUCCESS;
}

/* ── DxgkDdiUnload ───────────────────────────────────────────── */

VOID jackgpu_ddi_unload(VOID)
{
    JACKGPU_KMD_LOG("DxgkDdiUnload");
}
