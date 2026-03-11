/*
 * queue.h — VkQueue implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_QUEUE_H
#define JACKGPU_QUEUE_H

#include "driver/jackgpu.h"

struct jackgpu_queue {
    VK_LOADER_DATA loader_data;

    jackgpu_device  *device;
    venus_object_id  venus_id;
    uint32_t         family_index;
    uint32_t         queue_index;
};

void jackgpu_GetDeviceQueue(VkDevice device,
                             uint32_t queueFamilyIndex,
                             uint32_t queueIndex,
                             VkQueue *pQueue);

VkResult jackgpu_QueueSubmit(VkQueue queue,
                              uint32_t submitCount,
                              const VkSubmitInfo *pSubmits,
                              VkFence fence);

VkResult jackgpu_QueueWaitIdle(VkQueue queue);

VkResult jackgpu_QueuePresentKHR(VkQueue queue,
                                  const VkPresentInfoKHR *pPresentInfo);

#endif /* JACKGPU_QUEUE_H */
