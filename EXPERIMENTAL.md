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
