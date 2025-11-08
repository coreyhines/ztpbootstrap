#!/bin/bash
# Test VM Setup Script for Apple Silicon Mac
# This script helps set up a test VM for validating the ZTP Bootstrap service deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${VM_NAME:-ztpbootstrap-test-vm}"
VM_OS="${VM_OS:-fedora}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_DISK="${VM_DISK:-20G}"

# Detect architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    IS_APPLE_SILICON=true
    echo "✓ Detected Apple Silicon (ARM64)"
else
    IS_APPLE_SILICON=false
    echo "✓ Detected Intel Mac (x86_64)"
fi

echo "=========================================="
echo "ZTP Bootstrap Test VM Setup"
echo "=========================================="
echo ""
echo "This script will help you create a test VM to validate the deployment."
echo ""

# Check for common hypervisors
HYPERVISOR=""
if command -v vmrun &> /dev/null; then
    HYPERVISOR="vmware"
    echo "✓ Detected VMware Fusion"
elif command -v prlctl &> /dev/null; then
    HYPERVISOR="parallels"
    echo "✓ Detected Parallels Desktop"
elif command -v VBoxManage &> /dev/null; then
    HYPERVISOR="virtualbox"
    echo "✓ Detected VirtualBox"
elif command -v qemu-system-aarch64 &> /dev/null || command -v qemu-system-x86_64 &> /dev/null; then
    HYPERVISOR="qemu"
    echo "✓ Detected QEMU"
elif [[ -d "/Applications/UTM.app" ]] || command -v utm &> /dev/null; then
    HYPERVISOR="utm"
    echo "✓ Detected UTM (recommended for Apple Silicon)"
fi

if [[ -z "$HYPERVISOR" ]]; then
    echo "⚠ No hypervisor detected."
    echo ""
    if [[ "$IS_APPLE_SILICON" == "true" ]]; then
        echo "For Apple Silicon Macs, we recommend UTM (free, GUI-based):"
        echo "  1. Install UTM: brew install --cask utm"
        echo "     Or download from: https://mac.getutm.app/"
        echo ""
        echo "Alternative: Install QEMU via Homebrew:"
        echo "  brew install qemu"
        echo ""
    else
        echo "Install a hypervisor:"
        echo "  - UTM: brew install --cask utm"
        echo "  - QEMU: brew install qemu"
        echo "  - VMware Fusion, Parallels, or VirtualBox"
        echo ""
    fi
fi

echo ""
echo "=========================================="
echo "VM Setup Instructions"
echo "=========================================="
echo ""
echo "VM Configuration:"
echo "  - Name: $VM_NAME"
echo "  - OS: $VM_OS (Linux)"
echo "  - Memory: ${VM_MEMORY}MB (4GB recommended)"
echo "  - Disk: $VM_DISK"
echo ""

if [[ "$IS_APPLE_SILICON" == "true" ]]; then
    echo "⚠ IMPORTANT: Use ARM64 Linux for native performance!"
    echo ""
    echo "Recommended ARM64 Linux distributions:"
    echo "  - Fedora Server ARM64: https://download.fedoraproject.org/pub/fedora/linux/releases/"
    echo "  - Ubuntu Server ARM64: https://cdimage.ubuntu.com/releases/"
    echo "  - Debian ARM64: https://www.debian.org/CD/http-ftp/#stable"
    echo ""
    echo "⚠ Do NOT use x86_64 ISOs - they will be very slow (emulated)"
    echo ""
fi

echo ""
echo "=========================================="
echo "VM Creation Instructions"
echo "=========================================="
echo ""

if [[ "$HYPERVISOR" == "utm" ]]; then
    echo "UTM Setup (Recommended for Apple Silicon):"
    echo ""
    echo "1. Open UTM application"
    echo "2. Click '+' to create a new VM"
    echo "3. Choose 'Virtualize' (for ARM64) or 'Emulate' (for x86_64)"
    echo "4. Select 'Linux' as the operating system"
    echo "5. Configure:"
    echo "   - Memory: ${VM_MEMORY}MB"
    echo "   - Disk: $VM_DISK"
    echo "   - Network: Shared (NAT) or Bridged"
    echo "6. Select your ARM64 Linux ISO"
    echo "7. Install Linux in the VM"
    echo ""
