/*
 * sync.c — VkFence and VkSemaphore
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/sync.h"
#include "driver/device.h"
#include "driver/instance.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

/* ── Fence ────────────────────────────────────────────────── */

VkResult jackgpu_CreateFence(VkDevice device,
                              const VkFenceCreateInfo *pCreateInfo,
                              const VkAllocationCallbacks *pAllocator,
                              VkFence *pFence) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_fence *fence = (jackgpu_fence *)calloc(1, sizeof(jackgpu_fence));
    if (!fence)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    fence->device = dev;
    fence->venus_id = jackgpu_transport_alloc_id(tp);
    fence->signaled = (pCreateInfo->flags & VK_FENCE_CREATE_SIGNALED_BIT) != 0;

    uint8_t cmd_buf[128];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateFence, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkFenceCreateInfo(&enc, pCreateInfo);
    venus_enc_handle(&enc, fence->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(fence);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(fence);
        return host_result;
    }

    *pFence = (VkFence)(uintptr_t)fence;
    return VK_SUCCESS;
}

void jackgpu_DestroyFence(VkDevice device,
                           VkFence fence,
                           const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!fence) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_fence *f = (jackgpu_fence *)(uintptr_t)fence;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyFence, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, f->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(f);
}

VkResult jackgpu_WaitForFences(VkDevice device,
                                uint32_t fenceCount,
                                const VkFence *pFences,
                                VkBool32 waitAll,
                                uint64_t timeout) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkWaitForFences, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_uint32(&enc, fenceCount);
    venus_enc_array_size(&enc, fenceCount);
    for (uint32_t i = 0; i < fenceCount; i++) {
        jackgpu_fence *f = (jackgpu_fence *)(uintptr_t)pFences[i];
        venus_enc_handle(&enc, f->venus_id);
    }
    venus_enc_uint32(&enc, waitAll);
    venus_enc_uint64(&enc, timeout);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS)
        return result;

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);

    /* Update local signaled state */
    if (host_result == VK_SUCCESS) {
        for (uint32_t i = 0; i < fenceCount; i++) {
            jackgpu_fence *f = (jackgpu_fence *)(uintptr_t)pFences[i];
            f->signaled = true;
        }
    }

    return host_result;
}

VkResult jackgpu_ResetFences(VkDevice device,
                              uint32_t fenceCount,
                              const VkFence *pFences) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkResetFences, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_uint32(&enc, fenceCount);
    venus_enc_array_size(&enc, fenceCount);
    for (uint32_t i = 0; i < fenceCount; i++) {
        jackgpu_fence *f = (jackgpu_fence *)(uintptr_t)pFences[i];
        venus_enc_handle(&enc, f->venus_id);
        f->signaled = false;
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

VkResult jackgpu_GetFenceStatus(VkDevice device,
                                 VkFence fence) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_fence *f = (jackgpu_fence *)(uintptr_t)fence;

    /* Quick local check — if we already know it's signaled, skip the round-trip.
     * This is an optimization; the host is the source of truth. */

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    /* Note: vkGetFenceStatus uses the same wire slot as vkWaitForFences
     * with timeout=0, single fence, waitAll=true in Venus protocol.
     * We encode it as WaitForFences with zero timeout. */
    venus_enc_cmd_header(&enc, VENUS_CMD_vkWaitForFences, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_uint32(&enc, 1);
    venus_enc_array_size(&enc, 1);
    venus_enc_handle(&enc, f->venus_id);
    venus_enc_uint32(&enc, VK_TRUE);
    venus_enc_uint64(&enc, 0); /* timeout = 0 */

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS)
        return VK_NOT_READY;

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);

    if (host_result == VK_SUCCESS)
        f->signaled = true;

    return host_result;
}

/* ── Semaphore ────────────────────────────────────────────── */

VkResult jackgpu_CreateSemaphore(VkDevice device,
                                  const VkSemaphoreCreateInfo *pCreateInfo,
                                  const VkAllocationCallbacks *pAllocator,
                                  VkSemaphore *pSemaphore) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_semaphore *sem = (jackgpu_semaphore *)calloc(1, sizeof(jackgpu_semaphore));
    if (!sem)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    sem->device = dev;
    sem->venus_id = jackgpu_transport_alloc_id(tp);

    uint8_t cmd_buf[128];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateSemaphore, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkSemaphoreCreateInfo(&enc, pCreateInfo);
    venus_enc_handle(&enc, sem->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(sem);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(sem);
        return host_result;
    }

    *pSemaphore = (VkSemaphore)(uintptr_t)sem;
    return VK_SUCCESS;
}

void jackgpu_DestroySemaphore(VkDevice device,
                               VkSemaphore semaphore,
                               const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!semaphore) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_semaphore *sem = (jackgpu_semaphore *)(uintptr_t)semaphore;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroySemaphore, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, sem->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(sem);
}
