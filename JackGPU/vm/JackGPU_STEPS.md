# JackGPU VM — Setup Steps

> **Legend**: 🤖 = automated by script (`build-image.sh` / `run.sh`) · 👤 = manual user action

## Prerequisites

```bash
brew install qemu wimlib xorriso mtools
```

- Windows 11 ARM64 ISO (download from Microsoft or CrystalFetch)
- virtio-win.iso (from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)

---

## Phase 1: Install Windows (one-time)

### Step 1: Prepare Support Images 🤖

Handled by `build-image.sh`:

```bash
# EFI vars + disk image
dd if=/dev/zero of=efi-vars.fd bs=1m count=64
qemu-img create -f qcow2 windows-arm64.qcow2 64G

# Unattend USB (autounattend.xml + bypass.bat)
dd if=/dev/zero of=unattend-usb.img bs=1m count=128
mformat -i unattend-usb.img -F -v UNATTEND ::
mcopy -i unattend-usb.img autounattend.xml ::/autounattend.xml
mcopy -i unattend-usb.img bypass.bat ::/bypass.bat

# Startup USB (auto-boots from UEFI shell)
dd if=/dev/zero of=startup-usb.img bs=1k count=1440
mformat -i startup-usb.img ::
printf 'FS0:\\efi\\boot\\bootaa64.efi\r\n' | mcopy -i startup-usb.img - ::/startup.nsh
```

### Step 2: Launch Installer 🤖

Handled by `build-image.sh`:

```bash
qemu-system-aarch64 \
    -M virt,highmem=on \
    -accel hvf \
    -cpu host \
    -smp 4 \
    -m 8G \
    -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on \
    -drive if=pflash,format=raw,file=efi-vars.fd \
    -drive if=virtio,id=system,format=qcow2,file=windows-arm64.qcow2,cache=writethrough \
    -device ramfb \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -device usb-storage,drive=install \
    -drive if=none,id=install,format=raw,media=cdrom,file=Win11_ARM64.iso \
    -device usb-storage,drive=virtio-drivers \
    -drive if=none,id=virtio-drivers,format=raw,media=cdrom,file=virtio-win.iso \
    -device usb-storage,drive=unattend \
    -drive if=none,id=unattend,format=raw,file=unattend-usb.img,readonly=on \
    -device usb-storage,drive=startup \
    -drive if=none,id=startup,format=raw,file=startup-usb.img,readonly=on \
    -nic user,model=virtio-net-pci \
    -display cocoa \
    -serial mon:stdio
```

### Step 3: Interactive Install 👤

User must perform these actions in the QEMU window:

1. **UEFI Shell** → `startup.nsh` auto-runs `FS0:\efi\boot\bootaa64.efi`
   - If it doesn't, type it manually
2. **"Press any key to boot from CD"** → press a key quickly
3. **"This PC doesn't meet requirements"** → Shift+F10, type `D:\bypass.bat` (or E:, F:)
   - Runs registry bypass for TPM, Secure Boot, RAM checks
   - Close cmd, click Back, proceed
4. **"Load driver" (no disk visible)** → Load driver → Browse → virtio-win drive → `viostor\w11\ARM64` → Install
5. **64GB disk appears** → select it → Continue with install
6. Wait ~20 minutes for installation to complete
7. VM shuts down when done

---

## Phase 2: First Boot & Configuration

### Step 4: Launch VM 🤖

Handled by `run.sh` (without installer ISOs, with port forwarding):

```bash
qemu-system-aarch64 \
    -M virt,highmem=on \
    -accel hvf \
    -cpu host \
    -smp 4 \
    -m 8G \
    -drive if=pflash,format=raw,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd,readonly=on \
    -drive if=pflash,format=raw,file=efi-vars.fd \
    -drive if=virtio,id=system,format=qcow2,file=windows-arm64.qcow2,cache=writethrough \
    -device ramfb \
    -device virtio-gpu-pci \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -device usb-storage,drive=virtio-drivers \
    -drive if=none,id=virtio-drivers,format=raw,media=cdrom,file=virtio-win.iso \
    -nic user,model=virtio-net-pci,hostfwd=tcp::3389-:3389,hostfwd=tcp::2222-:22 \
    -display cocoa \
    -serial mon:stdio
```

### Step 5: Install Remaining Drivers 👤

In Windows, open Device Manager and install drivers from the virtio-win drive:

| Driver | Path | Purpose |
|--------|------|---------|
| NetKVM | `NetKVM\w11\ARM64` | Network (virtio-net) |
| viogpudo | `viogpudo\w11\ARM64` | GPU (virtio-gpu) |
| Balloon | `Balloon\w11\ARM64` | Memory ballooning |
| viorng | `viorng\w11\ARM64` | Random number generator |
| viofs | `viofs\w11\ARM64` | Shared folders (virtio-fs/9p) |

Or install all at once from PowerShell (admin):
```powershell
$drv = (Get-Volume | Where-Object {$_.FileSystemLabel -like 'virtio*'}).DriveLetter + ':'
Get-ChildItem "$drv" -Directory | ForEach-Object {
    $inf = Join-Path $_.FullName "w11\ARM64\*.inf"
    if (Test-Path $inf) { pnputil /add-driver $inf /install }
}
```

### Step 6: Enable RDP 👤

```powershell
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
```
Then connect from macOS: `open rdp://localhost:3389`

### Step 7: Compact Disk Image (optional) 🤖

After setup is complete, shut down the VM and compact:
```bash
qemu-img convert -O qcow2 windows-arm64.qcow2 windows-arm64-compact.qcow2
mv windows-arm64-compact.qcow2 windows-arm64.qcow2
```

---

## Phase 3: Daily Use

### Launch VM 🤖
```bash
./run.sh              # Standard boot with virtio-gpu
./run.sh --venus      # Boot with Venus/Vulkan paravirt (QEMU 10.0+)
```

### Connect via RDP 👤
```bash
open rdp://localhost:3389
```

---

## Phase 4: JackGPU Development

Once the VM is running with virtio-gpu:

| Step | Type | Action |
|------|------|--------|
| Build JackGPU ICD | 🤖 | Cross-compile `jackgpu.dll` (Vulkan ICD, Venus encoder) |
| Build JackGPU KMD | 🤖 | Build `jackgpu_kmd.sys` (mini WDDM driver, virtio-gpu transport) |
| Install DXVK | 👤 | Copy DXVK DLLs into game directory in VM |
| Configure Venus host | 🤖 | Setup virglrenderer + MoltenVK on macOS |
| Test pipeline | 👤 | `Game.exe → DXVK → JackGPU ICD → Venus → virtio-gpu → MoltenVK → Metal` |

### Key ports
- RDP: `localhost:3389`
- SSH: `localhost:2222`
- Custom: `localhost:9944`
