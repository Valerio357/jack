# JackGPU KMD — WDDM Kernel-Mode Display-Only Driver
#
# This CMakeLists.txt documents the build structure.
# Actual building requires the Windows Driver Kit (WDK).
#
# To build with WDK:
#   1. Install WDK for Windows 11 (22H2+)
#   2. Open "Developer Command Prompt for VS 2022"
#   3. Use the sources/Makefile below, or:
#      msbuild jackgpu_kmd.vcxproj /p:Configuration=Release /p:Platform=ARM64
#
# For cross-compilation from macOS, use the WDK Docker container
# or a Windows VM with Visual Studio + WDK installed.

cmake_minimum_required(VERSION 3.20)
project(jackgpu_kmd C)

message(STATUS "JackGPU KMD — WDDM kernel driver (requires WDK to build)")
message(STATUS "Source files:")
message(STATUS "  jackgpu_kmd.c  — DriverEntry and DDI callbacks")
message(STATUS "  virtqueue.c    — Virtio PCI device and virtqueue management")
message(STATUS "  escape.c       — DxgkDdiEscape command handler")
message(STATUS "  jackgpu_kmd.h  — Shared types and prototypes")
message(STATUS "  jackgpu_kmd.inf — Driver installation manifest")
