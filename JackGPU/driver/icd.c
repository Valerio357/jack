/*
 * icd.c — Vulkan ICD entry points
 *
 * These are the exported symbols that the Vulkan loader uses to
 * communicate with the JackGPU ICD driver.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/jackgpu.h"
#include "driver/dispatch.h"

/*
 * vk_icdNegotiateLoaderICDInterfaceVersion
 *
 * Called by the loader to negotiate the ICD interface version.
 * We support version 5 (VK_LOADER_DATA + physical device sorting).
 */
#ifdef _WIN32
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
VkResult vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *pSupportedVersion) {
    /* We support up to version 5 */
    if (*pSupportedVersion > 5)
        *pSupportedVersion = 5;

    JACKGPU_LOG("ICD interface version negotiated: %u", *pSupportedVersion);
    return VK_SUCCESS;
}

/*
 * vk_icdGetInstanceProcAddr
 *
 * Called by the loader to resolve Vulkan function pointers.
 * Delegates to our dispatch table.
 */
#ifdef _WIN32
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *pName) {
    return jackgpu_GetInstanceProcAddr(instance, pName);
}

/*
 * vk_icdGetPhysicalDeviceProcAddr
 *
 * Called by the loader (interface version >= 5) to resolve physical-device
 * functions that may need special dispatch (e.g. for VkPhysicalDevice
 * sorting/selection).
 *
 * Returns NULL for any function we don't specifically handle at
 * the physical device level, letting the loader use the normal path.
 */
#ifdef _WIN32
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
PFN_vkVoidFunction vk_icdGetPhysicalDeviceProcAddr(VkInstance instance, const char *pName) {
    JACKGPU_UNUSED(instance);

    /* Only return function pointers for physical-device-level functions */
    if (strcmp(pName, "vkGetPhysicalDeviceProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceFeatures") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceMemoryProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceQueueFamilyProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceFormatProperties") == 0 ||
        strcmp(pName, "vkEnumerateDeviceExtensionProperties") == 0) {
        return jackgpu_GetInstanceProcAddr(instance, pName);
    }

    return NULL;
}
