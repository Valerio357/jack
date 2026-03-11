/*
 * jackgpu_kmd.h — JackGPU WDDM Kernel-Mode Display-Only Driver
 *
 * KMDOD (Display-Only) driver for virtio-gpu PCI device.
 * Handles DxgkDdiEscape calls from the JackGPU Vulkan ICD (userspace),
 * translating them into virtio-gpu virtqueue commands to the host.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_KMD_H
#define JACKGPU_KMD_H

#include <ntddk.h>
#include <dispmprt.h>
#include <d3dkmddi.h>
#include <d3dkmdt.h>

/* ── Logging ─────────────────────────────────────────────────── */

#define JACKGPU_TAG 'GPKJ'

#define JACKGPU_KMD_LOG(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_INFO_LEVEL, \
               "[JackGPU] " fmt "\n", ##__VA_ARGS__)

#define JACKGPU_KMD_ERR(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_ERROR_LEVEL, \
               "[JackGPU ERROR] " fmt "\n", ##__VA_ARGS__)

/* ── Virtio-GPU PCI constants ────────────────────────────────── */

#define VIRTIO_GPU_VENDOR_ID        0x1AF4
#define VIRTIO_GPU_DEVICE_ID        0x1050  /* virtio 1.0+ GPU */
#define VIRTIO_GPU_DEVICE_ID_TRANS  0x1040  /* transitional */

/* Virtio common config registers (capabilities) */
#define VIRTIO_PCI_CAP_COMMON_CFG   1
#define VIRTIO_PCI_CAP_NOTIFY_CFG   2
#define VIRTIO_PCI_CAP_ISR_CFG      3
#define VIRTIO_PCI_CAP_DEVICE_CFG   4

/* Virtio device status bits */
#define VIRTIO_STATUS_ACKNOWLEDGE   0x01
#define VIRTIO_STATUS_DRIVER        0x02
#define VIRTIO_STATUS_FEATURES_OK   0x08
#define VIRTIO_STATUS_DRIVER_OK     0x04
#define VIRTIO_STATUS_FAILED        0x80

/* Virtio-GPU virtqueue indices */
#define VIRTGPU_VQ_CONTROLQ    0  /* 2D/control commands */
#define VIRTGPU_VQ_CURSORQ     1  /* cursor commands */
#define VIRTGPU_VQ_MAX         2

/* ── Virtio-GPU command types ────────────────────────────────── */

#define VIRTIO_GPU_CMD_GET_DISPLAY_INFO     0x0100
#define VIRTIO_GPU_CMD_RESOURCE_CREATE_2D   0x0101
#define VIRTIO_GPU_CMD_RESOURCE_UNREF       0x0102
#define VIRTIO_GPU_CMD_SET_SCANOUT          0x0103
#define VIRTIO_GPU_CMD_RESOURCE_FLUSH       0x0104
#define VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D  0x0105
#define VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING 0x0106
#define VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING 0x0107

/* 3D commands (Venus/virgl) */
#define VIRTIO_GPU_CMD_CTX_CREATE           0x0200
#define VIRTIO_GPU_CMD_CTX_DESTROY          0x0201
#define VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE  0x0202
#define VIRTIO_GPU_CMD_CTX_DETACH_RESOURCE  0x0203
#define VIRTIO_GPU_CMD_RESOURCE_CREATE_3D   0x0204
#define VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D  0x0205
#define VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D 0x0206
#define VIRTIO_GPU_CMD_SUBMIT_3D            0x0207

/* Blob commands */
#define VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB 0x010C
#define VIRTIO_GPU_CMD_SET_SCANOUT_BLOB     0x010D
#define VIRTIO_GPU_CMD_RESOURCE_MAP_BLOB    0x010E
#define VIRTIO_GPU_CMD_RESOURCE_UNMAP_BLOB  0x010F

