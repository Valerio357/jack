# JackGPU

Windows Vulkan ICD (Installable Client Driver) for virtio-gpu Venus protocol on Apple Silicon.

Enables GPU-accelerated DirectX gaming in Windows ARM VMs on macOS via:
```
Game.exe → DXVK (DX→Vulkan) → JackGPU ICD (Venus) → virtio-gpu → MoltenVK → Metal
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Windows ARM VM (QEMU + Hypervisor.framework)       │
│                                                      │
│  Game.exe (DirectX 11/12)                           │
│      │                                               │
│  DXVK (DirectX → Vulkan)                            │
│      │                                               │
│  jackgpu.dll (Vulkan ICD)                           │
│      │  Venus wire protocol encoder                  │
│      │  Ring buffer shared memory                    │
│      │                                               │
│  jackgpu_kmd.sys (mini WDDM kernel driver)          │
│      │  virtio-gpu virtqueue transport               │
│      │                                               │
└──────┼──────────────────────────────────────────────┘
       │  virtio-gpu (shared memory + virtqueues)
┌──────┼──────────────────────────────────────────────┐
│  macOS Host                                          │
│      │                                               │
│  virglrenderer + Venus (deserialize Vulkan)          │
│      │                                               │
│  MoltenVK (Vulkan → Metal)                           │
│      │                                               │
│  Apple Silicon GPU (native Metal)                    │
└─────────────────────────────────────────────────────┘
```

## Components

| Component | Language | Description |
|---|---|---|
| `driver/` | C | Vulkan ICD DLL — entry points, dispatch, Vulkan object management |
| `venus/` | C | Venus wire format encoder/decoder (command serialization) |
| `transport/` | C | Guest↔host communication (D3DKMTEscape, ring buffer) |
| `kmd/` | C | Minimal WDDM kernel-mode driver (virtio-gpu virtqueue transport) |
| `manifest/` | JSON | Vulkan ICD manifest for Windows loader discovery |

## Build

Requires:
- Windows Driver Kit (WDK) for kernel driver
- CMake + MSVC or clang-cl for userspace ICD
- Vulkan SDK headers

```bash
cmake -B build -G "Visual Studio 17 2022" -A ARM64
cmake --build build --config Release
```

## Development on macOS

Cross-compilation setup for building Windows ARM64 binaries from macOS:
```bash
# Install cross-compiler
brew install llvm
# Build with clang-cl targeting Windows ARM64
cmake -B build -DCMAKE_TOOLCHAIN_FILE=cmake/windows-arm64.cmake
```

## References

- [Vulkan ICD Loader Interface](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md)
- [Mesa Venus driver](https://docs.mesa3d.org/drivers/venus.html)
- [Venus wire protocol](https://gitlab.freedesktop.org/mesa/mesa/-/tree/main/src/virtio/venus-protocol)
- [virtio-gpu spec](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
