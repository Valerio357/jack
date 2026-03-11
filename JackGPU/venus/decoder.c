/*
 * decoder.c — Venus wire format decoder implementation
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "venus/decoder.h"

static inline bool dec_has_data(venus_decoder *dec, size_t bytes) {
    if (dec->error) return false;
    if (dec->offset + bytes > dec->size) {
        dec->error = true;
        JACKGPU_ERR("decoder underflow: need %zu, have %zu",
                    bytes, dec->size - dec->offset);
        return false;
    }
    return true;
}

static inline void dec_read(venus_decoder *dec, void *out, size_t size) {
    if (dec_has_data(dec, size)) {
        memcpy(out, dec->buffer + dec->offset, size);
        dec->offset += size;
    }
}

static inline void dec_pad4(venus_decoder *dec) {
    dec->offset = JACKGPU_ALIGN(dec->offset, 4);
}

void venus_dec_init(venus_decoder *dec, const void *buffer, size_t size) {
    dec->buffer = (const uint8_t *)buffer;
    dec->size = size;
    dec->offset = 0;
    dec->error = false;
}

uint32_t venus_dec_uint32(venus_decoder *dec) {
    uint32_t val = 0;
    dec_read(dec, &val, 4);
    return val;
}

int32_t venus_dec_int32(venus_decoder *dec) {
    int32_t val = 0;
    dec_read(dec, &val, 4);
    return val;
}

uint64_t venus_dec_uint64(venus_decoder *dec) {
    uint64_t val = 0;
    dec_read(dec, &val, 8);
    return val;
}

float venus_dec_float(venus_decoder *dec) {
    float val = 0;
    dec_read(dec, &val, 4);
    return val;
}

void venus_dec_bytes(venus_decoder *dec, void *out, size_t size) {
    dec_read(dec, out, size);
    dec_pad4(dec);
}

venus_object_id venus_dec_handle(venus_decoder *dec) {
    return venus_dec_uint64(dec);
}

uint64_t venus_dec_array_size(venus_decoder *dec) {
    return venus_dec_uint64(dec);
}

bool venus_dec_pointer(venus_decoder *dec) {
    return venus_dec_uint64(dec) != 0;
}

VkResult venus_dec_reply_header(venus_decoder *dec) {
    /* Reply format: cmd_type (int32) + flags (uint32) + VkResult (int32) */
    venus_dec_int32(dec);  /* cmd type — skip */
    venus_dec_uint32(dec); /* flags — skip */
    return (VkResult)venus_dec_int32(dec);
}

void venus_dec_VkPhysicalDeviceProperties(venus_decoder *dec, VkPhysicalDeviceProperties *props) {
    props->apiVersion = venus_dec_uint32(dec);
    props->driverVersion = venus_dec_uint32(dec);
    props->vendorID = venus_dec_uint32(dec);
    props->deviceID = venus_dec_uint32(dec);
    props->deviceType = (VkPhysicalDeviceType)venus_dec_int32(dec);

    /* deviceName: fixed 256 bytes */
    venus_dec_bytes(dec, props->deviceName, VK_MAX_PHYSICAL_DEVICE_NAME_SIZE);

    /* pipelineCacheUUID: 16 bytes */
    venus_dec_bytes(dec, props->pipelineCacheUUID, VK_UUID_SIZE);

    /* VkPhysicalDeviceLimits — large struct, decode as blob */
    venus_dec_bytes(dec, &props->limits, sizeof(VkPhysicalDeviceLimits));

    /* VkPhysicalDeviceSparseProperties */
    venus_dec_bytes(dec, &props->sparseProperties, sizeof(VkPhysicalDeviceSparseProperties));
}

void venus_dec_VkPhysicalDeviceFeatures(venus_decoder *dec, VkPhysicalDeviceFeatures *features) {
    /* 55 VkBool32 fields — decode as blob */
    venus_dec_bytes(dec, features, sizeof(VkPhysicalDeviceFeatures));
}

void venus_dec_VkPhysicalDeviceMemoryProperties(venus_decoder *dec, VkPhysicalDeviceMemoryProperties *props) {
    props->memoryTypeCount = venus_dec_uint32(dec);
    for (uint32_t i = 0; i < props->memoryTypeCount; i++) {
        props->memoryTypes[i].propertyFlags = venus_dec_uint32(dec);
        props->memoryTypes[i].heapIndex = venus_dec_uint32(dec);
    }
    props->memoryHeapCount = venus_dec_uint32(dec);
    for (uint32_t i = 0; i < props->memoryHeapCount; i++) {
        props->memoryHeaps[i].size = (VkDeviceSize)venus_dec_uint64(dec);
        props->memoryHeaps[i].flags = venus_dec_uint32(dec);
    }
}

void venus_dec_VkQueueFamilyProperties(venus_decoder *dec, VkQueueFamilyProperties *props) {
    props->queueFlags = venus_dec_uint32(dec);
    props->queueCount = venus_dec_uint32(dec);
    props->timestampValidBits = venus_dec_uint32(dec);
    props->minImageTransferGranularity.width = venus_dec_uint32(dec);
    props->minImageTransferGranularity.height = venus_dec_uint32(dec);
    props->minImageTransferGranularity.depth = venus_dec_uint32(dec);
}

void venus_dec_VkMemoryRequirements(venus_decoder *dec, VkMemoryRequirements *reqs) {
    reqs->size = (VkDeviceSize)venus_dec_uint64(dec);
    reqs->alignment = (VkDeviceSize)venus_dec_uint64(dec);
    reqs->memoryTypeBits = venus_dec_uint32(dec);
}