/* Response types */
#define VIRTIO_GPU_RESP_OK_NODATA           0x1100
#define VIRTIO_GPU_RESP_OK_DISPLAY_INFO     0x1101
#define VIRTIO_GPU_RESP_OK_CAPSET_INFO      0x1102
#define VIRTIO_GPU_RESP_OK_CAPSET           0x1103
#define VIRTIO_GPU_RESP_OK_MAP_INFO         0x1104
#define VIRTIO_GPU_RESP_ERR_UNSPEC          0x1200

/* Capset IDs */
#define VIRTIO_GPU_CAPSET_VIRGL    1
#define VIRTIO_GPU_CAPSET_VIRGL2   2
#define VIRTIO_GPU_CAPSET_VENUS    5

/* ── Virtio-GPU wire structures ──────────────────────────────── */

#pragma pack(push, 1)

struct virtio_gpu_ctrl_hdr {
    UINT32 type;
    UINT32 flags;
    UINT64 fence_id;
    UINT32 ctx_id;
    UINT32 ring_idx;
    UINT8  padding[16];
};

struct virtio_gpu_cmd_get_capset_info {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 capset_index;
    UINT32 padding;
};

struct virtio_gpu_resp_capset_info {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 capset_id;
    UINT32 capset_max_version;
    UINT32 capset_max_size;
    UINT32 padding;
};

struct virtio_gpu_cmd_get_capset {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 capset_id;
    UINT32 capset_version;
};

struct virtio_gpu_resp_capset {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT8 capset_data[];
};

struct virtio_gpu_cmd_ctx_create {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 nlen;
    UINT32 context_init;
    char   debug_name[64];
};

struct virtio_gpu_cmd_submit_3d {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 size;
    UINT32 padding;
};

struct virtio_gpu_resource_create_blob {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 resource_id;
    UINT32 blob_mem;
    UINT32 blob_flags;
    UINT32 nr_entries;
    UINT64 blob_id;
    UINT64 size;
};

struct virtio_gpu_resource_map_blob {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 resource_id;
    UINT32 padding;
    UINT64 offset;
};

struct virtio_gpu_resp_map_info {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 map_info;
    UINT32 padding;
};

struct virtio_gpu_resource_unmap_blob {
    struct virtio_gpu_ctrl_hdr hdr;
    UINT32 resource_id;
    UINT32 padding;
};

#pragma pack(pop)

/* ── Virtqueue descriptor ────────────────────────────────────── */

#define VIRTQ_DESC_F_NEXT       1
#define VIRTQ_DESC_F_WRITE      2
#define VIRTQ_DESC_F_INDIRECT   4

struct virtq_desc {
    UINT64 addr;
    UINT32 len;
    UINT16 flags;
    UINT16 next;
};

struct virtq_avail {
    UINT16 flags;
    UINT16 idx;
    UINT16 ring[];
    /* UINT16 used_event; at end */
};

struct virtq_used_elem {
    UINT32 id;
    UINT32 len;
};

struct virtq_used {
    UINT16 flags;
    UINT16 idx;
    struct virtq_used_elem ring[];
    /* UINT16 avail_event; at end */
};

/* ── Virtqueue state ─────────────────────────────────────────── */

#define JACKGPU_VQ_SIZE 256

typedef struct _JACKGPU_VIRTQUEUE {
    /* Descriptor table (physically contiguous) */
    struct virtq_desc  *desc;
    struct virtq_avail *avail;
    struct virtq_used  *used;
    PHYSICAL_ADDRESS    desc_phys;
    PHYSICAL_ADDRESS    avail_phys;
    PHYSICAL_ADDRESS    used_phys;

    /* Queue configuration */
    UINT16 size;           /* Number of descriptors */
    UINT16 free_head;      /* Head of free descriptor list */
    UINT16 num_free;       /* Number of free descriptors */
    UINT16 last_used_idx;  /* Last used index we processed */

    /* Notification register */
    volatile UINT16 *notify;

    /* DMA memory for queue rings */
    PVOID  ring_mem;
    SIZE_T ring_mem_size;
    PHYSICAL_ADDRESS ring_mem_phys;

    /* Pending request tracking */
    struct {
        PVOID   data;
        SIZE_T  size;
        KEVENT  *event;
    } pending[JACKGPU_VQ_SIZE];

    KSPIN_LOCK lock;
} JACKGPU_VIRTQUEUE;

