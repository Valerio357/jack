#!/bin/bash
# JackGPU VM Run — Launch Windows ARM64 VM with virtio-gpu
#
# Modes:
#   ./run.sh              — Standard boot with virtio-gpu
#   ./run.sh --apple-gfx  — Boot with Apple ParavirtualizedGraphics (Metal)
#   ./run.sh --venus      — Boot with virtio-gpu + Venus/virgl (when supported)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$SCRIPT_DIR"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"

RAM="8G"
CPUS="4"
DISK_IMG="$VM_DIR/windows-arm64.qcow2"
EFI_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS="$VM_DIR/efi-vars.fd"

if [ ! -f "$DISK_IMG" ]; then
    echo "ERROR: No disk image. Run setup.sh first."
    exit 1
fi

# GPU device selection
# ramfb provides a simple framebuffer for UEFI/early boot display
GPU_DEVICE="-device ramfb -device virtio-gpu-pci"
GPU_MODE="virtio-gpu (basic) + ramfb"

case "${1:-}" in
    --apple-gfx)
        GPU_DEVICE="-device ramfb -device apple-gfx-pci"
        GPU_MODE="Apple ParavirtualizedGraphics (Metal) + ramfb"
        ;;
    --venus)
        # Venus requires blob=on and venus=on (QEMU 10.0+)
        GPU_DEVICE="-device ramfb -device virtio-gpu-pci,blob=on,hostmem=4G,venus=on"
        GPU_MODE="virtio-gpu + Venus (Vulkan paravirt) + ramfb"
        ;;
esac

# Shared folder (games directory accessible via virtio-9p)
SHARED_DIR="/Volumes/Volume/Jack/SteamCMD/games"
SHARE_ARGS=""
if [ -d "$SHARED_DIR" ]; then
    SHARE_ARGS="-fsdev local,id=fsdev0,path=$SHARED_DIR,security_model=mapped-xattr -device virtio-9p-pci,fsdev=fsdev0,mount_tag=games"
fi

echo "=== JackGPU VM ==="
echo "GPU: $GPU_MODE"
echo "RAM: $RAM, CPUs: $CPUS"
echo "RDP: localhost:3389"
echo "SSH: localhost:2222"
if [ -n "$SHARE_ARGS" ]; then
    echo "Shared: $SHARED_DIR (mount_tag=games)"
fi
echo ""

exec "$QEMU" \
    -M virt,highmem=on \
    -accel hvf \
    -cpu host \
    -smp "$CPUS" \
    -m "$RAM" \
    \
    -drive if=pflash,format=raw,file="$EFI_FW",readonly=on \
    -drive if=pflash,format=raw,file="$EFI_VARS" \
    \
    -drive file="$DISK_IMG",if=none,id=hd0,format=qcow2,cache=writethrough \
    -device nvme,drive=hd0,serial=jackgpu0,bootindex=0 \
    \
    $GPU_DEVICE \
    \
    $SHARE_ARGS \
    \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    -device usb-net,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389,hostfwd=tcp::2222-:22,hostfwd=tcp::9944-:9944 \
    \
    -drive file="$VM_DIR/virtio-drivers.img",if=none,id=drivers,format=raw,readonly=on \
    -device usb-storage,drive=drivers,removable=on \
    \
    -display cocoa \
    -serial mon:stdio
