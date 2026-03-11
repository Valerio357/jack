#!/bin/bash
# JackGPU VM Image Builder
#
# Creates a modified Windows ARM64 ISO with:
#   - Virtio drivers pre-injected into boot.wim (WinPE sees all hardware)
#   - autounattend.xml for fully automated install (no OOBE, local account)
#   - startup.nsh for automatic UEFI shell boot
#
# Then installs Windows unattended into a QCOW2 disk image.
#
# Prerequisites:
#   brew install qemu wimlib xorriso
#
# Usage:
#   ./build-image.sh /path/to/windows-arm64.iso
#
# Output: windows-arm64.qcow2 (ready for ./run.sh)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$SCRIPT_DIR"
QEMU="/opt/homebrew/bin/qemu-system-aarch64"
EFI_FW="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"

# VM configuration
RAM="8G"
CPUS="4"
DISK_SIZE="64G"
DISK_IMG="$VM_DIR/windows-arm64.qcow2"
EFI_VARS="$VM_DIR/efi-vars.fd"
VIRTIO_ISO="$VM_DIR/virtio-win.iso"
MODIFIED_ISO="$VM_DIR/windows-arm64-jackgpu.iso"

# Local account
ADMIN_USER="jack"
ADMIN_PASS="jack"
COMPUTER_NAME="JACKGPU"

# ─── Args ──────────────────────────────────────────────────────────────────────

WIN_ISO="${1:-}"
if [ -z "$WIN_ISO" ] || [ ! -f "$WIN_ISO" ]; then
    echo "Usage: $0 /path/to/windows-arm64.iso"
    echo ""
    echo "Download from: https://www.microsoft.com/software-download/windows11arm64"
    echo "Or use CrystalFetch to generate one."
    exit 1
fi

echo "=== JackGPU VM Image Builder ==="
echo ""
echo "Windows ISO:  $WIN_ISO"
echo "Virtio ISO:   $VIRTIO_ISO"
echo "Output:       $DISK_IMG"
echo "Account:      $ADMIN_USER / $ADMIN_PASS"
echo ""

# ─── Check prerequisites ──────────────────────────────────────────────────────

MISSING=0
for tool in "$QEMU" "$EFI_FW" "$VIRTIO_ISO"; do
    [ ! -f "$tool" ] && echo "ERROR: Missing $tool" && MISSING=1
done
for cmd in wimlib-imagex xorriso; do
    which "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found. Run: brew install $cmd"; MISSING=1; }
done
[ $MISSING -eq 1 ] && exit 1

# ─── Step 1: Extract Windows ISO ──────────────────────────────────────────────

echo "[1/5] Extracting Windows ISO..."

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