/* ── Per-context state ───────────────────────────────────────── */

typedef struct _JACKGPU_CONTEXT {
    UINT32 context_id;
    UINT32 capset_id;
    UINT32 num_rings;
    BOOLEAN active;
} JACKGPU_CONTEXT;

/* ── Blob resource tracking ──────────────────────────────────── */

#define JACKGPU_MAX_RESOURCES 1024

typedef struct _JACKGPU_RESOURCE {
    UINT32 resource_id;
    UINT64 size;
    UINT64 blob_id;
    UINT32 blob_mem;
    UINT32 blob_flags;

    /* Mapping state */
    PVOID  mapped_kernel;     /* Kernel VA of mapped memory */
    PVOID  mapped_user;       /* User VA (MDL mapping) */
    PMDL   mdl;              /* Memory Descriptor List for user mapping */
    PHYSICAL_ADDRESS phys;   /* Physical address of backing */

    BOOLEAN in_use;
} JACKGPU_RESOURCE;

/* ── Device extension (per-adapter state) ────────────────────── */

typedef struct _JACKGPU_DEVICE_EXTENSION {
    /* DXGK handle */
    PVOID dxgk_handle;
    DXGKRNL_INTERFACE dxgk_interface;

    /* PCI BAR mappings */
    PVOID bar_mapped[6];
    SIZE_T bar_size[6];

    /* Virtio common config pointer (from PCI capabilities) */
    volatile UINT8 *common_cfg;
    volatile UINT8 *isr_cfg;
    volatile UINT8 *device_cfg;
    volatile UINT8 *notify_cfg;
    UINT32 notify_off_multiplier;

    /* Virtqueues */
    JACKGPU_VIRTQUEUE controlq;
    JACKGPU_VIRTQUEUE cursorq;

    /* Resource ID counter */
    UINT32 next_resource_id;

    /* Context tracking */
    JACKGPU_CONTEXT contexts[64];
    UINT32 next_context_id;

    /* Resource tracking */
    JACKGPU_RESOURCE resources[JACKGPU_MAX_RESOURCES];
    KSPIN_LOCK resource_lock;

    /* DPC and ISR */
    BOOLEAN interrupt_connected;
    KDPC    dpc;

    /* Synchronization */
    KEVENT  cmd_complete_event;
    KSPIN_LOCK cmd_lock;

} JACKGPU_DEVICE_EXTENSION, *PJACKGPU_DEVICE_EXTENSION;

/* ── Escape command definitions (must match d3dkmt.h in ICD) ── */

#define JACKGPU_ESCAPE_GET_CAPSET       0x01
#define JACKGPU_ESCAPE_CREATE_CONTEXT   0x02
#define JACKGPU_ESCAPE_DESTROY_CONTEXT  0x03
#define JACKGPU_ESCAPE_CREATE_BLOB      0x04
#define JACKGPU_ESCAPE_MAP_BLOB         0x05
#define JACKGPU_ESCAPE_UNMAP_BLOB       0x06
#define JACKGPU_ESCAPE_DESTROY_RESOURCE 0x07
#define JACKGPU_ESCAPE_EXECBUFFER       0x08
#define JACKGPU_ESCAPE_CREATE_RING      0x09
#define JACKGPU_ESCAPE_DESTROY_RING     0x0A
#define JACKGPU_ESCAPE_NOTIFY_RING      0x0B
#define JACKGPU_ESCAPE_SET_REPLY_STREAM 0x0C

