/*
 * encoder.c — Venus wire format encoder implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "venus/encoder.h"

/* ── Internal helpers ─────────────────────────────────────── */

static inline bool enc_has_space(venus_encoder *enc, size_t bytes) {
    if (enc->error)
        return false;
    if (enc->offset + bytes > enc->capacity) {
        enc->error = true;
        JACKGPU_ERR("encoder overflow: need %zu, have %zu",
                    bytes, enc->capacity - enc->offset);
        return false;
    }
    return true;
}

static inline void enc_write(venus_encoder *enc, const void *data, size_t size) {
    if (enc_has_space(enc, size)) {
        memcpy(enc->buffer + enc->offset, data, size);
        enc->offset += size;
    }
}

/* Pad to 4-byte alignment */
static inline void enc_pad4(venus_encoder *enc) {
    size_t aligned = JACKGPU_ALIGN(enc->offset, 4);
    if (aligned != enc->offset) {
        size_t pad = aligned - enc->offset;
        if (enc_has_space(enc, pad)) {
            memset(enc->buffer + enc->offset, 0, pad);
            enc->offset = aligned;
        }
    }
}

/* Encode a string (uint64 length + chars + pad) */
static void enc_string(venus_encoder *enc, const char *str) {
    if (str) {
        uint64_t len = (uint64_t)strlen(str);
        venus_enc_array_size(enc, len);
        venus_enc_bytes(enc, str, (size_t)len);
    } else {
        venus_enc_array_size(enc, 0);
    }
}

/* ── Public API ───────────────────────────────────────────── */

void venus_enc_init(venus_encoder *enc, void *buffer, size_t capacity) {
    enc->buffer = (uint8_t *)buffer;
    enc->capacity = capacity;
    enc->offset = 0;
    enc->error = false;
}

void venus_enc_reset(venus_encoder *enc) {
    enc->offset = 0;
    enc->error = false;
}

void venus_enc_uint32(venus_encoder *enc, uint32_t val) {
    enc_write(enc, &val, 4);
}

void venus_enc_int32(venus_encoder *enc, int32_t val) {
    enc_write(enc, &val, 4);
}

void venus_enc_uint64(venus_encoder *enc, uint64_t val) {
    enc_write(enc, &val, 8);
}

void venus_enc_float(venus_encoder *enc, float val) {
    enc_write(enc, &val, 4);
}

void venus_enc_bytes(venus_encoder *enc, const void *data, size_t size) {
    enc_write(enc, data, size);
    enc_pad4(enc);
}

void venus_enc_handle(venus_encoder *enc, venus_object_id id) {
    venus_enc_uint64(enc, id);
}

void venus_enc_array_size(venus_encoder *enc, uint64_t count) {
    venus_enc_uint64(enc, count);
}

void venus_enc_pointer(venus_encoder *enc, const void *ptr) {
    venus_enc_uint64(enc, ptr ? 1 : 0);
}

void venus_enc_cmd_header(venus_encoder *enc, enum venus_cmd_type type, uint32_t flags) {
    venus_enc_int32(enc, (int32_t)type);
    venus_enc_uint32(enc, flags);
}

size_t venus_sizeof_cmd_header(void) {
    return 8; /* int32 type + uint32 flags */
}

/* ── Struct encoders ──────────────────────────────────────── */

void venus_enc_VkApplicationInfo(venus_encoder *enc, const VkApplicationInfo *info) {
    if (!info) return;

    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL); /* pNext — skip for now */

    enc_string(enc, info->pApplicationName);
    venus_enc_uint32(enc, info->applicationVersion);
    enc_string(enc, info->pEngineName);
    venus_enc_uint32(enc, info->engineVersion);
    venus_enc_uint32(enc, info->apiVersion);
}

void venus_enc_VkInstanceCreateInfo(venus_encoder *enc, const VkInstanceCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL); /* pNext */
    venus_enc_uint32(enc, info->flags);

    /* pApplicationInfo */
    venus_enc_pointer(enc, info->pApplicationInfo);
    if (info->pApplicationInfo) {
        venus_enc_VkApplicationInfo(enc, info->pApplicationInfo);
    }

    /* enabledLayerCount + ppEnabledLayerNames */
    venus_enc_uint32(enc, info->enabledLayerCount);
    venus_enc_array_size(enc, info->enabledLayerCount);
    for (uint32_t i = 0; i < info->enabledLayerCount; i++) {
        enc_string(enc, info->ppEnabledLayerNames[i]);
    }

    /* enabledExtensionCount + ppEnabledExtensionNames */
    venus_enc_uint32(enc, info->enabledExtensionCount);
    venus_enc_array_size(enc, info->enabledExtensionCount);
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
        enc_string(enc, info->ppEnabledExtensionNames[i]);
    }
}

