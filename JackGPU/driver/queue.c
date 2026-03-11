/*
 * queue.c — VkQueue implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/queue.h"
#include "driver/device.h"
#include "driver/instance.h"
#include "driver/command_buffer.h"
#include "driver/sync.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

void jackgpu_GetDeviceQueue(VkDevice device,
                             uint32_t queueFamilyIndex,
                             uint32_t queueIndex,
                             VkQueue *pQueue) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    /* Find the matching queue in our pre-allocated array */
    for (uint32_t i = 0; i < dev->queue_count; i++) {
        jackgpu_queue *q = &dev->queues[i];
        if (q->family_index == queueFamilyIndex && q->queue_index == queueIndex) {
            /* Send vkGetDeviceQueue to host so it knows the mapping */
            uint8_t cmd_buf[128];
            venus_encoder enc;
            venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

            venus_enc_cmd_header(&enc, VENUS_CMD_vkGetDeviceQueue, VENUS_CMD_REPLY_BIT);
            venus_enc_handle(&enc, dev->venus_id);
            venus_enc_uint32(&enc, queueFamilyIndex);
            venus_enc_uint32(&enc, queueIndex);
            venus_enc_handle(&enc, q->venus_id);

            uint8_t reply_buf[64];
            jackgpu_transport_submit_cmd(tp,
                                         venus_enc_data(&enc),
                                         venus_enc_size(&enc),
                                         reply_buf, sizeof(reply_buf));

            *pQueue = (VkQueue)q;
            JACKGPU_LOG("GetDeviceQueue: family=%u idx=%u -> %p",
                        queueFamilyIndex, queueIndex, (void *)q);
            return;
        }
    }

    JACKGPU_ERR("GetDeviceQueue: no matching queue family=%u idx=%u",
                queueFamilyIndex, queueIndex);
    *pQueue = VK_NULL_HANDLE;
}

VkResult jackgpu_QueueSubmit(VkQueue queue,
                              uint32_t submitCount,
                              const VkSubmitInfo *pSubmits,
                              VkFence fence) {
    jackgpu_queue *q = (jackgpu_queue *)queue;
    jackgpu_device *dev = q->device;
    jackgpu_transport *tp = &dev->instance->transport;

    /* First, flush any recorded command buffer data to the host.
     * Each command buffer's local recording buffer contains the encoded
     * Venus commands that were recorded during vkCmd* calls. */
    for (uint32_t s = 0; s < submitCount; s++) {
        const VkSubmitInfo *submit = &pSubmits[s];
        for (uint32_t c = 0; c < submit->commandBufferCount; c++) {
            jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)submit->pCommandBuffers[c];
            if (cmd->recording_size > 0) {
                /* Submit the recorded commands as a batch */
                jackgpu_transport_submit_cmd_no_reply(tp,
                                                      cmd->recording_buf,
                                                      cmd->recording_size);
            }
        }
    }

    /* Now send the actual vkQueueSubmit command */
    uint8_t cmd_buf[4096];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkQueueSubmit, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, q->venus_id);
    venus_enc_uint32(&enc, submitCount);
    venus_enc_array_size(&enc, submitCount);

    for (uint32_t s = 0; s < submitCount; s++) {
        venus_enc_VkSubmitInfo(&enc, &pSubmits[s]);
    }

    /* Fence handle (0 if VK_NULL_HANDLE) */
    if (fence != VK_NULL_HANDLE) {
        jackgpu_fence *f = (jackgpu_fence *)(uintptr_t)fence;
        venus_enc_handle(&enc, f->venus_id);
    } else {
        venus_enc_handle(&enc, 0);
    }

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS)
        return result;

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    return venus_dec_reply_header(&dec);
}

VkResult jackgpu_QueueWaitIdle(VkQueue queue) {
    jackgpu_queue *q = (jackgpu_queue *)queue;
    jackgpu_transport *tp = &q->device->instance->transport;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkQueueWaitIdle, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, q->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS)
        return result;

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    return venus_dec_reply_header(&dec);
}

VkResult jackgpu_QueuePresentKHR(VkQueue queue,
                                  const VkPresentInfoKHR *pPresentInfo) {
    /* TODO: implement swapchain presentation */
    JACKGPU_UNUSED(queue);
    JACKGPU_UNUSED(pPresentInfo);
    JACKGPU_LOG("QueuePresentKHR: stub");
    return VK_SUCCESS;
}
