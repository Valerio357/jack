/*
 * sync.h — VkFence and VkSemaphore
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_SYNC_H
#define JACKGPU_SYNC_H

#include "driver/jackgpu.h"

struct jackgpu_fence {
    jackgpu_device  *device;
    venus_object_id  venus_id;
    bool             signaled;
};

struct jackgpu_semaphore {
    jackgpu_device  *device;
    venus_object_id  venus_id;
};

/* Fence */
VkResult jackgpu_CreateFence(VkDevice device,
                              const VkFenceCreateInfo *pCreateInfo,
                              const VkAllocationCallbacks *pAllocator,
                              VkFence *pFence);

void jackgpu_DestroyFence(VkDevice device,
                           VkFence fence,
                           const VkAllocationCallbacks *pAllocator);

VkResult jackgpu_WaitForFences(VkDevice device,
                                uint32_t fenceCount,
                                const VkFence *pFences,
                                VkBool32 waitAll,
                                uint64_t timeout);

VkResult jackgpu_ResetFences(VkDevice device,
                              uint32_t fenceCount,
                              const VkFence *pFences);

VkResult jackgpu_GetFenceStatus(VkDevice device,
                                 VkFence fence);

/* Semaphore */
VkResult jackgpu_CreateSemaphore(VkDevice device,
                                  const VkSemaphoreCreateInfo *pCreateInfo,
                                  const VkAllocationCallbacks *pAllocator,
                                  VkSemaphore *pSemaphore);

void jackgpu_DestroySemaphore(VkDevice device,
                               VkSemaphore semaphore,
                               const VkAllocationCallbacks *pAllocator);

#endif /* JACKGPU_SYNC_H */
