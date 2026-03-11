/*
 * memory.c — VkDeviceMemory, VkBuffer, VkImage, VkImageView
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "driver/memory.h"
#include "driver/device.h"
#include "driver/instance.h"
#include "venus/encoder.h"
#include "venus/decoder.h"

/* ── Device Memory ────────────────────────────────────────── */

VkResult jackgpu_AllocateMemory(VkDevice device,
                                 const VkMemoryAllocateInfo *pAllocateInfo,
                                 const VkAllocationCallbacks *pAllocator,
                                 VkDeviceMemory *pMemory) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_device_memory *mem = (jackgpu_device_memory *)calloc(1, sizeof(jackgpu_device_memory));
    if (!mem)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    mem->device = dev;
    mem->size = pAllocateInfo->allocationSize;
    mem->memory_type_index = pAllocateInfo->memoryTypeIndex;
    mem->venus_id = jackgpu_transport_alloc_id(tp);

    uint8_t cmd_buf[256];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkAllocateMemory, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkMemoryAllocateInfo(&enc, pAllocateInfo);
    venus_enc_handle(&enc, mem->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(mem);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(mem);
        return host_result;
    }

    *pMemory = (VkDeviceMemory)(uintptr_t)mem;
    JACKGPU_LOG("memory allocated: venus_id=%llu, size=%llu, type=%u",
                mem->venus_id, (unsigned long long)mem->size, mem->memory_type_index);
    return VK_SUCCESS;
}

void jackgpu_FreeMemory(VkDevice device,
                         VkDeviceMemory memory,
                         const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!memory) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_device_memory *mem = (jackgpu_device_memory *)(uintptr_t)memory;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkFreeMemory, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, mem->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(mem);
}

VkResult jackgpu_MapMemory(VkDevice device,
                            VkDeviceMemory memory,
                            VkDeviceSize offset,
                            VkDeviceSize size,
                            VkMemoryMapFlags flags,
                            void **ppData) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_device_memory *mem = (jackgpu_device_memory *)(uintptr_t)memory;

    uint8_t cmd_buf[128];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkMapMemory, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, mem->venus_id);
    venus_enc_uint64(&enc, offset);
    venus_enc_uint64(&enc, size);
    venus_enc_uint32(&enc, flags);

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
    if (host_result != VK_SUCCESS)
        return host_result;

    /* The actual mapped pointer comes from host shared memory.
     * For now, store a placeholder — real mapping uses blob resources. */
    mem->mapped = tp->reply_shmem;
    *ppData = mem->mapped;
    return VK_SUCCESS;
}

void jackgpu_UnmapMemory(VkDevice device,
                          VkDeviceMemory memory) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_device_memory *mem = (jackgpu_device_memory *)(uintptr_t)memory;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkUnmapMemory, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, mem->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    mem->mapped = NULL;
}

/* ── Buffer ───────────────────────────────────────────────── */

VkResult jackgpu_CreateBuffer(VkDevice device,
                               const VkBufferCreateInfo *pCreateInfo,
                               const VkAllocationCallbacks *pAllocator,
                               VkBuffer *pBuffer) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_buffer *buf = (jackgpu_buffer *)calloc(1, sizeof(jackgpu_buffer));
    if (!buf)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    buf->device = dev;
    buf->venus_id = jackgpu_transport_alloc_id(tp);

    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateBuffer, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkBufferCreateInfo(&enc, pCreateInfo);
    venus_enc_handle(&enc, buf->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(buf);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(buf);
        return host_result;
    }

    *pBuffer = (VkBuffer)(uintptr_t)buf;
    return VK_SUCCESS;
}

void jackgpu_DestroyBuffer(VkDevice device,
                            VkBuffer buffer,
                            const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!buffer) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_buffer *buf = (jackgpu_buffer *)(uintptr_t)buffer;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyBuffer, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, buf->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(buf);
}

void jackgpu_GetBufferMemoryRequirements(VkDevice device,
                                          VkBuffer buffer,
                                          VkMemoryRequirements *pMemoryRequirements) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_buffer *buf = (jackgpu_buffer *)(uintptr_t)buffer;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkGetBufferMemoryRequirements, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, buf->venus_id);

    uint8_t reply_buf[128];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        memset(pMemoryRequirements, 0, sizeof(*pMemoryRequirements));
        return;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    venus_dec_reply_header(&dec);
    venus_dec_VkMemoryRequirements(&dec, pMemoryRequirements);
}

VkResult jackgpu_BindBufferMemory(VkDevice device,
                                   VkBuffer buffer,
                                   VkDeviceMemory memory,
                                   VkDeviceSize memoryOffset) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_buffer *buf = (jackgpu_buffer *)(uintptr_t)buffer;
    jackgpu_device_memory *mem = (jackgpu_device_memory *)(uintptr_t)memory;

    uint8_t cmd_buf[128];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkBindBufferMemory, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, buf->venus_id);
    venus_enc_handle(&enc, mem->venus_id);
    venus_enc_uint64(&enc, memoryOffset);

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

