/*
 * command_buffer.c — VkCommandBuffer and VkCommandPool
 *
 * Command buffer recording commands encode into a local buffer.
 * The encoded data is flushed to the host in batch via vkQueueSubmit.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/command_buffer.h"
#include "driver/device.h"
#include "driver/instance.h"
#include "driver/memory.h"
#include "driver/sync.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

/* ── Helper: ensure recording buffer has enough space ─────── */

static bool jackgpu_cmd_ensure_space(jackgpu_cmd_buffer *cmd, size_t needed) {
    size_t required = cmd->recording_size + needed;
    if (required <= cmd->recording_capacity)
        return true;

    size_t new_cap = cmd->recording_capacity * 2;
    if (new_cap < required)
        new_cap = required;

    uint8_t *new_buf = (uint8_t *)realloc(cmd->recording_buf, new_cap);
    if (!new_buf)
        return false;

    cmd->recording_buf = new_buf;
    cmd->recording_capacity = new_cap;
    return true;
}

/* Get a venus_encoder that writes into the command buffer's recording area */
static void jackgpu_cmd_rec_encoder(jackgpu_cmd_buffer *cmd, venus_encoder *enc, size_t reserve) {
    jackgpu_cmd_ensure_space(cmd, reserve);
    venus_enc_init(enc, cmd->recording_buf + cmd->recording_size,
                   cmd->recording_capacity - cmd->recording_size);
}

/* Commit what was written by the encoder */
static void jackgpu_cmd_rec_commit(jackgpu_cmd_buffer *cmd, const venus_encoder *enc) {
    cmd->recording_size += venus_enc_size(enc);
}

/* ── Command Pool ─────────────────────────────────────────── */

VkResult jackgpu_CreateCommandPool(VkDevice device,
                                    const VkCommandPoolCreateInfo *pCreateInfo,
                                    const VkAllocationCallbacks *pAllocator,
                                    VkCommandPool *pCommandPool) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_cmd_pool *pool = (jackgpu_cmd_pool *)calloc(1, sizeof(jackgpu_cmd_pool));
    if (!pool)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    pool->device = dev;
    pool->venus_id = jackgpu_transport_alloc_id(tp);

    uint8_t cmd_buf[256];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateCommandPool, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_uint32(&enc, pCreateInfo->flags);
    venus_enc_uint32(&enc, pCreateInfo->queueFamilyIndex);
    venus_enc_handle(&enc, pool->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(pool);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(pool);
        return host_result;
    }

    *pCommandPool = (VkCommandPool)(uintptr_t)pool;
    JACKGPU_LOG("command pool created: venus_id=%llu", pool->venus_id);
    return VK_SUCCESS;
}

void jackgpu_DestroyCommandPool(VkDevice device,
                                 VkCommandPool commandPool,
                                 const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!commandPool) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_cmd_pool *pool = (jackgpu_cmd_pool *)(uintptr_t)commandPool;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyCommandPool, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, pool->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(pool);
}

/* ── Command Buffer Allocation ────────────────────────────── */

