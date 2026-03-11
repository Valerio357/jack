/*
 * instance.h — VkInstance implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_INSTANCE_H
#define JACKGPU_INSTANCE_H

#include "driver/jackgpu.h"
#include "transport/virtgpu.h"

struct jackgpu_instance {
    VK_LOADER_DATA loader_data;

    jackgpu_transport transport;

    /* Physical devices discovered from host */
    jackgpu_phys_dev *physical_devices;
    uint32_t          physical_device_count;

    /* Vulkan API version negotiated with host */
    uint32_t api_version;

    /* Object ID counter */
    venus_object_id venus_id;
};

VkResult jackgpu_CreateInstance(const VkInstanceCreateInfo *pCreateInfo,
                                const VkAllocationCallbacks *pAllocator,
                                VkInstance *pInstance);

void jackgpu_DestroyInstance(VkInstance instance,
                              const VkAllocationCallbacks *pAllocator);

VkResult jackgpu_EnumeratePhysicalDevices(VkInstance instance,
                                           uint32_t *pPhysicalDeviceCount,
                                           VkPhysicalDevice *pPhysicalDevices);

VkResult jackgpu_EnumerateInstanceVersion(uint32_t *pApiVersion);

VkResult jackgpu_EnumerateInstanceExtensionProperties(
    const char *pLayerName,
    uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties);

VkResult jackgpu_EnumerateInstanceLayerProperties(
    uint32_t *pPropertyCount,
    VkLayerProperties *pProperties);

#endif /* JACKGPU_INSTANCE_H */
