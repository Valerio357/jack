# Experimental: Online Multiplayer & Anti-Cheat on Apple Silicon

Research notes on potential approaches to enable online multiplayer and bypass anti-cheat limitations on macOS with Apple Silicon.

---

## Current Architecture (Jack today)

```
Game.exe (x86_64, DirectX)
    │
    ├─ Rosetta 2: x86_64 → ARM64 (CPU instruction translation)
    ├─ Wine: Win32 API → POSIX/macOS (syscall, filesystem, registry)
    └─ D3DMetal: DirectX 11/12 → Metal (GPU, shader translation)
```

Three runtime translation layers. No recompilation — everything is translated on the fly.
Performance: ~60-80% of native. This is already the fastest approach on Apple Silicon.

---

## Problem 1: Online Multiplayer (No Anti-Cheat Games)

### Why it doesn't work today

Jack uses **Goldberg Steam Emulator** to bypass Steam DRM. Goldberg emulates `steam_api.dll` locally and generates **fake auth tickets**. Game servers validate tickets with Steam servers → fake tickets are rejected → no online play.

### Solution: Real Steam Auth Tickets

Jack already has a real Steam session via **JackSteamBridge** (SteamKit2, connected to Steam CM network). The approach:

1. Game calls `GetAuthSessionTicket()` → custom steam_api.dll (replaces Goldberg)
2. Custom DLL sends IPC request to JackSteamBridge via named pipe
3. JackSteamBridge calls `SteamUser.GetAuthSessionTicket()` on the real CM session
4. Returns the real ticket to the game → game server validates with Steam → accepted

```
Game (.exe under Wine)
  └→ custom steam_api.dll (replaces Goldberg)
       └→ IPC (named pipe) → JackSteamBridge (.NET)
            └→ SteamKit2 CM session (real auth)
                 └→ Steam servers ✓
```

### Implementation effort

- Fork Goldberg or write a custom steam_api.dll with IPC to the bridge
- Extend JackSteamBridge with `GetAuthSessionTicket`, `BeginAuthSession`, multiplayer callbacks
- Test with a simple online game without anti-cheat (e.g. indie co-op titles)

### Scope

Works for games **without kernel-level anti-cheat**: indie multiplayer, co-op games, older online titles.
Does NOT work for: CoD (Ricochet), Fortnite (EAC), Apex (EAC), Valorant (Vanguard).

---

## Problem 2: Anti-Cheat

### Why anti-cheat fails under Wine

Kernel-level anti-cheat systems (Ricochet, EAC, BattlEye, Vanguard) work by:

1. Loading a **kernel driver** (`.sys`) into Windows kernel (ntoskrnl.exe)
2. Monitoring process memory, syscalls, detecting debuggers/hooks at kernel level
3. Verifying OS integrity — expecting a real Windows kernel
4. Communicating with anti-cheat servers to validate the environment is "clean"

Under Wine on macOS:
- **No Windows kernel** — Wine translates userspace calls only, no kernel emulation
- **Kernel is XNU (Darwin)** — anti-cheat sees the wrong kernel and fails immediately
- **SIP (System Integrity Protection)** — macOS blocks any kernel inspection/modification
- **No kernel driver loading** — `.sys` drivers cannot be loaded on macOS

### Linux partial solution (not available on macOS)

Valve convinced EAC and BattlEye to add a **Wine/Proton mode** — a userspace-only version of the anti-cheat that runs without a kernel driver. But:
- Only works if the **game developer opts in** (per-title basis)
- Ricochet (CoD) does not support it and likely never will
- This Wine mode exists **only for Linux**, not macOS
- Apple has no equivalent of Steam Deck / Proton — no commercial incentive for anti-cheat vendors

---

## Approach A: Windows VM with GPU Passthrough

### Concept

Run a real Windows VM → anti-cheat sees real Windows → problem solved.
GPU passthrough gives the VM direct access to the physical GPU → near-native performance.

