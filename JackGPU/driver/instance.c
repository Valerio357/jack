/*
 * instance.c — VkInstance implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/instance.h"
#include "driver/physical_device.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

VkResult jackgpu_EnumerateInstanceVersion(uint32_t *pApiVersion) {
    *pApiVersion = VK_MAKE_API_VERSION(0, 1, 3, 0);
    return VK_SUCCESS;
}

VkResult jackgpu_EnumerateInstanceExtensionProperties(
    const char *pLayerName,
    uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties) {
    JACKGPU_UNUSED(pLayerName);

    /* Extensions we support — will be populated from host capset */
    static const VkExtensionProperties extensions[] = {
        { VK_KHR_SURFACE_EXTENSION_NAME, 25 },
        { VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME, 2 },
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

VkResult jackgpu_EnumerateInstanceLayerProperties(
    uint32_t *pPropertyCount,
    VkLayerProperties *pProperties) {
    JACKGPU_UNUSED(pProperties);
    *pPropertyCount = 0;
    return VK_SUCCESS;
}

VkResult jackgpu_CreateInstance(const VkInstanceCreateInfo *pCreateInfo,
                                const VkAllocationCallbacks *pAllocator,
                                VkInstance *pInstance) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_instance *inst = (jackgpu_instance *)calloc(1, sizeof(jackgpu_instance));
    if (!inst)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    /* Set loader dispatch magic */
    set_loader_magic_value(inst);

    /* Initialize transport (opens virtio-gpu device, creates Venus context,
     * sets up ring buffer and shared memory) */
    VkResult result = jackgpu_transport_init(&inst->transport);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("transport init failed");
        free(inst);
        return result;
    }

    /* Negotiate API version with host renderer */
    inst->api_version = VK_MAKE_API_VERSION(0, 1, 3, 0);
    if (pCreateInfo->pApplicationInfo) {
        uint32_t requested = pCreateInfo->pApplicationInfo->apiVersion;
        if (requested && requested < inst->api_version)
            inst->api_version = requested;
    }

    /* Send vkCreateInstance to host via Venus ring */
    uint8_t cmd_buf[4096];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateInstance, VENUS_CMD_REPLY_BIT);
    venus_enc_VkInstanceCreateInfo(&enc, pCreateInfo);

    /* The host needs an object ID for this instance */
    inst->venus_id = jackgpu_transport_alloc_id(&inst->transport);
    venus_enc_handle(&enc, inst->venus_id);

    uint8_t reply_buf[256];
    result = jackgpu_transport_submit_cmd(&inst->transport,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc),
                                          reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("vkCreateInstance on host failed");
        jackgpu_transport_fini(&inst->transport);
        free(inst);
        return result;
    }

    /* Decode reply */
    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        JACKGPU_ERR("host vkCreateInstance returned %d", host_result);
        jackgpu_transport_fini(&inst->transport);
        free(inst);
        return host_result;
    }

    /* Enumerate physical devices from host */
    result = jackgpu_enumerate_physical_devices_from_host(inst);
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("failed to enumerate physical devices");
        jackgpu_transport_fini(&inst->transport);
        free(inst);
        return result;
    }

    *pInstance = (VkInstance)inst;
    JACKGPU_LOG("instance created: %p, api_version=%u.%u.%u",
                (void *)inst,
                VK_API_VERSION_MAJOR(inst->api_version),
                VK_API_VERSION_MINOR(inst->api_version),
                VK_API_VERSION_PATCH(inst->api_version));

    return VK_SUCCESS;
}

void jackgpu_DestroyInstance(VkInstance instance,
                              const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!instance) return;

    jackgpu_instance *inst = (jackgpu_instance *)instance;

    /* Send vkDestroyInstance to host */
    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyInstance, 0);
    venus_enc_handle(&enc, inst->venus_id);
    jackgpu_transport_submit_cmd_no_reply(&inst->transport,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    /* Cleanup physical devices */
    free(inst->physical_devices);

    /* Shutdown transport */
    jackgpu_transport_fini(&inst->transport);

    free(inst);
    JACKGPU_LOG("instance destroyed");
}

VkResult jackgpu_EnumeratePhysicalDevices(VkInstance instance,
                                           uint32_t *pPhysicalDeviceCount,
                                           VkPhysicalDevice *pPhysicalDevices) {
    jackgpu_instance *inst = (jackgpu_instance *)instance;

    if (!pPhysicalDevices) {
        *pPhysicalDeviceCount = inst->physical_device_count;
        return VK_SUCCESS;
    }

    uint32_t count = inst->physical_device_count;
    uint32_t copy = *pPhysicalDeviceCount < count ? *pPhysicalDeviceCount : count;

    for (uint32_t i = 0; i < copy; i++) {
        pPhysicalDevices[i] = (VkPhysicalDevice)&inst->physical_devices[i];
    }
    *pPhysicalDeviceCount = copy;

    return copy < count ? VK_INCOMPLETE : VK_SUCCESS;
}