/* ── Image ────────────────────────────────────────────────── */

VkResult jackgpu_CreateImage(VkDevice device,
                              const VkImageCreateInfo *pCreateInfo,
                              const VkAllocationCallbacks *pAllocator,
                              VkImage *pImage) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_image *img = (jackgpu_image *)calloc(1, sizeof(jackgpu_image));
    if (!img)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    img->device = dev;
    img->venus_id = jackgpu_transport_alloc_id(tp);

    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateImage, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkImageCreateInfo(&enc, pCreateInfo);
    venus_enc_handle(&enc, img->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(img);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(img);
        return host_result;
    }

    *pImage = (VkImage)(uintptr_t)img;
    return VK_SUCCESS;
}

void jackgpu_DestroyImage(VkDevice device,
                           VkImage image,
                           const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!image) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_image *img = (jackgpu_image *)(uintptr_t)image;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyImage, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, img->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(img);
}

void jackgpu_GetImageMemoryRequirements(VkDevice device,
                                         VkImage image,
                                         VkMemoryRequirements *pMemoryRequirements) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_image *img = (jackgpu_image *)(uintptr_t)image;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkGetImageMemoryRequirements, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, img->venus_id);

    uint8_t reply_buf[128];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        memset(pMemoryRequirements, 0, sizeof(*pMemoryRequirements));
        return;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    venus_dec_reply_header(&dec);
    venus_dec_VkMemoryRequirements(&dec, pMemoryRequirements);
}

VkResult jackgpu_BindImageMemory(VkDevice device,
                                  VkImage image,
                                  VkDeviceMemory memory,
                                  VkDeviceSize memoryOffset) {
    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_image *img = (jackgpu_image *)(uintptr_t)image;
    jackgpu_device_memory *mem = (jackgpu_device_memory *)(uintptr_t)memory;

    uint8_t cmd_buf[128];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkBindImageMemory, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, img->venus_id);
    venus_enc_handle(&enc, mem->venus_id);
    venus_enc_uint64(&enc, memoryOffset);

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

/* ── Image View ───────────────────────────────────────────── */

VkResult jackgpu_CreateImageView(VkDevice device,
                                  const VkImageViewCreateInfo *pCreateInfo,
                                  const VkAllocationCallbacks *pAllocator,
                                  VkImageView *pView) {
    JACKGPU_UNUSED(pAllocator);

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;

    jackgpu_image_view *view = (jackgpu_image_view *)calloc(1, sizeof(jackgpu_image_view));
    if (!view)
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    view->device = dev;
    view->venus_id = jackgpu_transport_alloc_id(tp);

    uint8_t cmd_buf[512];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));

    venus_enc_cmd_header(&enc, VENUS_CMD_vkCreateImageView, VENUS_CMD_REPLY_BIT);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_VkImageViewCreateInfo(&enc, pCreateInfo);
    venus_enc_handle(&enc, view->venus_id);

    uint8_t reply_buf[64];
    VkResult result = jackgpu_transport_submit_cmd(tp,
                                                    venus_enc_data(&enc),
                                                    venus_enc_size(&enc),
                                                    reply_buf, sizeof(reply_buf));
    if (result != VK_SUCCESS) {
        free(view);
        return result;
    }

    venus_decoder dec;
    venus_dec_init(&dec, reply_buf, sizeof(reply_buf));
    VkResult host_result = venus_dec_reply_header(&dec);
    if (host_result != VK_SUCCESS) {
        free(view);
        return host_result;
    }

    *pView = (VkImageView)(uintptr_t)view;
    return VK_SUCCESS;
}

void jackgpu_DestroyImageView(VkDevice device,
                               VkImageView imageView,
                               const VkAllocationCallbacks *pAllocator) {
    JACKGPU_UNUSED(pAllocator);
    if (!imageView) return;

    jackgpu_device *dev = (jackgpu_device *)device;
    jackgpu_transport *tp = &dev->instance->transport;
    jackgpu_image_view *view = (jackgpu_image_view *)(uintptr_t)imageView;

    uint8_t cmd_buf[64];
    venus_encoder enc;
    venus_enc_init(&enc, cmd_buf, sizeof(cmd_buf));
    venus_enc_cmd_header(&enc, VENUS_CMD_vkDestroyImageView, 0);
    venus_enc_handle(&enc, dev->venus_id);
    venus_enc_handle(&enc, view->venus_id);
    jackgpu_transport_submit_cmd_no_reply(tp,
                                          venus_enc_data(&enc),
                                          venus_enc_size(&enc));

    free(view);
}
