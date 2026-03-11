/*
 * jackgpu.h — Core types and macros for JackGPU Vulkan ICD
 *
 * This file is part of Jack.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_H
#define JACKGPU_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>

/* Vulkan headers — no prototypes, we implement them */
#ifndef VK_NO_PROTOTYPES
#define VK_NO_PROTOTYPES
#endif
#include <vulkan/vulkan.h>
#include <vulkan/vk_icd.h>

/* ── Loader magic ─────────────────────────────────────────────
 * Every dispatchable object (VkInstance, VkPhysicalDevice, VkDevice,
 * VkQueue, VkCommandBuffer) must have the loader's dispatch table
 * pointer as its first sizeof(void*) bytes.
 */
#define JACKGPU_DEFINE_DISPATCHABLE(type, name) \
    struct name { \
        VK_LOADER_DATA loader_data; \
        /* driver fields follow */

#define JACKGPU_END_DISPATCHABLE };

/* ── Forward declarations ─────────────────────────────────── */
typedef struct jackgpu_instance    jackgpu_instance;
typedef struct jackgpu_phys_dev    jackgpu_phys_dev;
typedef struct jackgpu_device      jackgpu_device;
typedef struct jackgpu_queue       jackgpu_queue;
typedef struct jackgpu_cmd_buffer  jackgpu_cmd_buffer;
typedef struct jackgpu_device_memory jackgpu_device_memory;
typedef struct jackgpu_fence       jackgpu_fence;
typedef struct jackgpu_semaphore   jackgpu_semaphore;

/* ── Transport (ring + virtio-gpu) ────────────────────────── */
typedef struct jackgpu_transport   jackgpu_transport;
typedef struct jackgpu_ring        jackgpu_ring;

/* ── Venus encoder ────────────────────────────────────────── */
typedef struct venus_encoder       venus_encoder;
typedef struct venus_decoder       venus_decoder;

/* ── Venus command types ──────────────────────────────────── */
/* Mirrors VkCommandTypeEXT from venus-protocol.
 * Full list has 345+ entries; we define the ones we implement. */
enum venus_cmd_type {
    VENUS_CMD_vkCreateInstance                      = 0,
    VENUS_CMD_vkDestroyInstance                     = 1,
    VENUS_CMD_vkEnumeratePhysicalDevices            = 2,
    VENUS_CMD_vkGetPhysicalDeviceProperties         = 3,
    VENUS_CMD_vkGetPhysicalDeviceFeatures           = 4,
    VENUS_CMD_vkGetPhysicalDeviceMemoryProperties   = 6,
    VENUS_CMD_vkGetPhysicalDeviceQueueFamilyProperties = 7,
    VENUS_CMD_vkCreateDevice                        = 11,
    VENUS_CMD_vkDestroyDevice                       = 12,
    VENUS_CMD_vkGetDeviceQueue                      = 14,
    VENUS_CMD_vkQueueSubmit                         = 15,
    VENUS_CMD_vkQueueWaitIdle                       = 16,
    VENUS_CMD_vkDeviceWaitIdle                      = 17,
    VENUS_CMD_vkAllocateMemory                      = 18,
    VENUS_CMD_vkFreeMemory                          = 19,
    VENUS_CMD_vkMapMemory                           = 20,
    VENUS_CMD_vkUnmapMemory                         = 21,
    VENUS_CMD_vkCreateFence                         = 28,
    VENUS_CMD_vkDestroyFence                        = 29,
    VENUS_CMD_vkResetFences                         = 30,
    VENUS_CMD_vkWaitForFences                       = 31,
    VENUS_CMD_vkGetFenceStatus                      = 32,
    VENUS_CMD_vkCreateSemaphore                     = 33,
    VENUS_CMD_vkDestroySemaphore                    = 34,
    VENUS_CMD_vkCreateCommandPool                   = 40,
    VENUS_CMD_vkDestroyCommandPool                  = 41,
    VENUS_CMD_vkAllocateCommandBuffers              = 43,
    VENUS_CMD_vkFreeCommandBuffers                  = 44,
    VENUS_CMD_vkBeginCommandBuffer                  = 45,
    VENUS_CMD_vkEndCommandBuffer                    = 46,
    VENUS_CMD_vkResetCommandBuffer                  = 47,
    VENUS_CMD_vkEnumerateInstanceVersion            = 131,
    VENUS_CMD_vkEnumerateInstanceExtensionProperties = 132,
    VENUS_CMD_vkGetPhysicalDeviceProperties2        = 200,
    VENUS_CMD_vkGetPhysicalDeviceFeatures2          = 201,

    /* Pipeline / renderpass / framebuffer */
    VENUS_CMD_vkCreateRenderPass                    = 60,
    VENUS_CMD_vkDestroyRenderPass                   = 61,
    VENUS_CMD_vkCreateFramebuffer                   = 62,
    VENUS_CMD_vkDestroyFramebuffer                  = 63,
    VENUS_CMD_vkCreateGraphicsPipelines             = 65,
    VENUS_CMD_vkCreateComputePipelines              = 66,
    VENUS_CMD_vkDestroyPipeline                     = 67,
    VENUS_CMD_vkCreatePipelineLayout                = 68,
    VENUS_CMD_vkDestroyPipelineLayout               = 69,
    VENUS_CMD_vkCreateShaderModule                  = 55,
    VENUS_CMD_vkDestroyShaderModule                 = 56,

    /* Descriptor sets */
    VENUS_CMD_vkCreateDescriptorSetLayout           = 70,
    VENUS_CMD_vkDestroyDescriptorSetLayout          = 71,
    VENUS_CMD_vkCreateDescriptorPool                = 72,
    VENUS_CMD_vkDestroyDescriptorPool               = 73,
    VENUS_CMD_vkAllocateDescriptorSets              = 74,
    VENUS_CMD_vkFreeDescriptorSets                  = 75,
    VENUS_CMD_vkUpdateDescriptorSets                = 76,

    /* Buffer / image */
    VENUS_CMD_vkCreateBuffer                        = 22,
    VENUS_CMD_vkDestroyBuffer                       = 23,
    VENUS_CMD_vkCreateImage                         = 24,
    VENUS_CMD_vkDestroyImage                        = 25,
    VENUS_CMD_vkCreateImageView                     = 26,
    VENUS_CMD_vkDestroyImageView                    = 27,
    VENUS_CMD_vkCreateBufferView                    = 50,
    VENUS_CMD_vkDestroyBufferView                   = 51,
    VENUS_CMD_vkGetBufferMemoryRequirements         = 52,
    VENUS_CMD_vkGetImageMemoryRequirements          = 53,
    VENUS_CMD_vkBindBufferMemory                    = 54,
    VENUS_CMD_vkBindImageMemory                     = 57,
    VENUS_CMD_vkCreateSampler                       = 58,
    VENUS_CMD_vkDestroySampler                      = 59,

    /* Command buffer recording */
    VENUS_CMD_vkCmdBindPipeline                     = 80,
    VENUS_CMD_vkCmdSetViewport                      = 81,
    VENUS_CMD_vkCmdSetScissor                       = 82,
    VENUS_CMD_vkCmdBindDescriptorSets               = 86,
    VENUS_CMD_vkCmdBindVertexBuffers                = 88,
    VENUS_CMD_vkCmdBindIndexBuffer                  = 87,
    VENUS_CMD_vkCmdDraw                             = 89,
    VENUS_CMD_vkCmdDrawIndexed                      = 90,
    VENUS_CMD_vkCmdDispatch                         = 93,
    VENUS_CMD_vkCmdCopyBuffer                       = 95,
    VENUS_CMD_vkCmdCopyImage                        = 96,
    VENUS_CMD_vkCmdBlitImage                        = 97,
    VENUS_CMD_vkCmdCopyBufferToImage                = 98,
    VENUS_CMD_vkCmdCopyImageToBuffer                = 99,
    VENUS_CMD_vkCmdPipelineBarrier                  = 103,
    VENUS_CMD_vkCmdBeginRenderPass                  = 104,
    VENUS_CMD_vkCmdEndRenderPass                    = 106,
    VENUS_CMD_vkCmdPushConstants                    = 108,

    /* Swapchain (VK_KHR_swapchain) */
    VENUS_CMD_vkCreateSwapchainKHR                  = 150,
    VENUS_CMD_vkDestroySwapchainKHR                 = 151,
    VENUS_CMD_vkGetSwapchainImagesKHR               = 152,
    VENUS_CMD_vkAcquireNextImageKHR                 = 153,
    VENUS_CMD_vkQueuePresentKHR                     = 154,
};

/* Venus command flags */
#define VENUS_CMD_REPLY_BIT  0x00000001

/* ── Object ID management ─────────────────────────────────── */
/* Venus uses 64-bit object IDs on the wire instead of pointers.
 * We maintain a monotonic counter per instance. */
typedef uint64_t venus_object_id;

static inline venus_object_id jackgpu_alloc_object_id(uint64_t *counter) {
    return ++(*counter);
}

/* ── Utility macros ───────────────────────────────────────── */
#define JACKGPU_UNUSED(x) ((void)(x))
#define JACKGPU_ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define JACKGPU_ALIGN(x, a) (((x) + ((a) - 1)) & ~((a) - 1))

/* ── Logging ──────────────────────────────────────────────── */
#ifdef JACKGPU_DEBUG
    #include <stdio.h>
    #define JACKGPU_LOG(fmt, ...) fprintf(stderr, "[JackGPU] " fmt "\n", ##__VA_ARGS__)
    #define JACKGPU_ERR(fmt, ...) fprintf(stderr, "[JackGPU ERROR] " fmt "\n", ##__VA_ARGS__)
#else
    #define JACKGPU_LOG(fmt, ...) ((void)0)
    #define JACKGPU_ERR(fmt, ...) ((void)0)
#endif

#endif /* JACKGPU_H */
