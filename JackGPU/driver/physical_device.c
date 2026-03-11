/*
 * physical_device.c — VkPhysicalDevice implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/physical_device.h"
#include "driver/instance.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

VkResult jackgpu_enumerate_physical_devices_from_host(jackgpu_instance *inst) {
    jackgpu_transport *tp = &inst->transport;

    /* 1. Query physical device count */
    uint8_t cmd_buf[256];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkEnumeratePhysicalDevices, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, inst->venus_id);  /* instance handle */
    venus_enc_uint32(&enc, 0);  /* pPhysicalDeviceCount = 0 (query count) */
    venus_enc_pointer(&enc, NULL);  /* pPhysicalDevices = NULL */

    uint8_t reply_buf[1024];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) return result;

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);

    uint32_t count = venus_dec_uint32(&dec);
    if (count == 0) {
        JACKGPU_ERR("no physical devices on host");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    JACKGPU_LOG("host reports %u physical device(s)", count);

    /* 2. Allocate and query physical device handles */
    inst->physical_devices = (jackgpu_phys_dev *)calloc(count, sizeof(jackgpu_phys_dev));
    if (!inst->physical_devices) return VK_ERROR_OUT_OF_HOST_MEMORY;
    inst->physical_device_count = count;

    /* Re-query with space for handles */
    venus_enc_reset(&enc);
    venus_enc_cmd_header(&enc, VENUS_CMD_vkEnumeratePhysicalDevices, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, inst->venus_id);
    venus_enc_uint32(&enc, count);
    venus_enc_pointer(&enc, (void *)1); /* non-NULL = give me handles */
    venus_enc_array_size(&enc, count);

    result = jackgpu_transport_submit_cmd(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc),
                                          reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) return result;

    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    host_result = venus_dec_reply_header(&dec);
    count = venus_dec_uint32(&dec);

    /* Read host-side object IDs for each physical device */
    uint64_t arr_size = venus_dec_array_size(&dec);
    for (uint32_t i = 0; i < count && i < arr_size; i++) {
        jackgpu_phys_dev *pd = &inst->physical_devices[i];
        set_loader_magic_value(pd);
        pd->instance = inst;
        pd->venus_id = venus_dec_handle(&dec);
        JACKGPU_LOG("physical device %u: venus_id=%llu", i, pd->venus_id);
    }

    /* 3. Query properties for each physical device */
    for (uint32_t i = 0; i < count; i++) {
        jackgpu_phys_dev *pd = &inst->physical_devices[i];

        /* GetPhysicalDeviceProperties */
        venus_enc_reset(&enc);
        venus_enc_cmd_header(&enc, VENUS_CMD_vkGetPhysicalDeviceProperties, VENUS_CMD_REPLY_BIT);
        venus_enc_handle(&enc, pd->venus_id);

        result = jackgpu_transport_submit_cmd(tp,
                                              venus_enc_data(&enc),
                                              venus_enc_size(&enc),
                                              reply_buf, sizeof(reply_buf));
        if (result == VK_SUCCESS) {
            venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
            venus_dec_reply_header(&dec);
            venus_dec_VkPhysicalDeviceProperties(&dec, &pd->properties);
            JACKGPU_LOG("  device: %s (type=%d)", pd->properties.deviceName,
                        pd->properties.deviceType);
        }

        /* GetPhysicalDeviceFeatures */
        venus_enc_reset(&enc);
        venus_enc_cmd_header(&enc, VENUS_CMD_vkGetPhysicalDeviceFeatures, VENUS_CMD_REPLY_BIT);
        venus_enc_handle(&enc, pd->venus_id);

        result = jackgpu_transport_submit_cmd(tp,
                                              venus_enc_data(&enc),
                                              venus_enc_size(&enc),
                                              reply_buf, sizeof(reply_buf));
        if (result == VK_SUCCESS) {
            venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
            venus_dec_reply_header(&dec);
            venus_dec_VkPhysicalDeviceFeatures(&dec, &pd->features);
        }

        /* GetPhysicalDeviceMemoryProperties */
        venus_enc_reset(&enc);
        venus_enc_cmd_header(&enc, VENUS_CMD_vkGetPhysicalDeviceMemoryProperties, VENUS_CMD_REPLY_BIT);
        venus_enc_handle(&enc, pd->venus_id);

        result = jackgpu_transport_submit_cmd(tp,
                                              venus_enc_data(&enc),
                                              venus_enc_size(&enc),
                                              reply_buf, sizeof(reply_buf));
        if (result == VK_SUCCESS) {
            venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
            venus_dec_reply_header(&dec);
            venus_dec_VkPhysicalDeviceMemoryProperties(&dec, &pd->memory_properties);
        }

        /* GetPhysicalDeviceQueueFamilyProperties — query count first */
        venus_enc_reset(&enc);
        venus_enc_cmd_header(&enc, VENUS_CMD_vkGetPhysicalDeviceQueueFamilyProperties, VENUS_CMD_REPLY_BIT);
        venus_enc_handle(&enc, pd->venus_id);
        venus_enc_uint32(&enc, 0);
        venus_enc_pointer(&enc, NULL);

        result = jackgpu_transport_submit_cmd(tp,
                                              venus_enc_data(&enc),
                                              venus_enc_size(&enc),
                                              reply_buf, sizeof(reply_buf));
        if (result == VK_SUCCESS) {
            venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
            venus_dec_reply_header(&dec);
            pd->queue_family_count = venus_dec_uint32(&dec);

            pd->queue_family_properties = (VkQueueFamilyProperties *)
                calloc(pd->queue_family_count, sizeof(VkQueueFamilyProperties));

            /* Query actual properties */
            venus_enc_reset(&enc);
            venus_enc_cmd_header(&enc, VENUS_CMD_vkGetPhysicalDeviceQueueFamilyProperties, VENUS_CMD_REPLY_BIT);
            venus_enc_handle(&enc, pd->venus_id);
            venus_enc_uint32(&enc, pd->queue_family_count);
            venus_enc_pointer(&enc, (void *)1);
            venus_enc_array_size(&enc, pd->queue_family_count);

            result = jackgpu_transport_submit_cmd(tp,
                                                  venus_enc_data(&enc),
                                                  venus_enc_size(&enc),
                                                  reply_buf, sizeof(reply_buf));
            if (result == VK_SUCCESS) {
                venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
                venus_dec_reply_header(&dec);
                uint32_t qf_count = venus_dec_uint32(&dec);
                venus_dec_array_size(&dec);
                for (uint32_t q = 0; q < qf_count; q++) {
                    venus_dec_VkQueueFamilyProperties(&dec, &pd->queue_family_properties[q]);
                }
            }
        }
    }

    return VK_SUCCESS;
}

