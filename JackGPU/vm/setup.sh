#!/bin/bash
# JackGPU VM Setup — Creates and configures Windows ARM64 VM for testing
#
# Prerequisites:
#   - QEMU ARM64 with HVF: /opt/homebrew/bin/qemu-system-aarch64
#   - Windows 11 ARM64 ISO (download from Microsoft)
#   - virtio-win drivers ISO (for virtio disk/network in Windows)
#
# Usage:
#   1. Download Windows 11 ARM64 ISO from:
#      https://www.microsoft.com/software-download/windows11arm64
#   2. Download virtio-win drivers ISO from:
#      https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
#   3. Place both ISOs in this directory
#   4. Run: ./setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$SCRIPT_DIR"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"

# VM configuration
RAM="8G"
CPUS="4"
DISK_SIZE="128G"
DISK_IMG="$VM_DIR/windows-arm64.qcow2"
EFI_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS="$VM_DIR/efi-vars.fd"

# ISO paths
WIN_ISO="/Users/valeriodomenici/Code/jack/downloads/Win11_25H2_EnglishInternational_Arm64.iso"
VIRTIO_ISO="$VM_DIR/virtio-win.iso"

echo "=== JackGPU VM Setup ==="
echo "QEMU: $QEMU"
echo "Disk: $DISK_IMG ($DISK_SIZE)"
echo "RAM:  $RAM"
echo "CPUs: $CPUS"

# Check prerequisites
if [ ! -f "$QEMU" ]; then
    echo "ERROR: QEMU not found at $QEMU"
    echo "Install: /opt/homebrew/bin/brew install qemu"
    exit 1
fi

if [ ! -f "$EFI_FW" ]; then
    echo "ERROR: UEFI firmware not found at $EFI_FW"
    exit 1
fi

if [ ! -f "$WIN_ISO" ]; then
    echo "ERROR: Windows ARM64 ISO not found at $WIN_ISO"
    echo "Download from: https://www.microsoft.com/software-download/windows11arm64"
    exit 1
fi

# Create disk image
if [ ! -f "$DISK_IMG" ]; then
    echo "Creating disk image: $DISK_IMG ($DISK_SIZE)"
    /opt/homebrew/bin/qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE"
fi

# Create EFI vars (persistent UEFI settings)
if [ ! -f "$EFI_VARS" ]; then
    echo "Creating EFI vars"
    dd if=/dev/zero of="$EFI_VARS" bs=1m count=64
fi

# Build QEMU command — use USB storage for ISOs (aarch64 virt has no IDE)
VIRTIO_USB_ARGS=""
if [ -f "$VIRTIO_ISO" ]; then
    VIRTIO_USB_ARGS="-drive file=$VIRTIO_ISO,if=none,id=virtio_iso,format=raw,readonly=on -device usb-storage,drive=virtio_iso"
    echo "virtio-win ISO: $VIRTIO_ISO (USB)"
fi

echo ""
echo "Starting Windows ARM64 installer..."
echo "Press Ctrl+A, X to exit QEMU"
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
    -device nvme,drive=hd0,serial=jackgpu0,bootindex=1 \
    \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    \
    -drive file="$WIN_ISO",if=none,id=win_iso,format=raw,readonly=on \
    -device usb-storage,drive=win_iso,bootindex=0 \
    $VIRTIO_USB_ARGS \
    \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::3389-:3389 \
    \
    -device ramfb \
    -device virtio-gpu-pci \
    \
    -display cocoa \
    -serial mon:stdio
