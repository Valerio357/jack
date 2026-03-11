/*
 * device.c — VkDevice implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/device.h"
#include "driver/instance.h"
#include "driver/physical_device.h"
#include "driver/queue.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

VkResult jackgpu_CreateDevice(VkPhysicalDevice physicalDevice,
                               const VkDeviceCreateInfo *pCreateInfo,
                               const VkAllocationCallbacks *pAllocator,
                               VkDevice *pDevice) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_phys_dev *pd = (jackgpu_phys_dev *)physicalDevice;
    jackgpu_instance *inst = pd->instance;
    jackgpu_transport *tp = &inst->transport;

    jackgpu_device *dev = (jackgpu_device *)calloc(1, sizeof(jackgpu_device));
    if (!dev)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    set_loader_magic_value(dev);
    dev->instance = inst;
    dev->physical_device = pd;

    /* Allocate Venus object ID for this device */
    dev->venus_id = jackgpu_transport_alloc_id(tp);

    /* Encode vkCreateDevice command */
    uint8_t cmd_buf[4096];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateDevice, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, pd->venus_id);   /* physicalDevice */
    venus_enc_VkDeviceCreateInfo(&enc, pCreateInfo);
    venus_enc_handle(&enc, dev->venus_id);  /* output device ID */

    uint8_t reply_buf[256];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        JACKGPU_ERR("vkCreateDevice transport failed");
        free(dev);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        JACKGPU_ERR("host vkCreateDevice returned %d", host_result);
        free(dev);
        return host_result;
    }

    /* Count total queues across all families */
    uint32_t total_queues = 0;
    for (uint32_t i = 0; i < pCreateInfo->queueCreateInfoCount; i++) {
        total_queues += pCreateInfo->pQueueCreateInfos[i].queueCount;
    }

    /* Allocate queue objects */
    dev->queues = (jackgpu_queue *)calloc(total_queues, sizeof(jackgpu_queue));
    if (!dev->queues) {
        free(dev);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    dev->queue_count = total_queues;

    /* Initialize queue objects — they will be populated on GetDeviceQueue */
    uint32_t q = 0;
    for (uint32_t i = 0; i < pCreateInfo->queueCreateInfoCount; i++) {
        const VkDeviceQueueCreateInfo *qi = &pCreateInfo->pQueueCreateInfos[i];
        for (uint32_t j = 0; j < qi->queueCount; j++) {
            jackgpu_queue *queue = &dev->queues[q++];
            set_loader_magic_value(queue);
            queue->device = dev;
            queue->family_index = qi->queueFamilyIndex;
            queue->queue_index = j;
            queue->venus_id = jackgpu_transport_alloc_id(tp);
        }
    }

    *pDevice = (VkDevice)dev;
    JACKGPU_LOG("device created: %p, venus_id=%llu, %u queue(s)",
                (void *)dev, dev->venus_id, total_queues);

    return VK_SUCCESS;
}

void jackgpu_DestroyDevice(VkDevice device,
                            const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!device) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    /* Send vkDestroyDevice to host */
    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyDevice, 0);
    venus_enc_handle(&enc, dev->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(dev->queues);
    free(dev);
    JACKGPU_LOG("device destroyed");
}

VkResult jackgpu_DeviceWaitIdle(VkDevice device) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDeviceWaitIdle, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);

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