ISOMOUNT=$(hdiutil attach "$WIN_ISO" 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')
echo "  Mounted at: $ISOMOUNT"

rsync -a "$ISOMOUNT/" "$WORK_DIR/" 2>/dev/null
chmod -R u+w "$WORK_DIR/"

# bootaa64.efi may be on a separate El Torito partition — copy explicitly
if [ ! -f "$WORK_DIR/efi/boot/bootaa64.efi" ]; then
    mkdir -p "$WORK_DIR/efi/boot"
    cp "$ISOMOUNT/efi/boot/bootaa64.efi" "$WORK_DIR/efi/boot/" 2>/dev/null || true
fi

hdiutil detach "$(mount | grep "$ISOMOUNT" | awk '{print $1}' | head -1)" 2>/dev/null || true

# Verify critical files
for f in sources/install.wim sources/boot.wim efi/boot/bootaa64.efi; do
    [ ! -f "$WORK_DIR/$f" ] && echo "ERROR: Missing $f in ISO" && exit 1
done

echo "  install.wim: $(du -h "$WORK_DIR/sources/install.wim" | awk '{print $1}')"
echo "  boot.wim:    $(du -h "$WORK_DIR/sources/boot.wim" | awk '{print $1}')"

# ─── Step 2: Extract virtio drivers ───────────────────────────────────────────

echo "[2/5] Extracting virtio ARM64 drivers..."

DRIVER_DIR=$(mktemp -d)
VDISK=$(hdiutil attach "$VIRTIO_ISO" 2>/dev/null | grep '/dev/disk' | head -1 | awk '{print $1}')
VMOUNT=$(mount | grep "$VDISK" | awk -F'on ' '{print $2}' | awk -F' \\(' '{print $1}')
if [ -z "$VMOUNT" ]; then
    VMOUNT=$(mktemp -d)
    mount -t cd9660 "$VDISK" "$VMOUNT" 2>/dev/null
fi

for drv in NetKVM viostor vioscsi Balloon viogpudo viorng viofs; do
    if [ -d "$VMOUNT/$drv/w11/ARM64" ]; then
        cp -R "$VMOUNT/$drv/w11/ARM64" "$DRIVER_DIR/$drv"
        echo "  $drv"
    fi
done

umount "$VMOUNT" 2>/dev/null || true
hdiutil detach "$VDISK" 2>/dev/null || true

# ─── Step 3: Inject drivers into boot.wim ─────────────────────────────────────

echo "[3/5] Injecting virtio drivers into boot.wim..."

# Inject into WinPE (Image 1) and Windows Setup (Image 2)
for idx in 1 2; do
    echo "  Image $idx..."
    wimlib-imagex update "$WORK_DIR/sources/boot.wim" "$idx" \
        --command "add $DRIVER_DIR /Windows/INF/virtio" 2>&1 | grep -E "^(Archiving|Using)" | tail -1
done

# ─── Step 4: Add autounattend.xml + rebuild ISO ───────────────────────────────

echo "[4/5] Adding autounattend.xml and rebuilding ISO..."

# Create autounattend.xml
cat > "$WORK_DIR/autounattend.xml" << XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions>
          <CreatePartition wcm:action="add"><Order>1</Order><Size>260</Size><Type>EFI</Type></CreatePartition>
          <CreatePartition wcm:action="add"><Order>2</Order><Size>16</Size><Type>MSR</Type></CreatePartition>
          <CreatePartition wcm:action="add"><Order>3</Order><Extend>true</Extend><Type>Primary</Type></CreatePartition>
        </CreatePartitions>
        <ModifyPartitions>
          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>EFI</Label></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
        </ModifyPartitions>
      </Disk></DiskConfiguration>
      <ImageInstall><OSImage><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><ProductKey><WillShowUI>Never</WillShowUI></ProductKey></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$COMPUTER_NAME</ComputerName>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Home</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add">
        <Name>$ADMIN_USER</Name><Group>Administrators</Group>
        <Password><Value>$ADMIN_PASS</Value><PlainText>true</PlainText></Password>
      </LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>$ADMIN_USER</Username>
        <Password><Value>$ADMIN_PASS</Value><PlainText>true</PlainText></Password>
        <LogonCount>3</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order>
          <CommandLine>powershell -NoProfile -Command "Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0; Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order>
          <CommandLine>shutdown /s /t 60 /c "JackGPU setup complete"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XMLEOF

# startup.nsh for automatic UEFI shell boot
printf 'FS0:\\efi\\boot\\bootaa64.efi\r\n' > "$WORK_DIR/startup.nsh"

# Build ISO with iso-level 3 for >4GB file support
rm -f "$MODIFIED_ISO"
echo "  Building ISO (this takes a few minutes for ~5GB)..."
xorriso -as mkisofs \
    -o "$MODIFIED_ISO" \
    -iso-level 3 \
    -J -joliet-long -r \
    -V "WIN11_JACKGPU" \
    -e efi/boot/bootaa64.efi \
    -no-emul-boot \
    -append_partition 2 0xef "$WORK_DIR/efi/boot/bootaa64.efi" \
    "$WORK_DIR/" 2>&1 | tail -1

if [ ! -f "$MODIFIED_ISO" ]; then
    echo "  ERROR: Failed to build ISO"
    exit 1
fi

SIZE=$(du -h "$MODIFIED_ISO" | awk '{print $1}')
echo "  Modified ISO: $MODIFIED_ISO ($SIZE)"

# ─── Step 5: Install Windows unattended ────────────────────────────────────────

echo "[5/5] Installing Windows (unattended, ~20 minutes)..."
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  A QEMU window will appear.                          ║"
echo "  ║  At UEFI Shell, type: FS0:\\efi\\boot\\bootaa64.efi    ║"
echo "  ║  Then press a key when asked to boot from CD.        ║"
echo "  ║  After that, installation is fully automatic.        ║"
echo "  ║  The VM shuts down when complete.                    ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""

rm -f "$DISK_IMG" "$EFI_VARS"
/opt/homebrew/bin/qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null 2>&1
dd if=/dev/zero of="$EFI_VARS" bs=1m count=64 2>/dev/null

"$QEMU" \
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
    -device virtio-scsi-pci,id=scsi0 \
    -drive file="$MODIFIED_ISO",if=none,id=cdrom0,media=cdrom,readonly=on \
    -device scsi-cd,drive=cdrom0,bus=scsi0.0,bootindex=0 \
    \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    \
    -device qemu-xhci \
    -device usb-kbd \
    -device usb-tablet \
    \
    -device ramfb \
    \
    -display cocoa \
    -serial mon:stdio

# Compact image
echo ""
echo "Compacting image..."
/opt/homebrew/bin/qemu-img convert -O qcow2 "$DISK_IMG" "${DISK_IMG}.tmp" 2>/dev/null
mv "${DISK_IMG}.tmp" "$DISK_IMG"

FINAL_SIZE=$(du -h "$DISK_IMG" | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  BUILD COMPLETE                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Image:    $DISK_IMG ($FINAL_SIZE)"
echo "║  Account:  $ADMIN_USER / $ADMIN_PASS"
echo "║  Computer: $COMPUTER_NAME"
echo "║                                                      ║"
echo "║  Launch:   ./run.sh                                  ║"
echo "╚══════════════════════════════════════════════════════╝"
