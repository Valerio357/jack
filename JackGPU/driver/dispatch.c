/*
 * dispatch.c — Function dispatch table
 *
 * Maps Vulkan function names to JackGPU implementations.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/dispatch.h"
#include "driver/instance.h"
#include "driver/physical_device.h"
#include "driver/device.h"
#include "driver/queue.h"
#include "driver/memory.h"
#include "driver/command_buffer.h"
#include "driver/sync.h"

/* ── Dispatch table entry ─────────────────────────────────── */

struct dispatch_entry {
    const char        *name;
    PFN_vkVoidFunction func;
};

/* ── Full dispatch table ──────────────────────────────────── */

static const struct dispatch_entry dispatch_table[] = {
    /* Instance */
    { "vkCreateInstance",                       (PFN_vkVoidFunction)jackgpu_CreateInstance },
    { "vkDestroyInstance",                      (PFN_vkVoidFunction)jackgpu_DestroyInstance },
    { "vkEnumeratePhysicalDevices",             (PFN_vkVoidFunction)jackgpu_EnumeratePhysicalDevices },
    { "vkEnumerateInstanceVersion",             (PFN_vkVoidFunction)jackgpu_EnumerateInstanceVersion },
    { "vkEnumerateInstanceExtensionProperties", (PFN_vkVoidFunction)jackgpu_EnumerateInstanceExtensionProperties },
    { "vkEnumerateInstanceLayerProperties",     (PFN_vkVoidFunction)jackgpu_EnumerateInstanceLayerProperties },

    /* Physical Device */
    { "vkGetPhysicalDeviceProperties",            (PFN_vkVoidFunction)jackgpu_GetPhysicalDeviceProperties },
    { "vkGetPhysicalDeviceFeatures",              (PFN_vkVoidFunction)jackgpu_GetPhysicalDeviceFeatures },
    { "vkGetPhysicalDeviceMemoryProperties",      (PFN_vkVoidFunction)jackgpu_GetPhysicalDeviceMemoryProperties },
    { "vkGetPhysicalDeviceQueueFamilyProperties", (PFN_vkVoidFunction)jackgpu_GetPhysicalDeviceQueueFamilyProperties },
    { "vkGetPhysicalDeviceFormatProperties",      (PFN_vkVoidFunction)jackgpu_GetPhysicalDeviceFormatProperties },
    { "vkEnumerateDeviceExtensionProperties",     (PFN_vkVoidFunction)jackgpu_EnumerateDeviceExtensionProperties },

    /* Device */
    { "vkCreateDevice",                         (PFN_vkVoidFunction)jackgpu_CreateDevice },
    { "vkDestroyDevice",                        (PFN_vkVoidFunction)jackgpu_DestroyDevice },
    { "vkDeviceWaitIdle",                       (PFN_vkVoidFunction)jackgpu_DeviceWaitIdle },

    /* Queue */
    { "vkGetDeviceQueue",                       (PFN_vkVoidFunction)jackgpu_GetDeviceQueue },
    { "vkQueueSubmit",                          (PFN_vkVoidFunction)jackgpu_QueueSubmit },
    { "vkQueueWaitIdle",                        (PFN_vkVoidFunction)jackgpu_QueueWaitIdle },

    /* Memory */
    { "vkAllocateMemory",                       (PFN_vkVoidFunction)jackgpu_AllocateMemory },
    { "vkFreeMemory",                           (PFN_vkVoidFunction)jackgpu_FreeMemory },
    { "vkMapMemory",                            (PFN_vkVoidFunction)jackgpu_MapMemory },
    { "vkUnmapMemory",                          (PFN_vkVoidFunction)jackgpu_UnmapMemory },

    /* Buffer */
    { "vkCreateBuffer",                         (PFN_vkVoidFunction)jackgpu_CreateBuffer },
    { "vkDestroyBuffer",                        (PFN_vkVoidFunction)jackgpu_DestroyBuffer },
    { "vkGetBufferMemoryRequirements",          (PFN_vkVoidFunction)jackgpu_GetBufferMemoryRequirements },
    { "vkBindBufferMemory",                     (PFN_vkVoidFunction)jackgpu_BindBufferMemory },

    /* Image */
    { "vkCreateImage",                          (PFN_vkVoidFunction)jackgpu_CreateImage },
    { "vkDestroyImage",                         (PFN_vkVoidFunction)jackgpu_DestroyImage },
    { "vkGetImageMemoryRequirements",           (PFN_vkVoidFunction)jackgpu_GetImageMemoryRequirements },
    { "vkBindImageMemory",                      (PFN_vkVoidFunction)jackgpu_BindImageMemory },

    /* Image View */
    { "vkCreateImageView",                      (PFN_vkVoidFunction)jackgpu_CreateImageView },
    { "vkDestroyImageView",                     (PFN_vkVoidFunction)jackgpu_DestroyImageView },

    /* Command Pool */
    { "vkCreateCommandPool",                    (PFN_vkVoidFunction)jackgpu_CreateCommandPool },
    { "vkDestroyCommandPool",                   (PFN_vkVoidFunction)jackgpu_DestroyCommandPool },

    /* Command Buffer */
    { "vkAllocateCommandBuffers",               (PFN_vkVoidFunction)jackgpu_AllocateCommandBuffers },
    { "vkFreeCommandBuffers",                   (PFN_vkVoidFunction)jackgpu_FreeCommandBuffers },
    { "vkBeginCommandBuffer",                   (PFN_vkVoidFunction)jackgpu_BeginCommandBuffer },
    { "vkEndCommandBuffer",                     (PFN_vkVoidFunction)jackgpu_EndCommandBuffer },
    { "vkResetCommandBuffer",                   (PFN_vkVoidFunction)jackgpu_ResetCommandBuffer },

    /* Synchronization */
    { "vkCreateFence",                          (PFN_vkVoidFunction)jackgpu_CreateFence },
    { "vkDestroyFence",                         (PFN_vkVoidFunction)jackgpu_DestroyFence },
    { "vkWaitForFences",                        (PFN_vkVoidFunction)jackgpu_WaitForFences },
    { "vkResetFences",                          (PFN_vkVoidFunction)jackgpu_ResetFences },
    { "vkGetFenceStatus",                       (PFN_vkVoidFunction)jackgpu_GetFenceStatus },
    { "vkCreateSemaphore",                      (PFN_vkVoidFunction)jackgpu_CreateSemaphore },
    { "vkDestroySemaphore",                     (PFN_vkVoidFunction)jackgpu_DestroySemaphore },

    /* Command buffer recording */
    { "vkCmdBindPipeline",                      (PFN_vkVoidFunction)jackgpu_CmdBindPipeline },
    { "vkCmdSetViewport",                       (PFN_vkVoidFunction)jackgpu_CmdSetViewport },
    { "vkCmdSetScissor",                        (PFN_vkVoidFunction)jackgpu_CmdSetScissor },
    { "vkCmdDraw",                              (PFN_vkVoidFunction)jackgpu_CmdDraw },
    { "vkCmdDrawIndexed",                       (PFN_vkVoidFunction)jackgpu_CmdDrawIndexed },
    { "vkCmdBindVertexBuffers",                 (PFN_vkVoidFunction)jackgpu_CmdBindVertexBuffers },
    { "vkCmdBindIndexBuffer",                   (PFN_vkVoidFunction)jackgpu_CmdBindIndexBuffer },
    { "vkCmdBindDescriptorSets",                (PFN_vkVoidFunction)jackgpu_CmdBindDescriptorSets },
    { "vkCmdPipelineBarrier",                   (PFN_vkVoidFunction)jackgpu_CmdPipelineBarrier },
    { "vkCmdBeginRenderPass",                   (PFN_vkVoidFunction)jackgpu_CmdBeginRenderPass },
    { "vkCmdEndRenderPass",                     (PFN_vkVoidFunction)jackgpu_CmdEndRenderPass },
    { "vkCmdCopyBuffer",                        (PFN_vkVoidFunction)jackgpu_CmdCopyBuffer },
    { "vkCmdDispatch",                          (PFN_vkVoidFunction)jackgpu_CmdDispatch },
    { "vkCmdPushConstants",                     (PFN_vkVoidFunction)jackgpu_CmdPushConstants },

    /* Dispatch */
    { "vkGetDeviceProcAddr",                    (PFN_vkVoidFunction)jackgpu_GetDeviceProcAddr },

    /* Sentinel */
    { NULL, NULL },
};