VkResult jackgpu_AllocateCommandBuffers(VkDevice device,
                                         const VkCommandBufferAllocateInfo *pAllocateInfo,
                                         VkCommandBuffer *pCommandBuffers) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_cmd_pool *pool = (jackgpu_cmd_pool *)(uintptr_t)pAllocateInfo->commandPool;

    for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; i++) {
        jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)calloc(1, sizeof(jackgpu_cmd_buffer));
        if (!cmd) {
            /* Free previously allocated on failure */
            for (uint32_t j = 0; j < i; j++) {
                jackgpu_cmd_buffer *prev = (jackgpu_cmd_buffer *)pCommandBuffers[j];
                free(prev->recording_buf);
                free(prev);
            }
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }

        set_loader_magic_value(cmd);
        cmd->device = dev;
        cmd->pool_venus_id = pool->venus_id;
        cmd->venus_id = jackgpu_transport_alloc_id(tp);

        /* Allocate initial recording buffer */
        cmd->recording_buf = (uint8_t *)malloc(JACKGPU_CMD_RECORDING_INITIAL_SIZE);
        if (!cmd->recording_buf) {
            free(cmd);
            for (uint32_t j = 0; j < i; j++) {
                jackgpu_cmd_buffer *prev = (jackgpu_cmd_buffer *)pCommandBuffers[j];
                free(prev->recording_buf);
                free(prev);
            }
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        cmd->recording_capacity = JACKGPU_CMD_RECORDING_INITIAL_SIZE;
        cmd->recording_size = 0;
        cmd->is_recording = false;

        pCommandBuffers[i] = (VkCommandBuffer)cmd;
    }

    /* Notify host about the allocation */
    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkAllocateCommandBuffers, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkCommandBufferAllocateInfo(&enc, pAllocateInfo);
    venus_enc_array_size(&enc, pAllocateInfo->commandBufferCount);
    for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; i++) {
        jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)pCommandBuffers[i];
        venus_enc_handle(&enc, cmd->venus_id);
    }

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; i++) {
            jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)pCommandBuffers[i];
            free(cmd->recording_buf);
            free(cmd);
        }
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; i++) {
            jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)pCommandBuffers[i];
            free(cmd->recording_buf);
            free(cmd);
        }
        return host_result;
    }

    JACKGPU_LOG("allocated %u command buffer(s)", pAllocateInfo->commandBufferCount);
    return VK_SUCCESS;
}

void jackgpu_FreeCommandBuffers(VkDevice device,
                                 VkCommandPool commandPool,
                                 uint32_t commandBufferCount,
                                 const VkCommandBuffer *pCommandBuffers) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_cmd_pool *pool = (jackgpu_cmd_pool *)(uintptr_t)commandPool;

    /* Notify host */
    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkFreeCommandBuffers, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, pool->venus_id);
    venus_enc_uint32(&enc, commandBufferCount);
    venus_enc_array_size(&enc, commandBufferCount);
    for (uint32_t i = 0; i < commandBufferCount; i++) {
        if (pCommandBuffers[i]) {
            jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)pCommandBuffers[i];
            venus_enc_handle(&enc, cmd->venus_id);
        } else {
            venus_enc_handle(&enc, 0);
        }
    }
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    /* Free local resources */
    for (uint32_t i = 0; i < commandBufferCount; i++) {
        if (pCommandBuffers[i]) {
            jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)pCommandBuffers[i];
            free(cmd->recording_buf);
            free(cmd);
        }
    }
}

/* ── Command Buffer Recording ─────────────────────────────── */

VkResult jackgpu_BeginCommandBuffer(VkCommandBuffer commandBuffer,
                                     const VkCommandBufferBeginInfo *pBeginInfo) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    /* Reset recording buffer */
    cmd->recording_size = 0;
    cmd->is_recording = true;

    /* Encode BeginCommandBuffer into the recording buffer */
    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 256);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkBeginCommandBuffer, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_VkCommandBufferBeginInfo(&enc, pBeginInfo);

    jackgpu_cmd_rec_commit(cmd, &enc);

    JACKGPU_LOG("BeginCommandBuffer: venus_id=%llu", cmd->venus_id);
    return VK_SUCCESS;
}

VkResult jackgpu_EndCommandBuffer(VkCommandBuffer commandBuffer) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkEndCommandBuffer, 0);
    venus_enc_handle(&enc, cmd->venus_id);

    jackgpu_cmd_rec_commit(cmd, &enc);
    cmd->is_recording = false;

    JACKGPU_LOG("EndCommandBuffer: venus_id=%llu, recorded %zu bytes",
                cmd->venus_id, cmd->recording_size);
    return VK_SUCCESS;
}

VkResult jackgpu_ResetCommandBuffer(VkCommandBuffer commandBuffer,
                                     VkCommandBufferResetFlags flags) {
    JACKGPU_UNUSED(flags);
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    cmd->recording_size = 0;
    cmd->is_recording = false;
    return VK_SUCCESS;
}