/* Escape header — shared with userspace */
struct jackgpu_escape_header {
    UINT32 cmd;
    UINT32 size;
    INT32  result;
};

/* ── Function prototypes ─────────────────────────────────────── */

/* jackgpu_kmd.c — DDI callbacks */
NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath);

NTSTATUS jackgpu_ddi_add_device(
    CONST PDEVICE_OBJECT PhysicalDeviceObject,
    PVOID MiniportDeviceContext,
    PVOID *DeviceContext);

NTSTATUS jackgpu_ddi_start_device(
    PVOID MiniportDeviceContext,
    PDXGK_START_INFO DxgkStartInfo,
    PDXGKRNL_INTERFACE DxgkInterface,
    PULONG NumberOfVideoPresentSources,
    PULONG NumberOfChildren);

NTSTATUS jackgpu_ddi_stop_device(PVOID MiniportDeviceContext);
NTSTATUS jackgpu_ddi_remove_device(PVOID MiniportDeviceContext);

BOOLEAN jackgpu_ddi_interrupt_routine(
    PVOID MiniportDeviceContext,
    ULONG MessageNumber);

VOID jackgpu_ddi_dpc_routine(PVOID MiniportDeviceContext);

NTSTATUS jackgpu_ddi_query_child_relations(
    PVOID MiniportDeviceContext,
    PDXGK_CHILD_DESCRIPTOR ChildRelations,
    ULONG ChildRelationsSize);

NTSTATUS jackgpu_ddi_query_child_status(
    PVOID MiniportDeviceContext,
    PDXGK_CHILD_STATUS ChildStatus,
    BOOLEAN NonDestructiveOnly);

NTSTATUS jackgpu_ddi_query_device_descriptor(
    PVOID MiniportDeviceContext,
    ULONG ChildUid,
    PDXGK_DEVICE_DESCRIPTOR DeviceDescriptor);

NTSTATUS jackgpu_ddi_set_power_state(
    PVOID MiniportDeviceContext,
    ULONG HardwareUid,
    DEVICE_POWER_STATE DevicePowerState,
    POWER_ACTION ActionType);

VOID jackgpu_ddi_unload(VOID);

/* escape.c — Escape command handler */
NTSTATUS jackgpu_ddi_escape(
    PVOID MiniportDeviceContext,
    CONST DXGKARG_ESCAPE *pEscape);

/* virtqueue.c — Virtqueue management */
NTSTATUS jackgpu_vq_init(
    PJACKGPU_DEVICE_EXTENSION ext,
    JACKGPU_VIRTQUEUE *vq,
    UINT16 queue_idx);

VOID jackgpu_vq_destroy(
    PJACKGPU_DEVICE_EXTENSION ext,
    JACKGPU_VIRTQUEUE *vq);

NTSTATUS jackgpu_vq_send_command(
    PJACKGPU_DEVICE_EXTENSION ext,
    JACKGPU_VIRTQUEUE *vq,
    PVOID cmd, UINT32 cmd_size,
    PVOID resp, UINT32 resp_size);

VOID jackgpu_virtio_set_status(
    PJACKGPU_DEVICE_EXTENSION ext,
    UINT8 status);

UINT8 jackgpu_virtio_get_status(
    PJACKGPU_DEVICE_EXTENSION ext);

VOID jackgpu_virtio_reset(
    PJACKGPU_DEVICE_EXTENSION ext);

NTSTATUS jackgpu_virtio_init(
    PJACKGPU_DEVICE_EXTENSION ext);

/* Resource management helpers */
JACKGPU_RESOURCE *jackgpu_alloc_resource(PJACKGPU_DEVICE_EXTENSION ext);
JACKGPU_RESOURCE *jackgpu_find_resource(PJACKGPU_DEVICE_EXTENSION ext, UINT32 handle);
VOID jackgpu_free_resource(PJACKGPU_DEVICE_EXTENSION ext, JACKGPU_RESOURCE *res);

#endif /* JACKGPU_KMD_H */