/* ── Lookup helper ────────────────────────────────────────── */

static PFN_vkVoidFunction jackgpu_lookup(const char *name) {
    for (const struct dispatch_entry *e = dispatch_table; e->name; e++) {
        if (strcmp(e->name, name) == 0)
            return e->func;
    }
    return NULL;
}

/* ── Public dispatch functions ────────────────────────────── */

PFN_vkVoidFunction jackgpu_GetInstanceProcAddr(VkInstance instance, const char *pName) {
    /* Global functions that don't require an instance */
    if (!instance) {
        if (strcmp(pName, "vkCreateInstance") == 0)
            return (PFN_vkVoidFunction)jackgpu_CreateInstance;
        if (strcmp(pName, "vkEnumerateInstanceVersion") == 0)
            return (PFN_vkVoidFunction)jackgpu_EnumerateInstanceVersion;
        if (strcmp(pName, "vkEnumerateInstanceExtensionProperties") == 0)
            return (PFN_vkVoidFunction)jackgpu_EnumerateInstanceExtensionProperties;
        if (strcmp(pName, "vkEnumerateInstanceLayerProperties") == 0)
            return (PFN_vkVoidFunction)jackgpu_EnumerateInstanceLayerProperties;
        return NULL;
    }

    return jackgpu_lookup(pName);
}

PFN_vkVoidFunction jackgpu_GetDeviceProcAddr(VkDevice device, const char *pName) {
    JACKGPU_UNUSED(device);

    /* Device-level functions only — skip instance/physical device functions */
    if (strcmp(pName, "vkCreateInstance") == 0 ||
        strcmp(pName, "vkDestroyInstance") == 0 ||
        strcmp(pName, "vkEnumeratePhysicalDevices") == 0 ||
        strcmp(pName, "vkEnumerateInstanceVersion") == 0 ||
        strcmp(pName, "vkEnumerateInstanceExtensionProperties") == 0 ||
        strcmp(pName, "vkEnumerateInstanceLayerProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceFeatures") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceMemoryProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceQueueFamilyProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceFormatProperties") == 0 ||
        strcmp(pName, "vkEnumerateDeviceExtensionProperties") == 0) {
        return NULL;
    }

    return jackgpu_lookup(pName);
}