### Why traditional GPU passthrough is impossible on Apple Silicon

On a PC (Linux + NVIDIA/AMD):
```
CPU ←── PCIe bus ──→ GPU (physically separate chip)
```
The GPU can be detached from the host and attached to the VM via IOMMU. Works because they are physically separate components connected by a bus.

On Apple Silicon:
```
┌─────────────────────────────────┐
│  M1/M2/M3/M4 SoC               │
│  CPU + GPU + RAM + NPU + ISP   │
│  all on the same die            │
└─────────────────────────────────┘
```

- **No discrete GPU** — the GPU is part of the SoC, same silicon as the CPU
- **No PCIe bus to redirect** — there is no physical separation to exploit
- **No IOMMU for GPU** — Apple does not expose any GPU virtualization interface
- **Unified memory architecture** — CPU and GPU share the same memory pool, no separate VRAM

Traditional GPU passthrough is a hardware impossibility on Apple Silicon.

---

## Approach B: Paravirtualized GPU (Viable Path)

### Overview

Instead of passing through a physical GPU, **forward GPU commands** from the VM guest to the host's Metal GPU via a paravirtualized driver. Multiple real projects are actively building the pieces for this.

### Existing APIs and Projects

#### 1. Apple ParavirtualizedGraphics.framework (PVG)

Apple's **official public framework** for GPU paravirtualization in VMs.

- **`PGDevice`** — paravirtualized GPU device object
- **`PGDisplay`** — virtual display for the guest OS
- Provides **full Metal** to the guest VM
- Shares memory between VM and PVG via MMIO callbacks
- Integrated in **QEMU 10.0** as `apple-gfx-pci` (x86_64 guests) and `apple-gfx-mmio` (ARM64 guests)
- Works on both ARM and x86 guests with macOS 11+

**Limitation**: Apple only provides a guest driver for **macOS guests**, not Windows. A custom Windows guest driver would need to be written.

Documentation: https://developer.apple.com/documentation/paravirtualizedgraphics

#### 2. Virtio-GPU Venus (Vulkan Paravirtualization)

Open-source Vulkan command forwarding from guest to host, near-native performance.

