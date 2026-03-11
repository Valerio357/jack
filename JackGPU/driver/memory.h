/*
 * memory.h — VkDeviceMemory, VkBuffer, VkImage, VkImageView
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_MEMORY_H
#define JACKGPU_MEMORY_H

#include "driver/jackgpu.h"

struct jackgpu_device_memory {
    jackgpu_device  *device;
    venus_object_id  venus_id;
    VkDeviceSize     size;
    uint32_t         memory_type_index;
    void            *mapped;
};

/* Non-dispatchable objects — simple wrappers around Venus IDs */
typedef struct jackgpu_buffer {
    jackgpu_device  *device;
    venus_object_id  venus_id;
} jackgpu_buffer;

typedef struct jackgpu_image {
    jackgpu_device  *device;
    venus_object_id  venus_id;
} jackgpu_image;

typedef struct jackgpu_image_view {
    jackgpu_device  *device;
    venus_object_id  venus_id;
} jackgpu_image_view;

/* Memory */
VkResult jackgpu_AllocateMemory(VkDevice device,
                                 const VkMemoryAllocateInfo *pAllocateInfo,
                                 const VkAllocationCallbacks *pAllocator,
                                 VkDeviceMemory *pMemory);

void jackgpu_FreeMemory(VkDevice device,
                         VkDeviceMemory memory,
                         const VkAllocationCallbacks *pAllocator);

VkResult jackgpu_MapMemory(VkDevice device,
                            VkDeviceMemory memory,
                            VkDeviceSize offset,
                            VkDeviceSize size,
                            VkMemoryMapFlags flags,
                            void **ppData);

void jackgpu_UnmapMemory(VkDevice device,
                          VkDeviceMemory memory);

/* Buffer */
VkResult jackgpu_CreateBuffer(VkDevice device,
                               const VkBufferCreateInfo *pCreateInfo,
                               const VkAllocationCallbacks *pAllocator,
                               VkBuffer *pBuffer);

void jackgpu_DestroyBuffer(VkDevice device,
                            VkBuffer buffer,
                            const VkAllocationCallbacks *pAllocator);

void jackgpu_GetBufferMemoryRequirements(VkDevice device,
                                          VkBuffer buffer,
                                          VkMemoryRequirements *pMemoryRequirements);

VkResult jackgpu_BindBufferMemory(VkDevice device,
                                   VkBuffer buffer,
                                   VkDeviceMemory memory,
                                   VkDeviceSize memoryOffset);

/* Image */
VkResult jackgpu_CreateImage(VkDevice device,
                              const VkImageCreateInfo *pCreateInfo,
                              const VkAllocationCallbacks *pAllocator,
                              VkImage *pImage);

void jackgpu_DestroyImage(VkDevice device,
                           VkImage image,
                           const VkAllocationCallbacks *pAllocator);

void jackgpu_GetImageMemoryRequirements(VkDevice device,
                                         VkImage image,
                                         VkMemoryRequirements *pMemoryRequirements);

VkResult jackgpu_BindImageMemory(VkDevice device,
                                  VkImage image,
                                  VkDeviceMemory memory,
                                  VkDeviceSize memoryOffset);

/* Image View */
VkResult jackgpu_CreateImageView(VkDevice device,
                                  const VkImageViewCreateInfo *pCreateInfo,
                                  const VkAllocationCallbacks *pAllocator,
                                  VkImageView *pView);

void jackgpu_DestroyImageView(VkDevice device,
                               VkImageView imageView,
                               const VkAllocationCallbacks *pAllocator);

#endif /* JACKGPU_MEMORY_H */