/* ── Recording commands (encode into local buffer) ────────── */

void jackgpu_CmdBindPipeline(VkCommandBuffer commandBuffer,
                              VkPipelineBindPoint pipelineBindPoint,
                              VkPipeline pipeline) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdBindPipeline, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, (uint32_t)pipelineBindPoint);
    venus_enc_handle(&enc, (venus_object_id)(uintptr_t)pipeline);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdSetViewport(VkCommandBuffer commandBuffer,
                             uint32_t firstViewport,
                             uint32_t viewportCount,
                             const VkViewport *pViewports) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64 + viewportCount * sizeof(VkViewport));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdSetViewport, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, firstViewport);
    venus_enc_uint32(&enc, viewportCount);
    venus_enc_array_size(&enc, viewportCount);
    for (uint32_t i = 0; i < viewportCount; i++) {
        venus_enc_float(&enc, pViewports[i].x);
        venus_enc_float(&enc, pViewports[i].y);
        venus_enc_float(&enc, pViewports[i].width);
        venus_enc_float(&enc, pViewports[i].height);
        venus_enc_float(&enc, pViewports[i].minDepth);
        venus_enc_float(&enc, pViewports[i].maxDepth);
    }

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdSetScissor(VkCommandBuffer commandBuffer,
                            uint32_t firstScissor,
                            uint32_t scissorCount,
                            const VkRect2D *pScissors) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64 + scissorCount * sizeof(VkRect2D));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdSetScissor, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, firstScissor);
    venus_enc_uint32(&enc, scissorCount);
    venus_enc_array_size(&enc, scissorCount);
    for (uint32_t i = 0; i < scissorCount; i++) {
        venus_enc_int32(&enc, pScissors[i].offset.x);
        venus_enc_int32(&enc, pScissors[i].offset.y);
        venus_enc_uint32(&enc, pScissors[i].extent.width);
        venus_enc_uint32(&enc, pScissors[i].extent.height);
    }

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdDraw(VkCommandBuffer commandBuffer,
                      uint32_t vertexCount,
                      uint32_t instanceCount,
                      uint32_t firstVertex,
                      uint32_t firstInstance) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdDraw, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, vertexCount);
    venus_enc_uint32(&enc, instanceCount);
    venus_enc_uint32(&enc, firstVertex);
    venus_enc_uint32(&enc, firstInstance);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdDrawIndexed(VkCommandBuffer commandBuffer,
                             uint32_t indexCount,
                             uint32_t instanceCount,
                             uint32_t firstIndex,
                             int32_t vertexOffset,
                             uint32_t firstInstance) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdDrawIndexed, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, indexCount);
    venus_enc_uint32(&enc, instanceCount);
    venus_enc_uint32(&enc, firstIndex);
    venus_enc_int32(&enc, vertexOffset);
    venus_enc_uint32(&enc, firstInstance);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdBindVertexBuffers(VkCommandBuffer commandBuffer,
                                   uint32_t firstBinding,
                                   uint32_t bindingCount,
                                   const VkBuffer *pBuffers,
                                   const VkDeviceSize *pOffsets) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64 + bindingCount * 16);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdBindVertexBuffers, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, firstBinding);
    venus_enc_uint32(&enc, bindingCount);
    venus_enc_array_size(&enc, bindingCount);
    for (uint32_t i = 0; i < bindingCount; i++) {
        jackgpu_buffer *buf = (jackgpu_buffer *)(uintptr_t)pBuffers[i];
        venus_enc_handle(&enc, buf ? buf->venus_id : 0);
    }
    venus_enc_array_size(&enc, bindingCount);
    for (uint32_t i = 0; i < bindingCount; i++) {
        venus_enc_uint64(&enc, pOffsets[i]);
    }

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdBindIndexBuffer(VkCommandBuffer commandBuffer,
                                 VkBuffer buffer,
                                 VkDeviceSize offset,
                                 VkIndexType indexType) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;
    jackgpu_buffer *buf = (jackgpu_buffer *)(uintptr_t)buffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdBindIndexBuffer, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_handle(&enc, buf ? buf->venus_id : 0);
    venus_enc_uint64(&enc, offset);
    venus_enc_uint32(&enc, (uint32_t)indexType);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdBindDescriptorSets(VkCommandBuffer commandBuffer,
                                    VkPipelineBindPoint pipelineBindPoint,
                                    VkPipelineLayout layout,
                                    uint32_t firstSet,
                                    uint32_t descriptorSetCount,
                                    const VkDescriptorSet *pDescriptorSets,
                                    uint32_t dynamicOffsetCount,
                                    const uint32_t *pDynamicOffsets) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 128 + descriptorSetCount * 8 + dynamicOffsetCount * 4);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdBindDescriptorSets, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, (uint32_t)pipelineBindPoint);
    venus_enc_handle(&enc, (venus_object_id)(uintptr_t)layout);
    venus_enc_uint32(&enc, firstSet);
    venus_enc_uint32(&enc, descriptorSetCount);
    venus_enc_array_size(&enc, descriptorSetCount);
    for (uint32_t i = 0; i < descriptorSetCount; i++) {
        venus_enc_handle(&enc, (venus_object_id)(uintptr_t)pDescriptorSets[i]);
    }
    venus_enc_uint32(&enc, dynamicOffsetCount);
    venus_enc_array_size(&enc, dynamicOffsetCount);
    for (uint32_t i = 0; i < dynamicOffsetCount; i++) {
        venus_enc_uint32(&enc, pDynamicOffsets[i]);
    }

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdPipelineBarrier(VkCommandBuffer commandBuffer,
                                 VkPipelineStageFlags srcStageMask,
                                 VkPipelineStageFlags dstStageMask,
                                 VkDependencyFlags dependencyFlags,
                                 uint32_t memoryBarrierCount,
                                 const VkMemoryBarrier *pMemoryBarriers,
                                 uint32_t bufferMemoryBarrierCount,
                                 const VkBufferMemoryBarrier *pBufferMemoryBarriers,
                                 uint32_t imageMemoryBarrierCount,
                                 const VkImageMemoryBarrier *pImageMemoryBarriers) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    size_t est = 128 + memoryBarrierCount * 32 +
                 bufferMemoryBarrierCount * 64 +
                 imageMemoryBarrierCount * 80;
    jackgpu_cmd_rec_encoder(cmd, &enc, est);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdPipelineBarrier, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, srcStageMask);
    venus_enc_uint32(&enc, dstStageMask);
    venus_enc_uint32(&enc, dependencyFlags);

    /* Memory barriers */
    venus_enc_uint32(&enc, memoryBarrierCount);
    venus_enc_array_size(&enc, memoryBarrierCount);
    for (uint32_t i = 0; i < memoryBarrierCount; i++) {
        venus_enc_uint32(&enc, pMemoryBarriers[i].srcAccessMask);
        venus_enc_uint32(&enc, pMemoryBarriers[i].dstAccessMask);
    }

    /* Buffer memory barriers */
    venus_enc_uint32(&enc, bufferMemoryBarrierCount);
    venus_enc_array_size(&enc, bufferMemoryBarrierCount);
    for (uint32_t i = 0; i < bufferMemoryBarrierCount; i++) {
        venus_enc_uint32(&enc, pBufferMemoryBarriers[i].srcAccessMask);
        venus_enc_uint32(&enc, pBufferMemoryBarriers[i].dstAccessMask);
        venus_enc_uint32(&enc, pBufferMemoryBarriers[i].srcQueueFamilyIndex);
        venus_enc_uint32(&enc, pBufferMemoryBarriers[i].dstQueueFamilyIndex);
        jackgpu_buffer *buf = (jackgpu_buffer *)(uintptr_t)pBufferMemoryBarriers[i].buffer;
        venus_enc_handle(&enc, buf ? buf->venus_id : 0);
        venus_enc_uint64(&enc, pBufferMemoryBarriers[i].offset);
        venus_enc_uint64(&enc, pBufferMemoryBarriers[i].size);
    }

    /* Image memory barriers */
    venus_enc_uint32(&enc, imageMemoryBarrierCount);
    venus_enc_array_size(&enc, imageMemoryBarrierCount);
    for (uint32_t i = 0; i < imageMemoryBarrierCount; i++) {
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].srcAccessMask);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].dstAccessMask);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].oldLayout);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].newLayout);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].srcQueueFamilyIndex);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].dstQueueFamilyIndex);
        jackgpu_image *img = (jackgpu_image *)(uintptr_t)pImageMemoryBarriers[i].image;
        venus_enc_handle(&enc, img ? img->venus_id : 0);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].subresourceRange.aspectMask);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].subresourceRange.baseMipLevel);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].subresourceRange.levelCount);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].subresourceRange.baseArrayLayer);
        venus_enc_uint32(&enc, pImageMemoryBarriers[i].subresourceRange.layerCount);
    }

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdBeginRenderPass(VkCommandBuffer commandBuffer,
                                 const VkRenderPassBeginInfo *pRenderPassBegin,
                                 VkSubpassContents contents) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 256);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdBeginRenderPass, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_VkRenderPassBeginInfo(&enc, pRenderPassBegin);
    venus_enc_uint32(&enc, (uint32_t)contents);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdEndRenderPass(VkCommandBuffer commandBuffer) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdEndRenderPass, 0);
    venus_enc_handle(&enc, cmd->venus_id);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdCopyBuffer(VkCommandBuffer commandBuffer,
                            VkBuffer srcBuffer,
                            VkBuffer dstBuffer,
                            uint32_t regionCount,
                            const VkBufferCopy *pRegions) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;
    jackgpu_buffer *src = (jackgpu_buffer *)(uintptr_t)srcBuffer;
    jackgpu_buffer *dst = (jackgpu_buffer *)(uintptr_t)dstBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64 + regionCount * 24);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdCopyBuffer, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_handle(&enc, src ? src->venus_id : 0);
    venus_enc_handle(&enc, dst ? dst->venus_id : 0);
    venus_enc_uint32(&enc, regionCount);
    venus_enc_array_size(&enc, regionCount);
    for (uint32_t i = 0; i < regionCount; i++) {
        venus_enc_uint64(&enc, pRegions[i].srcOffset);
        venus_enc_uint64(&enc, pRegions[i].dstOffset);
        venus_enc_uint64(&enc, pRegions[i].size);
    }

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdDispatch(VkCommandBuffer commandBuffer,
                          uint32_t groupCountX,
                          uint32_t groupCountY,
                          uint32_t groupCountZ) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdDispatch, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_uint32(&enc, groupCountX);
    venus_enc_uint32(&enc, groupCountY);
    venus_enc_uint32(&enc, groupCountZ);

    jackgpu_cmd_rec_commit(cmd, &enc);
}

void jackgpu_CmdPushConstants(VkCommandBuffer commandBuffer,
                               VkPipelineLayout layout,
                               VkShaderStageFlags stageFlags,
                               uint32_t offset,
                               uint32_t size,
                               const void *pValues) {
    jackgpu_cmd_buffer *cmd = (jackgpu_cmd_buffer *)commandBuffer;

    venus_encoder enc;
    jackgpu_cmd_rec_encoder(cmd, &enc, 64 + size);

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCmdPushConstants, 0);
    venus_enc_handle(&enc, cmd->venus_id);
    venus_enc_handle(&enc, (venus_object_id)(uintptr_t)layout);
    venus_enc_uint32(&enc, stageFlags);
    venus_enc_uint32(&enc, offset);
    venus_enc_uint32(&enc, size);
    venus_enc_bytes(&enc, pValues, size);

    jackgpu_cmd_rec_commit(cmd, &enc);
}
