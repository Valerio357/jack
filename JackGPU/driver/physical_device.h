/*
 * physical_device.h — VkPhysicalDevice implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_PHYSICAL_DEVICE_H
#define JACKGPU_PHYSICAL_DEVICE_H

#include "driver/jackgpu.h"

struct jackgpu_phys_dev {
    VK_LOADER_DATA loader_data;

    jackgpu_instance *instance;
    venus_object_id   venus_id;

    /* Cached properties from host */
    VkPhysicalDeviceProperties       properties;
    VkPhysicalDeviceFeatures         features;
    VkPhysicalDeviceMemoryProperties memory_properties;

    VkQueueFamilyProperties *queue_family_properties;
    uint32_t                 queue_family_count;
};

/* Query physical devices from host renderer */
VkResult jackgpu_enumerate_physical_devices_from_host(jackgpu_instance *inst);

/* Vulkan entry points */
void jackgpu_GetPhysicalDeviceProperties(VkPhysicalDevice physicalDevice,
                                          VkPhysicalDeviceProperties *pProperties);

void jackgpu_GetPhysicalDeviceFeatures(VkPhysicalDevice physicalDevice,
                                        VkPhysicalDeviceFeatures *pFeatures);

void jackgpu_GetPhysicalDeviceMemoryProperties(VkPhysicalDevice physicalDevice,
                                                VkPhysicalDeviceMemoryProperties *pMemoryProperties);

void jackgpu_GetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice physicalDevice,
                                                      uint32_t *pQueueFamilyPropertyCount,
                                                      VkQueueFamilyProperties *pQueueFamilyProperties);

void jackgpu_GetPhysicalDeviceFormatProperties(VkPhysicalDevice physicalDevice,
                                                VkFormat format,
                                                VkFormatProperties *pFormatProperties);

VkResult jackgpu_EnumerateDeviceExtensionProperties(VkPhysicalDevice physicalDevice,
                                                     const char *pLayerName,
                                                     uint32_t *pPropertyCount,
                                                     VkExtensionProperties *pProperties);

#endif /* JACKGPU_PHYSICAL_DEVICE_H */
