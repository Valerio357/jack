/*
 * encoder.h — Venus wire format encoder
 *
 * Serializes Vulkan commands into the Venus wire protocol format.
 * Wire format: little-endian, 4-byte aligned, matches Mesa venus-protocol.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef VENUS_ENCODER_H
#define VENUS_ENCODER_H

#include "driver/jackgpu.h"

/* ── Encoder state ────────────────────────────────────────── */

struct venus_encoder {
    uint8_t *buffer;       /* Command buffer start */
    size_t   capacity;     /* Total buffer size */
    size_t   offset;       /* Current write position */
    bool     error;        /* Set on overflow */
};

/* Initialize encoder with external buffer */
void venus_enc_init(venus_encoder *enc, void *buffer, size_t capacity);

/* Reset encoder to beginning */
void venus_enc_reset(venus_encoder *enc);

/* Get encoded size so far */
static inline size_t venus_enc_size(const venus_encoder *enc) {
    return enc->offset;
}

/* Get pointer to encoded data */
static inline const void *venus_enc_data(const venus_encoder *enc) {
    return enc->buffer;
}

/* ── Primitive encoders ───────────────────────────────────── */

/* All values are little-endian, naturally aligned.
 * uint8_t and uint16_t are padded to 4 bytes on the wire. */

void venus_enc_uint32(venus_encoder *enc, uint32_t val);
void venus_enc_int32(venus_encoder *enc, int32_t val);
void venus_enc_uint64(venus_encoder *enc, uint64_t val);
void venus_enc_float(venus_encoder *enc, float val);
void venus_enc_bytes(venus_encoder *enc, const void *data, size_t size);

/* Encode a Vulkan handle as 64-bit object ID */
void venus_enc_handle(venus_encoder *enc, venus_object_id id);

/* Encode array size (uint64_t) */
void venus_enc_array_size(venus_encoder *enc, uint64_t count);

/* Encode a simple pointer flag (1 = present, 0 = NULL) */
void venus_enc_pointer(venus_encoder *enc, const void *ptr);

/* ── Command header ───────────────────────────────────────── */

/* Write command header: type (int32) + flags (uint32) */
void venus_enc_cmd_header(venus_encoder *enc, enum venus_cmd_type type, uint32_t flags);

/* ── Struct encoders ──────────────────────────────────────── */

/* Encode VkApplicationInfo (for vkCreateInstance) */
void venus_enc_VkApplicationInfo(venus_encoder *enc, const VkApplicationInfo *info);

/* Encode VkInstanceCreateInfo */
void venus_enc_VkInstanceCreateInfo(venus_encoder *enc, const VkInstanceCreateInfo *info);

/* Encode VkDeviceQueueCreateInfo */
void venus_enc_VkDeviceQueueCreateInfo(venus_encoder *enc, const VkDeviceQueueCreateInfo *info);

/* Encode VkDeviceCreateInfo */
void venus_enc_VkDeviceCreateInfo(venus_encoder *enc, const VkDeviceCreateInfo *info);

/* Encode VkCommandBufferAllocateInfo */
void venus_enc_VkCommandBufferAllocateInfo(venus_encoder *enc, const VkCommandBufferAllocateInfo *info);

/* Encode VkCommandBufferBeginInfo */
void venus_enc_VkCommandBufferBeginInfo(venus_encoder *enc, const VkCommandBufferBeginInfo *info);

/* Encode VkMemoryAllocateInfo */
void venus_enc_VkMemoryAllocateInfo(venus_encoder *enc, const VkMemoryAllocateInfo *info);

/* Encode VkBufferCreateInfo */
void venus_enc_VkBufferCreateInfo(venus_encoder *enc, const VkBufferCreateInfo *info);

/* Encode VkImageCreateInfo */
void venus_enc_VkImageCreateInfo(venus_encoder *enc, const VkImageCreateInfo *info);

/* Encode VkImageViewCreateInfo */
void venus_enc_VkImageViewCreateInfo(venus_encoder *enc, const VkImageViewCreateInfo *info);

/* Encode VkShaderModuleCreateInfo */
void venus_enc_VkShaderModuleCreateInfo(venus_encoder *enc, const VkShaderModuleCreateInfo *info);

/* Encode VkFenceCreateInfo */
void venus_enc_VkFenceCreateInfo(venus_encoder *enc, const VkFenceCreateInfo *info);

/* Encode VkSemaphoreCreateInfo */
void venus_enc_VkSemaphoreCreateInfo(venus_encoder *enc, const VkSemaphoreCreateInfo *info);

/* Encode VkSubmitInfo */
void venus_enc_VkSubmitInfo(venus_encoder *enc, const VkSubmitInfo *info);

/* Encode VkRenderPassBeginInfo */
void venus_enc_VkRenderPassBeginInfo(venus_encoder *enc, const VkRenderPassBeginInfo *info);

/* ── Size calculators ─────────────────────────────────────── */
/* Return wire size of a command (header + params), used to check
 * ring buffer space before encoding. */

size_t venus_sizeof_cmd_header(void);
size_t venus_sizeof_vkCreateInstance(const VkInstanceCreateInfo *info);
size_t venus_sizeof_vkCreateDevice(const VkDeviceCreateInfo *info);

#endif /* VENUS_ENCODER_H */