- **Venus** serializes Vulkan API calls and forwards them to the host with minimal overhead
- Shaders are passed as **SPIR-V binary** — no recompilation needed on host
- Supports **Vulkan 1.3** and all extensions required by **DXVK**
- Performance: **"within a good ballpark of PCI passthrough"** (Collabora)
- Stable since May 2023 on Linux hosts
- **macOS host support in development**: UTM submitted [RFC v2 patches](https://patchew.org/QEMU/20251219183853.4426-1-j@getutm.app/) adding Venus + Metal texture scanout to QEMU for macOS
- On macOS: Venus → **MoltenVK** → Metal (native GPU)

Documentation: https://docs.mesa3d.org/drivers/venus.html

#### 3. viogpu3d (Windows Guest Driver for virtio-gpu 3D)

Active [pull request](https://github.com/virtio-win/kvm-guest-drivers-windows/pull/943) adding 3D acceleration to Windows guests.

- VirtIO-GPU display driver for Windows with 3D acceleration
- Supports `d3d10umd` rendering on VirGL
- Still experimental (rendering glitches, crashes)
- Combined with Venus + DXVK: provides Vulkan to Windows guests → DirectX games can use DXVK

#### 4. IOSurface (Cross-Process GPU Memory Sharing)

Apple's public API for **zero-copy GPU buffer sharing** between processes.

- `MTLDevice.makeTexture(descriptor:iosurface:plane:)` — create Metal texture from shared IOSurface
- Kernel-managed texture memory, automatically paged on/off GPU
- **No data copying** when shared across processes
- Unified Memory Architecture on Apple Silicon makes this extremely efficient
- Could be used for host↔VM framebuffer sharing

Documentation: https://developer.apple.com/documentation/iosurface

#### 5. MoltenVK (Vulkan → Metal)

Stable, production-ready translation layer.

- Translates Vulkan API calls to Metal
- Used by DXVK-macOS, Steam Proton, Valve
- Open source (Apache 2.0)
- Already works on Apple Silicon

### The Complete Pipeline

```
Windows ARM VM (QEMU + Hypervisor.framework)
  │
  Game.exe (DirectX 11/12)
  │
  DXVK (DirectX → Vulkan, inside the VM)
  │
  Venus guest driver (serializes Vulkan → virtio-gpu transport)
  │
  ─── VM / host boundary (shared memory, virtio-gpu) ───
  │
  virglrenderer + Venus host (deserializes Vulkan)
  │
  MoltenVK (Vulkan → Metal)
  │
  Apple Silicon GPU (native Metal)
```

Anti-cheat is satisfied because the game runs on a **real Windows kernel** with real ntoskrnl.exe, real kernel drivers, and real anti-cheat driver loading.

### Component Status

| Component | Status | Who |
|---|---|---|
| QEMU + Hypervisor.framework | Working | UTM, Apple |
| ParavirtualizedGraphics.framework | Public API, working | Apple |
| Venus on macOS host | RFC v2, active development | UTM (osy) |
| viogpu3d (Windows virtio-gpu driver) | PR open, experimental | virtio-win community |
| DXVK (DirectX → Vulkan) | Stable, production | doitsujin |
| MoltenVK (Vulkan → Metal) | Stable, production | Khronos / Valve |
| Windows ARM on Apple Silicon | Working (UTM/Parallels) | Microsoft / UTM |

### Performance Estimate (Updated)

```
Wine + D3DMetal (Jack today):             ~60-80% native (no anti-cheat)
VM + Venus + MoltenVK (optimized):        ~60-75% native (with anti-cheat)
VM + ParavirtualizedGraphics:             ~70-85% native (macOS guest only)
VM + Parallels (current):                 ~20-30% native
Traditional GPU passthrough:              impossible on Apple Silicon
```

Venus performance is described as close to PCI passthrough because Vulkan commands and SPIR-V shaders are forwarded with minimal transformation — unlike VirGL/OpenGL which requires double translation.

---

## Approach C: Native Porting / AOT Binary Translation

### Why "recompiling" downloaded games is impossible

A compiled .exe is machine code — variable names, function names, code structure are **lost** during compilation. Decompilation produces unreadable, non-recompilable output:

```c
// Original source (lost forever)
float health = player.GetHealth() * 0.5f;

// Decompiled
float v23 = (*(float(__thiscall**)(int))(*(int*)v4 + 0x1C))(v4) * 0.5f;
```

You cannot recompile this to ARM64/Metal. Nobody can. True native porting requires **source code**, which is owned by the game studios (Activision, FromSoftware, Capcom, etc.).

### AOT (Ahead-of-Time) binary translation

Instead of runtime translation, pre-translate everything:

1. Take the x86 .exe
2. Translate all x86 machine code → ARM64 ahead of time (not at runtime)
3. Pre-convert DXBC/DXIL shaders → Metal shader binaries
4. Cache the result as a "native" binary

This is what **FEX-Emu** does on Linux and partially what **Rosetta AOT cache** does. But:

- The translation is mechanical 1:1 instruction mapping, not "smart recompilation"
- Performance is similar to runtime translation because the translation quality is the same
- The translated binary still calls Wine/D3DMetal for API translation
- Marginal benefit: eliminates JIT compilation overhead (~5-10% improvement at best)

---

## Approach D: Removing Anti-Cheat from Binaries

### Technically possible, practically useless

Anti-cheat code can be patched out of game binaries (NOP out checks, patch jumps). But:

- Game servers perform **server-side validation** — you would be detected and banned
- Anti-cheat updates frequently — patches would need to be maintained per game per update
- Violates Terms of Service and potentially laws (DMCA, CFAA)
- Even if client-side checks are bypassed, server-side detection remains

This approach is not viable for legitimate use.

---

## Conclusion

| Approach | Feasibility | Performance | Anti-Cheat | Effort |
|---|---|---|---|---|
| **Real auth tickets (IPC bridge)** | High | ~60-80% native | No | Weeks |
| **VM + Venus + DXVK + MoltenVK** | Medium | ~60-75% native | Yes | Months |
| **VM + ParavirtualizedGraphics** | Low (no Win driver) | ~70-85% native | Yes | Years |
| **AOT binary translation** | Low | ~5-10% gain | No | Months |
| **Anti-cheat binary patching** | Possible but illegal | Same | Bypassed (banned) | Per-game |

### Recommended roadmap

**Phase 1 (weeks):** Real auth tickets via IPC bridge — online multiplayer for non-anti-cheat games. Builds on existing JackSteamBridge architecture.

**Phase 2 (months):** VM + Venus + DXVK + MoltenVK — once UTM merges Venus macOS support, integrate a Windows ARM VM mode into Jack with GPU-accelerated gaming and full anti-cheat support. The key missing piece is a stable **viogpu3d Windows driver** with Venus/Vulkan support.

**Phase 3 (long-term):** If Apple expands ParavirtualizedGraphics.framework with a Windows guest driver or public guest driver API, this becomes the highest-performance path.

### Key insight

The pieces for VM-based gaming with anti-cheat on Apple Silicon **already exist in various stages of development**. Nobody has assembled them into a complete solution yet. Jack could be the first app to do this.

---

## JackGPU — Custom Implementation (In Progress)

Rather than waiting for viogpu3d or other community drivers, we are building our own complete GPU paravirtualization stack from scratch. This gives us full control and removes dependencies on third-party driver timelines.

### Architecture

```
Windows ARM64 VM (QEMU + Apple Hypervisor.framework)
  │
  Game.exe (DirectX 11/12)
  │
  DXVK (DirectX → Vulkan)
  │
  JackGPU Vulkan ICD (jackgpu.dll) ←── userspace, Windows
  │  Implements Vulkan 1.3 ICD interface
  │  Encodes Vulkan calls via Venus wire protocol
  │  Communicates with kernel via D3DKMTEscape
  │
  JackGPU KMD (jackgpu_kmd.sys) ←── kernel, Windows
  │  WDDM Display-Only driver (KMDOD)
  │  Translates escape commands → virtio-gpu virtqueue commands
  │  Manages shared memory blobs, ring buffers, contexts
  │
  ─── VM / host boundary (virtio-gpu PCI, shared memory) ───
  │
  virglrenderer + Venus host (deserializes Vulkan)
  │
  MoltenVK (Vulkan → Metal)
  │
  Apple Silicon GPU (native Metal)
```

### Components Built

#### 1. JackGPU Vulkan ICD (`JackGPU/driver/`) — Complete

A full Windows Vulkan ICD (Installable Client Driver) that the Vulkan loader discovers and uses.

- **ICD entry points** (`icd.c`): `vk_icdNegotiateLoaderICDInterfaceVersion` (v5), `vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr`
- **63 Vulkan functions** implemented across instance, physical device, device, queue, memory, command buffer, sync, and dispatch
- **Venus wire protocol** encoder/decoder (`venus/encoder.c`, `venus/decoder.c`): serializes all Vulkan commands into the Venus binary format (little-endian, 4-byte aligned, 64-bit object IDs)
- **Transport layer** (`transport/`): ring buffer protocol matching Mesa's `vn_ring`, D3DKMTEscape wrapper for kernel communication, blob resource management
- **ICD manifest** (`manifest/jackgpu_x64.json`): Vulkan loader discovers the driver via this JSON file
- Compiles on macOS (stub transport) and Windows (real D3DKMT transport)

**Vulkan coverage**: instance creation/destruction, physical device enumeration/properties/features/memory/queues, device creation, queue submit, memory allocation/mapping, buffers, images, image views, samplers, shader modules, render passes, framebuffers, graphics/compute pipelines, pipeline layouts, descriptor sets/pools/layouts, command buffers (bindPipeline, bindVertexBuffers, bindIndexBuffer, draw, drawIndexed, dispatch, copyBuffer, copyImage, blitImage, copyBufferToImage, pipelineBarrier, beginRenderPass, endRenderPass, pushConstants), fences, semaphores, swapchain (KHR).

#### 2. JackGPU WDDM Kernel Driver (`JackGPU/kmd/`) — Complete

A WDDM KMDOD (Kernel-Mode Display-Only Driver) for the virtio-gpu PCI device.

- **DriverEntry** (`jackgpu_kmd.c`): Registers via `DxgkInitializeDisplayOnlyDriver` with all required DDI callbacks
- **Virtio PCI initialization** (`virtqueue.c`): Parses PCI capabilities, performs full virtio handshake (reset → acknowledge → driver → features_ok → driver_ok), sets up virtqueues with physically contiguous DMA memory
- **Virtqueue management**: Lock-free descriptor ring, available/used ring protocol, interrupt-driven completion with DPC processing
- **DxgkDdiEscape handler** (`escape.c`): 12 escape commands matching the ICD's D3DKMTEscape interface:
  - `GET_CAPSET` → `VIRTIO_GPU_CMD_GET_CAPSET`
  - `CREATE/DESTROY_CONTEXT` → `VIRTIO_GPU_CMD_CTX_CREATE/DESTROY`
  - `CREATE_BLOB` → `VIRTIO_GPU_CMD_RESOURCE_CREATE_BLOB` with scatter-gather backing
  - `MAP_BLOB` → MDL mapping into user address space via `MmMapLockedPagesSpecifyCache`
  - `UNMAP_BLOB` / `DESTROY_RESOURCE` → cleanup + `VIRTIO_GPU_CMD_RESOURCE_UNREF`
  - `EXECBUFFER` → `VIRTIO_GPU_CMD_SUBMIT_3D` (Venus command passthrough)
  - `CREATE_RING` / `SET_REPLY_STREAM` → `VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE`
  - `NOTIFY_RING` → zero-length SUBMIT_3D ping to wake host renderer
- **Resource tracking**: Up to 1024 concurrent blob resources with kernel↔user mapping
- **INF file** (`jackgpu_kmd.inf`): Targets `PCI\VEN_1AF4&DEV_1050` (virtio-gpu 1.0), supports ARM64 and x64
- **Build system**: WDK Makefile + packaging/signing instructions

#### 3. Venus Wire Protocol (`JackGPU/venus/`) — Complete

Encoder and decoder for the Venus binary protocol (matches Mesa's implementation).

- Encodes: uint32, int32, uint64, float, bytes, handles, array sizes, pointers, and all complex Vulkan structs (`VkInstanceCreateInfo`, `VkDeviceCreateInfo`, `VkBufferCreateInfo`, `VkImageCreateInfo`, `VkShaderModuleCreateInfo`, `VkSubmitInfo`, `VkRenderPassBeginInfo`, etc.)
- Decodes: reply headers, `VkPhysicalDeviceProperties`, `VkPhysicalDeviceFeatures`, `VkPhysicalDeviceMemoryProperties`, `VkQueueFamilyProperties`, `VkMemoryRequirements`
- 80+ Venus command types defined

#### 4. QEMU VM Environment (`JackGPU/vm/`) — In Progress

Windows 11 ARM64 VM running on QEMU with Apple Hypervisor.framework (HVF).

- **QEMU 10.2.1** (ARM64 native via Homebrew) with HVF acceleration
- **Configuration**: `ramfb` display, NVMe boot disk (128GB), USB-storage for ISOs, virtio-net networking
- **Windows 11 25H2 ARM64** installation in progress (TPM/SecureBoot bypass via registry)
- **Shared folder**: virtio-9p mount for game files from host
- **Port forwarding**: RDP (3389), SSH (2222)

### Why Build From Scratch Instead of Using viogpu3d?

| Factor | viogpu3d | JackGPU |
|---|---|---|
| **API level** | OpenGL / D3D10 (VirGL) | Vulkan 1.3 (Venus) |
| **Status** | Experimental PR, rendering glitches | Purpose-built for our pipeline |
| **DXVK compatible** | No (needs Vulkan) | Yes (native Vulkan ICD) |
| **Control** | Depends on upstream maintainers | We own the full stack |
| **Performance** | VirGL double-translation overhead | Venus near-native Vulkan |
| **Target** | General purpose | Optimized for gaming + anti-cheat |

viogpu3d provides OpenGL/D3D10 via VirGL — not enough for modern games. JackGPU provides Vulkan directly, which DXVK needs for DirectX 11/12 → Vulkan translation. Building from scratch means we control the entire pipeline and don't depend on upstream driver schedules.

### Possible Evolutions

#### Short-term
- Complete Windows 11 ARM64 VM setup and driver installation
- Cross-compile JackGPU ICD as Windows ARM64 DLL
- Build KMD with WDK in the VM, test-sign, install
- Validate end-to-end: Vulkan loader → JackGPU ICD → KMD → virtio-gpu → host

#### Medium-term
- Compile QEMU with virglrenderer + Venus support (custom build with MoltenVK backend)
- Test with simple Vulkan applications (vkcube, triangle demos)
- Test DXVK + DirectX games (Cuphead, simple titles first)
- Add swapchain presentation via virtio-gpu scanout

#### Long-term
- Integrate VM management into Jack app (one-click Windows VM launch)
- Automate driver installation in the VM
- Test with demanding titles (COD Ghosts `iw6mp64_ship.exe`, Sekiro, etc.)
- Investigate Apple ParavirtualizedGraphics as alternative backend (needs reverse-engineering guest protocol)
- Optimize Venus encoding/ring buffer for minimal latency
- Add timeline semaphore support for async compute
- Explore running anti-cheat games (Ricochet, EAC) — real Windows kernel should satisfy anti-cheat checks

### Current LOC

```
JackGPU/driver/    — ~1500 LOC (Vulkan ICD, 14 files)
JackGPU/venus/     — ~1200 LOC (encoder/decoder, 4 files)
JackGPU/transport/ — ~650 LOC  (ring, virtgpu, d3dkmt, 6 files)
JackGPU/kmd/       — ~2000 LOC (WDDM kernel driver, 5 files)
JackGPU/vm/        — ~200 LOC  (QEMU scripts, 2 files)
Total:             — ~5550 LOC
```

---

## References

- [Apple ParavirtualizedGraphics.framework](https://developer.apple.com/documentation/paravirtualizedgraphics)
- [Apple PGDevice API](https://developer.apple.com/documentation/paravirtualizedgraphics/pgdevice)
- [Apple IOSurface API](https://developer.apple.com/documentation/iosurface)
- [Venus macOS host patches (UTM)](https://patchew.org/QEMU/20251219183853.4426-1-j@getutm.app/)
- [Virtio-GPU Venus documentation](https://docs.mesa3d.org/drivers/venus.html)
- [State of GFX virtualization (Collabora, Jan 2025)](https://www.collabora.com/news-and-blog/blog/2025/01/15/the-state-of-gfx-virtualization-using-virglrenderer/)
- [viogpu3d Windows driver PR](https://github.com/virtio-win/kvm-guest-drivers-windows/pull/943)
- [GPU acceleration in macOS containers (Sergio López)](https://sinrega.org/2024-03-06-enabling-containers-gpu-macos/)
- [GPU access in Apple Silicon VMs (Eclectic Light)](https://eclecticlight.co/2023/10/26/how-good-is-gpu-access-for-apple-silicon-virtual-machines/)
- [QEMU ParavirtualizedGraphics patches](https://lists.gnu.org/archive/html/qemu-riscv/2024-11/msg00039.html)
