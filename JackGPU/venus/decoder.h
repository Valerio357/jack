/*
 * decoder.h — Venus wire format decoder
 *
 * Deserializes replies from the Venus renderer (host).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VENUS_DECODER_H
#define VENUS_DECODER_H

#include "driver/jackgpu.h"

struct venus_decoder {
    const uint8_t *buffer;
    size_t         size;
    size_t         offset;
    bool           error;
};

void     venus_dec_init(venus_decoder *dec, const void *buffer, size_t size);
uint32_t venus_dec_uint32(venus_decoder *dec);
int32_t  venus_dec_int32(venus_decoder *dec);
uint64_t venus_dec_uint64(venus_decoder *dec);
float    venus_dec_float(venus_decoder *dec);
void     venus_dec_bytes(venus_decoder *dec, void *out, size_t size);

venus_object_id venus_dec_handle(venus_decoder *dec);
uint64_t        venus_dec_array_size(venus_decoder *dec);
bool            venus_dec_pointer(venus_decoder *dec);

/* Decode reply header: returns VkResult */
VkResult venus_dec_reply_header(venus_decoder *dec);

/* Decode physical device properties from reply */
void venus_dec_VkPhysicalDeviceProperties(venus_decoder *dec, VkPhysicalDeviceProperties *props);
void venus_dec_VkPhysicalDeviceFeatures(venus_decoder *dec, VkPhysicalDeviceFeatures *features);
void venus_dec_VkPhysicalDeviceMemoryProperties(venus_decoder *dec, VkPhysicalDeviceMemoryProperties *props);
void venus_dec_VkQueueFamilyProperties(venus_decoder *dec, VkQueueFamilyProperties *props);
void venus_dec_VkMemoryRequirements(venus_decoder *dec, VkMemoryRequirements *reqs);

#endif /* VENUS_DECODER_H */
