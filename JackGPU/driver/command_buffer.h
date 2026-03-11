/*
 * command_buffer.h — VkCommandBuffer and VkCommandPool
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_COMMAND_BUFFER_H
#define JACKGPU_COMMAND_BUFFER_H

#include "driver/jackgpu.h"

/* Default size for command recording buffer (grows as needed) */
#define JACKGPU_CMD_RECORDING_INITIAL_SIZE  (64 * 1024)

typedef struct jackgpu_cmd_pool {
    jackgpu_device  *device;
    venus_object_id  venus_id;
} jackgpu_cmd_pool;

struct jackgpu_cmd_buffer {
    VK_LOADER_DATA loader_data;

    jackgpu_device  *device;
    venus_object_id  venus_id;
    venus_object_id  pool_venus_id;

    /* Local recording buffer — commands are encoded here during recording
     * and flushed to the host in batch when vkQueueSubmit is called. */
    uint8_t *recording_buf;
    size_t   recording_capacity;
    size_t   recording_size;
    bool     is_recording;
};

/* Command Pool */
VkResult jackgpu_CreateCommandPool(VkDevice device,
                                    const VkCommandPoolCreateInfo *pCreateInfo,
                                    const VkAllocationCallbacks *pAllocator,
                                    VkCommandPool *pCommandPool);

void jackgpu_DestroyCommandPool(VkDevice device,
                                 VkCommandPool commandPool,
                                 const VkAllocationCallbacks *pAllocator);

/* Command Buffer allocation */
VkResult jackgpu_AllocateCommandBuffers(VkDevice device,
                                         const VkCommandBufferAllocateInfo *pAllocateInfo,
                                         VkCommandBuffer *pCommandBuffers);

void jackgpu_FreeCommandBuffers(VkDevice device,
                                 VkCommandPool commandPool,
                                 uint32_t commandBufferCount,
                                 const VkCommandBuffer *pCommandBuffers);

/* Command Buffer recording */
VkResult jackgpu_BeginCommandBuffer(VkCommandBuffer commandBuffer,
                                     const VkCommandBufferBeginInfo *pBeginInfo);

VkResult jackgpu_EndCommandBuffer(VkCommandBuffer commandBuffer);

VkResult jackgpu_ResetCommandBuffer(VkCommandBuffer commandBuffer,
                                     VkCommandBufferResetFlags flags);

/* Recording commands (stubs — encode into local buffer) */
void jackgpu_CmdBindPipeline(VkCommandBuffer commandBuffer,
                              VkPipelineBindPoint pipelineBindPoint,
                              VkPipeline pipeline);

void jackgpu_CmdSetViewport(VkCommandBuffer commandBuffer,
                             uint32_t firstViewport,
                             uint32_t viewportCount,
                             const VkViewport *pViewports);

void jackgpu_CmdSetScissor(VkCommandBuffer commandBuffer,
                            uint32_t firstScissor,
                            uint32_t scissorCount,
                            const VkRect2D *pScissors);

void jackgpu_CmdDraw(VkCommandBuffer commandBuffer,
                      uint32_t vertexCount,
                      uint32_t instanceCount,
                      uint32_t firstVertex,
                      uint32_t firstInstance);

void jackgpu_CmdDrawIndexed(VkCommandBuffer commandBuffer,
                             uint32_t indexCount,
                             uint32_t instanceCount,
                             uint32_t firstIndex,
                             int32_t vertexOffset,
                             uint32_t firstInstance);

void jackgpu_CmdBindVertexBuffers(VkCommandBuffer commandBuffer,
                                   uint32_t firstBinding,
                                   uint32_t bindingCount,
                                   const VkBuffer *pBuffers,
                                   const VkDeviceSize *pOffsets);

void jackgpu_CmdBindIndexBuffer(VkCommandBuffer commandBuffer,
                                 VkBuffer buffer,
                                 VkDeviceSize offset,
                                 VkIndexType indexType);

void jackgpu_CmdBindDescriptorSets(VkCommandBuffer commandBuffer,
                                    VkPipelineBindPoint pipelineBindPoint,
                                    VkPipelineLayout layout,
                                    uint32_t firstSet,
                                    uint32_t descriptorSetCount,
                                    const VkDescriptorSet *pDescriptorSets,
                                    uint32_t dynamicOffsetCount,
                                    const uint32_t *pDynamicOffsets);

void jackgpu_CmdPipelineBarrier(VkCommandBuffer commandBuffer,
                                 VkPipelineStageFlags srcStageMask,
                                 VkPipelineStageFlags dstStageMask,
                                 VkDependencyFlags dependencyFlags,
                                 uint32_t memoryBarrierCount,
                                 const VkMemoryBarrier *pMemoryBarriers,
                                 uint32_t bufferMemoryBarrierCount,
                                 const VkBufferMemoryBarrier *pBufferMemoryBarriers,
                                 uint32_t imageMemoryBarrierCount,
                                 const VkImageMemoryBarrier *pImageMemoryBarriers);

void jackgpu_CmdBeginRenderPass(VkCommandBuffer commandBuffer,
                                 const VkRenderPassBeginInfo *pRenderPassBegin,
                                 VkSubpassContents contents);

void jackgpu_CmdEndRenderPass(VkCommandBuffer commandBuffer);

void jackgpu_CmdCopyBuffer(VkCommandBuffer commandBuffer,
                            VkBuffer srcBuffer,
                            VkBuffer dstBuffer,
                            uint32_t regionCount,
                            const VkBufferCopy *pRegions);

void jackgpu_CmdDispatch(VkCommandBuffer commandBuffer,
                          uint32_t groupCountX,
                          uint32_t groupCountY,
                          uint32_t groupCountZ);

void jackgpu_CmdPushConstants(VkCommandBuffer commandBuffer,
                               VkPipelineLayout layout,
                               VkShaderStageFlags stageFlags,
                               uint32_t offset,
                               uint32_t size,
                               const void *pValues);

#endif /* JACKGPU_COMMAND_BUFFER_H */