void venus_enc_VkDeviceQueueCreateInfo(venus_encoder *enc, const VkDeviceQueueCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL); /* pNext */
    venus_enc_uint32(enc, info->flags);
    venus_enc_uint32(enc, info->queueFamilyIndex);
    venus_enc_uint32(enc, info->queueCount);

    venus_enc_array_size(enc, info->queueCount);
    for (uint32_t i = 0; i < info->queueCount; i++) {
        venus_enc_float(enc, info->pQueuePriorities[i]);
    }
}

void venus_enc_VkDeviceCreateInfo(venus_encoder *enc, const VkDeviceCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL); /* pNext — TODO: encode pNext chain for features */
    venus_enc_uint32(enc, info->flags);

    /* queueCreateInfoCount + pQueueCreateInfos */
    venus_enc_uint32(enc, info->queueCreateInfoCount);
    venus_enc_array_size(enc, info->queueCreateInfoCount);
    for (uint32_t i = 0; i < info->queueCreateInfoCount; i++) {
        venus_enc_VkDeviceQueueCreateInfo(enc, &info->pQueueCreateInfos[i]);
    }

    /* layers (deprecated but still on wire) */
    venus_enc_uint32(enc, info->enabledLayerCount);
    venus_enc_array_size(enc, info->enabledLayerCount);
    for (uint32_t i = 0; i < info->enabledLayerCount; i++) {
        enc_string(enc, info->ppEnabledLayerNames[i]);
    }

    /* extensions */
    venus_enc_uint32(enc, info->enabledExtensionCount);
    venus_enc_array_size(enc, info->enabledExtensionCount);
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
        enc_string(enc, info->ppEnabledExtensionNames[i]);
    }

    /* pEnabledFeatures */
    venus_enc_pointer(enc, info->pEnabledFeatures);
    if (info->pEnabledFeatures) {
        /* VkPhysicalDeviceFeatures is 55 VkBool32 fields */
        venus_enc_bytes(enc, info->pEnabledFeatures, sizeof(VkPhysicalDeviceFeatures));
    }
}

void venus_enc_VkCommandBufferAllocateInfo(venus_encoder *enc, const VkCommandBufferAllocateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->commandPool);
    venus_enc_int32(enc, (int32_t)info->level);
    venus_enc_uint32(enc, info->commandBufferCount);
}

void venus_enc_VkCommandBufferBeginInfo(venus_encoder *enc, const VkCommandBufferBeginInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
    venus_enc_pointer(enc, info->pInheritanceInfo);
    /* TODO: encode VkCommandBufferInheritanceInfo if present */
}

void venus_enc_VkMemoryAllocateInfo(venus_encoder *enc, const VkMemoryAllocateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint64(enc, info->allocationSize);
    venus_enc_uint32(enc, info->memoryTypeIndex);
}

void venus_enc_VkBufferCreateInfo(venus_encoder *enc, const VkBufferCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
    venus_enc_uint64(enc, info->size);
    venus_enc_uint32(enc, info->usage);
    venus_enc_int32(enc, (int32_t)info->sharingMode);
    venus_enc_uint32(enc, info->queueFamilyIndexCount);
    if (info->queueFamilyIndexCount > 0 && info->pQueueFamilyIndices) {
        venus_enc_array_size(enc, info->queueFamilyIndexCount);
        for (uint32_t i = 0; i < info->queueFamilyIndexCount; i++) {
            venus_enc_uint32(enc, info->pQueueFamilyIndices[i]);
        }
    } else {
        venus_enc_array_size(enc, 0);
    }
}

void venus_enc_VkImageCreateInfo(venus_encoder *enc, const VkImageCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
    venus_enc_int32(enc, (int32_t)info->imageType);
    venus_enc_int32(enc, (int32_t)info->format);
    venus_enc_uint32(enc, info->extent.width);
    venus_enc_uint32(enc, info->extent.height);
    venus_enc_uint32(enc, info->extent.depth);
    venus_enc_uint32(enc, info->mipLevels);
    venus_enc_uint32(enc, info->arrayLayers);
    venus_enc_int32(enc, (int32_t)info->samples);
    venus_enc_int32(enc, (int32_t)info->tiling);
    venus_enc_uint32(enc, info->usage);
    venus_enc_int32(enc, (int32_t)info->sharingMode);
    venus_enc_uint32(enc, info->queueFamilyIndexCount);
    if (info->queueFamilyIndexCount > 0 && info->pQueueFamilyIndices) {
        venus_enc_array_size(enc, info->queueFamilyIndexCount);
        for (uint32_t i = 0; i < info->queueFamilyIndexCount; i++) {
            venus_enc_uint32(enc, info->pQueueFamilyIndices[i]);
        }
    } else {
        venus_enc_array_size(enc, 0);
    }
    venus_enc_int32(enc, (int32_t)info->initialLayout);
}

