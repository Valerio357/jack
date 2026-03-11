/*
 * device.h — VkDevice implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_DEVICE_H
#define JACKGPU_DEVICE_H

#include "driver/jackgpu.h"

#define JACKGPU_MAX_QUEUES 16

struct jackgpu_device {
    VK_LOADER_DATA loader_data;

    jackgpu_instance  *instance;
    jackgpu_phys_dev  *physical_device;
    venus_object_id    venus_id;

    /* Queues created with the device */
    jackgpu_queue *queues;
    uint32_t       queue_count;
};

VkResult jackgpu_CreateDevice(VkPhysicalDevice physicalDevice,
                               const VkDeviceCreateInfo *pCreateInfo,
                               const VkAllocationCallbacks *pAllocator,
                               VkDevice *pDevice);

void jackgpu_DestroyDevice(VkDevice device,
                            const VkAllocationCallbacks *pAllocator);

VkResult jackgpu_DeviceWaitIdle(VkDevice device);

#endif /* JACKGPU_DEVICE_H */