void jackgpu_GetPhysicalDeviceProperties(VkPhysicalDevice physicalDevice,
                                          VkPhysicalDeviceProperties *pProperties) {
    jackgpu_phys_dev *pd = (jackgpu_phys_dev *)physicalDevice;
    *pProperties = pd->properties;
}

void jackgpu_GetPhysicalDeviceFeatures(VkPhysicalDevice physicalDevice,
                                        VkPhysicalDeviceFeatures *pFeatures) {
    jackgpu_phys_dev *pd = (jackgpu_phys_dev *)physicalDevice;
    *pFeatures = pd->features;
}

void jackgpu_GetPhysicalDeviceMemoryProperties(VkPhysicalDevice physicalDevice,
                                                VkPhysicalDeviceMemoryProperties *pMemoryProperties) {
    jackgpu_phys_dev *pd = (jackgpu_phys_dev *)physicalDevice;
    *pMemoryProperties = pd->memory_properties;
}

void jackgpu_GetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice physicalDevice,
                                                      uint32_t *pQueueFamilyPropertyCount,
                                                      VkQueueFamilyProperties *pQueueFamilyProperties) {
    jackgpu_phys_dev *pd = (jackgpu_phys_dev *)physicalDevice;

    if (!pQueueFamilyProperties) {
        *pQueueFamilyPropertyCount = pd->queue_family_count;
        return;
    }

    uint32_t copy = *pQueueFamilyPropertyCount < pd->queue_family_count
                  ? *pQueueFamilyPropertyCount : pd->queue_family_count;
    memcpy(pQueueFamilyProperties, pd->queue_family_properties,
           copy * sizeof(VkQueueFamilyProperties));
    *pQueueFamilyPropertyCount = copy;
}

void jackgpu_GetPhysicalDeviceFormatProperties(VkPhysicalDevice physicalDevice,
                                                VkFormat format,
                                                VkFormatProperties *pFormatProperties) {
    /* TODO: query from host */
    JACKGPU_UNUSED(physicalDevice);
    JACKGPU_UNUSED(format);
    memset(pFormatProperties, 0, sizeof(*pFormatProperties));
}

VkResult jackgpu_EnumerateDeviceExtensionProperties(VkPhysicalDevice physicalDevice,
                                                     const char *pLayerName,
                                                     uint32_t *pPropertyCount,
                                                     VkExtensionProperties *pProperties) {
    JACKGPU_UNUSED(physicalDevice);
    JACKGPU_UNUSED(pLayerName);

    /* Device extensions we expose — queried from host capset */
    static const VkExtensionProperties extensions[] = {
        { VK_KHR_SWAPCHAIN_EXTENSION_NAME, 70 },
        { VK_KHR_MAINTENANCE1_EXTENSION_NAME, 2 },
        { VK_KHR_MAINTENANCE2_EXTENSION_NAME, 1 },
        { VK_KHR_MAINTENANCE3_EXTENSION_NAME, 1 },
    };
    uint32_t count = JACKGPU_ARRAY_SIZE(extensions);

    if (!pProperties) {
        *pPropertyCount = count;
        return VK_SUCCESS;
    }

    uint32_t copy = *pPropertyCount < count ? *pPropertyCount : count;
    memcpy(pProperties, extensions, copy * sizeof(VkExtensionProperties));
    *pPropertyCount = copy;

    return copy < count ? VK_INCOMPLETE : VK_SUCCESS;
}
