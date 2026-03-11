/*
 * dispatch.h — Vulkan function dispatch table
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef JACKGPU_DISPATCH_H
#define JACKGPU_DISPATCH_H

#include "driver/jackgpu.h"

/* Retrieve instance-level and device-level function pointers */
PFN_vkVoidFunction jackgpu_GetInstanceProcAddr(VkInstance instance, const char *pName);
PFN_vkVoidFunction jackgpu_GetDeviceProcAddr(VkDevice device, const char *pName);

#endif /* JACKGPU_DISPATCH_H */