elif [[ "$HYPERVISOR" == "qemu" ]]; then
    echo "QEMU Setup:"
    echo ""
    if [[ "$IS_APPLE_SILICON" == "true" ]]; then
        echo "For ARM64 VM (native, fast):"
        echo ""
        echo "1. Download ARM64 Linux ISO (Fedora/Ubuntu/Debian)"
        echo "2. Create disk image:"
        echo "   qemu-img create -f qcow2 ${VM_NAME}.qcow2 $VM_DISK"
        echo ""
        echo "3. Start VM:"
        echo "   qemu-system-aarch64 \\"
        echo "     -M virt,accel=hvf \\"
        echo "     -cpu host \\"
        echo "     -smp 2 \\"
        echo "     -m ${VM_MEMORY} \\"
        echo "     -drive file=${VM_NAME}.qcow2,if=virtio,format=qcow2 \\"
        echo "     -cdrom /path/to/linux-arm64.iso \\"
        echo "     -netdev user,id=net0 \\"
        echo "     -device virtio-net-device,netdev=net0 \\"
        echo "     -display default"
        echo ""
    else
        echo "For x86_64 VM:"
        echo ""
        echo "1. Download x86_64 Linux ISO"
        echo "2. Create disk image:"
        echo "   qemu-img create -f qcow2 ${VM_NAME}.qcow2 $VM_DISK"
        echo ""
        echo "3. Start VM:"
        echo "   qemu-system-x86_64 \\"
        echo "     -machine type=q35,accel=hvf \\"
        echo "     -cpu host \\"
        echo "     -smp 2 \\"
        echo "     -m ${VM_MEMORY} \\"
        echo "     -drive file=${VM_NAME}.qcow2,if=virtio,format=qcow2 \\"
        echo "     -cdrom /path/to/linux.iso \\"
        echo "     -netdev user,id=net0 \\"
        echo "     -device virtio-net-device,netdev=net0 \\"
        echo "     -display default"
        echo ""
    fi
else
    echo "General VM Setup:"
    echo ""
    echo "1. Create a new VM with these settings:"
    echo "   - Name: $VM_NAME"
    if [[ "$IS_APPLE_SILICON" == "true" ]]; then
        echo "   - Architecture: ARM64 (aarch64) - IMPORTANT!"
    fi
    echo "   - OS Type: Linux ($VM_OS)"
    echo "   - Memory: ${VM_MEMORY}MB (4GB recommended)"
    echo "   - Disk: $VM_DISK"
    echo "   - Network: NAT or Bridged (bridged recommended for macvlan testing)"
    echo ""
    echo "2. Install Linux:"
    if [[ "$IS_APPLE_SILICON" == "true" ]]; then
        echo "   - Fedora Server ARM64 (recommended)"
        echo "   - Ubuntu Server ARM64"
        echo "   - Debian ARM64"
    else
        echo "   - Fedora 37+ (recommended)"
        echo "   - RHEL 9+ / Rocky Linux 9+ / AlmaLinux 9+"
        echo "   - Ubuntu 22.04+ / Debian 12+"
    fi
    echo ""
fi

echo "3. After installation, SSH into the VM and run:"
echo ""
echo "   # Clone the repo"
echo "   git clone https://github.com/coreyhines/ztpbootstrap.git"
echo "   cd ztpbootstrap"
echo ""
echo "   # Run the test deployment script"
echo "   sudo ./test-vm-deployment.sh"
echo ""
echo "Or use this one-liner:"
echo "   curl -fsSL https://raw.githubusercontent.com/coreyhines/ztpbootstrap/main/test-vm-deployment.sh | sudo bash"
echo ""