void venus_enc_VkImageViewCreateInfo(venus_encoder *enc, const VkImageViewCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
    venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->image);
    venus_enc_int32(enc, (int32_t)info->viewType);
    venus_enc_int32(enc, (int32_t)info->format);
    /* VkComponentMapping */
    venus_enc_int32(enc, (int32_t)info->components.r);
    venus_enc_int32(enc, (int32_t)info->components.g);
    venus_enc_int32(enc, (int32_t)info->components.b);
    venus_enc_int32(enc, (int32_t)info->components.a);
    /* VkImageSubresourceRange */
    venus_enc_uint32(enc, info->subresourceRange.aspectMask);
    venus_enc_uint32(enc, info->subresourceRange.baseMipLevel);
    venus_enc_uint32(enc, info->subresourceRange.levelCount);
    venus_enc_uint32(enc, info->subresourceRange.baseArrayLayer);
    venus_enc_uint32(enc, info->subresourceRange.layerCount);
}

void venus_enc_VkShaderModuleCreateInfo(venus_encoder *enc, const VkShaderModuleCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
    venus_enc_uint64(enc, (uint64_t)info->codeSize);
    venus_enc_bytes(enc, info->pCode, info->codeSize);
}

void venus_enc_VkFenceCreateInfo(venus_encoder *enc, const VkFenceCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
}

void venus_enc_VkSemaphoreCreateInfo(venus_encoder *enc, const VkSemaphoreCreateInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_uint32(enc, info->flags);
}

void venus_enc_VkSubmitInfo(venus_encoder *enc, const VkSubmitInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);

    /* wait semaphores */
    venus_enc_uint32(enc, info->waitSemaphoreCount);
    venus_enc_array_size(enc, info->waitSemaphoreCount);
    for (uint32_t i = 0; i < info->waitSemaphoreCount; i++) {
        venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->pWaitSemaphores[i]);
    }
    venus_enc_array_size(enc, info->waitSemaphoreCount);
    for (uint32_t i = 0; i < info->waitSemaphoreCount; i++) {
        venus_enc_uint32(enc, info->pWaitDstStageMask[i]);
    }

    /* command buffers */
    venus_enc_uint32(enc, info->commandBufferCount);
    venus_enc_array_size(enc, info->commandBufferCount);
    for (uint32_t i = 0; i < info->commandBufferCount; i++) {
        venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->pCommandBuffers[i]);
    }

    /* signal semaphores */
    venus_enc_uint32(enc, info->signalSemaphoreCount);
    venus_enc_array_size(enc, info->signalSemaphoreCount);
    for (uint32_t i = 0; i < info->signalSemaphoreCount; i++) {
        venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->pSignalSemaphores[i]);
    }
}

void venus_enc_VkRenderPassBeginInfo(venus_encoder *enc, const VkRenderPassBeginInfo *info) {
    venus_enc_int32(enc, (int32_t)info->sType);
    venus_enc_pointer(enc, NULL);
    venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->renderPass);
    venus_enc_handle(enc, (venus_object_id)(uintptr_t)info->framebuffer);
    /* VkRect2D renderArea */
    venus_enc_int32(enc, info->renderArea.offset.x);
    venus_enc_int32(enc, info->renderArea.offset.y);
    venus_enc_uint32(enc, info->renderArea.extent.width);
    venus_enc_uint32(enc, info->renderArea.extent.height);
    /* clear values */
    venus_enc_uint32(enc, info->clearValueCount);
    venus_enc_array_size(enc, info->clearValueCount);
    for (uint32_t i = 0; i < info->clearValueCount; i++) {
        venus_enc_bytes(enc, &info->pClearValues[i], sizeof(VkClearValue));
    }
}

/* ── Size calculators ─────────────────────────────────────── */

size_t venus_sizeof_vkCreateInstance(const VkInstanceCreateInfo *info) {
    JACKGPU_UNUSED(info);
    /* Conservative estimate — actual size depends on strings */
    return 4096;
}

size_t venus_sizeof_vkCreateDevice(const VkDeviceCreateInfo *info) {
    JACKGPU_UNUSED(info);
    return 4096;
}
