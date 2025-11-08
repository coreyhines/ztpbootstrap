# VM Testing Guide for Apple Silicon Mac

This guide helps you set up a Linux VM on your Apple Silicon Mac to test the ZTP Bootstrap service deployment.

## Quick Start

**Recommended: Native CLI using Apple Hypervisor Framework**

```bash
# Install QEMU (uses Apple's native Hypervisor Framework)
brew install qemu

# Use the native VM creation script
./vm-create-native.sh -i ~/Downloads/fedora-server-arm64.iso
```

This uses Apple's native [Hypervisor Framework](https://developer.apple.com/documentation/hypervisor) via QEMU with HVF acceleration for best performance.

## Option 0: Native CLI (Recommended)

Use Apple's native Hypervisor Framework directly via QEMU CLI - no GUI apps needed.

### Installation

```bash
brew install qemu
```

### Quick Start

```bash
# Download latest Fedora and create VM (easiest!)
./vm-create-native.sh --download fedora

# Download specific Ubuntu version
./vm-create-native.sh --download ubuntu --version 22.04

# Or use existing ISO
./vm-create-native.sh -i ~/Downloads/fedora-server-arm64.iso

# Custom settings with auto-download
./vm-create-native.sh \
  -n ztpbootstrap-vm \
  -m 8192 \
  -c 4 \
  --download fedora
```

### Features

- ✅ **Native performance** - Uses Apple's Hypervisor Framework (HVF)
- ✅ **CLI-based** - No GUI apps required
- ✅ **SSH forwarding** - Access VM via `ssh user@localhost -p 2222`
- ✅ **Full control** - All QEMU options available

See [Native CLI Setup](#native-cli-setup) for detailed instructions.

## Option 1: UTM (GUI Alternative)

If you prefer a GUI, UTM is a free, GUI-based VM manager built on QEMU.

## Architecture Considerations

**⚠️ IMPORTANT for Apple Silicon (M1/M2/M3/M4):**

- **Use ARM64 Linux VMs** for native performance (fast)
- **Avoid x86_64 Linux VMs** - they will be very slow (emulated)
- Podman works perfectly on ARM64 Linux

## Native CLI Setup

Use Apple's native [Hypervisor Framework](https://developer.apple.com/documentation/hypervisor) via QEMU for native performance without GUI apps.

### Prerequisites

```bash
# Install QEMU
brew install qemu
```

### Download ARM64 Linux ISO

Download an ARM64 Linux distribution:

- **Fedora Server ARM64**: https://download.fedoraproject.org/pub/fedora/linux/releases/
- **Ubuntu Server ARM64**: https://cdimage.ubuntu.com/releases/
- **Debian ARM64**: https://www.debian.org/CD/http-ftp/#stable

### Create and Start VM

**Automatic ISO Download (Recommended):**

```bash
# Download latest Fedora and start VM
./vm-create-native.sh --download fedora

# Download specific version
./vm-create-native.sh --download ubuntu --version 22.04

# Download Debian
./vm-create-native.sh --download debian
```

**Using Existing ISO:**

```bash
# Basic usage with existing ISO
./vm-create-native.sh -i ~/Downloads/fedora-server-arm64.iso

# Custom configuration
./vm-create-native.sh \
  --name ztpbootstrap-vm \
  --memory 8192 \
  --cpus 4 \
  --disk ztpbootstrap.qcow2 \
  --size 30G \
  --iso ~/Downloads/fedora-server-arm64.iso
```

**Supported Distributions:**
- `fedora` - Latest Fedora Server ARM64 (auto-detects version)
- `ubuntu` - Ubuntu Server ARM64 (default: 22.04 LTS)
- `debian` - Debian ARM64 (default: 12 stable)

ISOs are downloaded to `~/Downloads` by default (configurable with `--iso-dir`).

### VM Configuration

The script uses:
- **Acceleration**: `accel=hvf` (Apple Hypervisor Framework)
- **CPU**: `host` (uses host CPU features)
- **Network**: NAT with SSH forwarding (localhost:2222 → VM:22)
- **Display**: Default (can be changed)

### Access the VM

**During installation:**
- Use the QEMU window that opens
- Mouse/keyboard: Click in window to capture, Ctrl+Alt+G to release

**After installation:**
```bash
# SSH into the VM
ssh user@localhost -p 2222

# Or use the test deployment script
curl -fsSL https://raw.githubusercontent.com/coreyhines/ztpbootstrap/main/test-vm-deployment.sh | sudo bash
```

### Manual QEMU Command

If you prefer to run QEMU directly:

```bash
# Create disk
qemu-img create -f qcow2 ztpbootstrap.qcow2 20G

# Start VM
qemu-system-aarch64 \
  -M virt,accel=hvf \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -drive file=ztpbootstrap.qcow2,if=virtio,format=qcow2 \
  -cdrom ~/Downloads/fedora-server-arm64.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-device,netdev=net0 \
  -display default \
  -usb \
  -device usb-tablet \
  -name ztpbootstrap-vm
```

**Key parameters:**
- `-M virt,accel=hvf` - Use virt machine with Apple Hypervisor Framework
- `-cpu host` - Use host CPU features (native performance)
- `-netdev user,hostfwd=tcp::2222-:22` - NAT with SSH port forwarding
- `-display default` - Use default display (can use `-nographic` for headless)

### Advanced: Bridged Networking

For macvlan testing, you may need bridged networking. This requires more setup:

```bash
# Create bridge (requires root)
sudo ifconfig bridge0 create
sudo ifconfig bridge0 addm en0
sudo ifconfig bridge0 up

# Use bridge in QEMU
-netdev bridge,id=net0,br=bridge0 \
-device virtio-net-device,netdev=net0
```

## Option 1: UTM (GUI Alternative)

UTM is a free, GUI-based VM manager built on QEMU, specifically designed for macOS and Apple Silicon.

### Installation

```bash
brew install --cask utm
```

Or download from: https://mac.getutm.app/

### Setup Steps

1. **Open UTM** and click the **+** button to create a new VM

2. **Choose "Virtualize"** (for ARM64) - this uses native virtualization for best performance

3. **Select "Linux"** as the operating system

4. **Configure VM:**
   - **Memory**: 4096 MB (4GB) minimum, 8192 MB (8GB) recommended
   - **Disk**: 20 GB minimum
   - **Network**: 
     - **Shared (NAT)** - easier setup, works for basic testing
     - **Bridged** - better for macvlan network testing

5. **Download ARM64 Linux ISO:**
   - **Fedora Server ARM64**: https://download.fedoraproject.org/pub/fedora/linux/releases/
   - **Ubuntu Server ARM64**: https://cdimage.ubuntu.com/releases/
   - **Debian ARM64**: https://www.debian.org/CD/http-ftp/#stable

6. **Select the ISO** and start the VM

7. **Install Linux** in the VM (standard installation)

8. **After installation**, SSH into the VM and run:

```bash
# Clone the repo
git clone https://github.com/coreyhines/ztpbootstrap.git
cd ztpbootstrap

# Run the automated test script
sudo ./test-vm-deployment.sh
```

Or use the one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/coreyhines/ztpbootstrap/main/test-vm-deployment.sh | sudo bash
```

## Option 2: QEMU (Command Line)

If you prefer command-line tools, QEMU works well on Apple Silicon.

### Installation

```bash
brew install qemu
```

### Create ARM64 VM

1. **Download ARM64 Linux ISO** (Fedora/Ubuntu/Debian)

2. **Create disk image:**

```bash
qemu-img create -f qcow2 ztpbootstrap-test.qcow2 20G
```

3. **Start VM:**

```bash
qemu-system-aarch64 \
  -M virt,accel=hvf \
  -cpu host \
  -smp 2 \
  -m 4096 \
  -drive file=ztpbootstrap-test.qcow2,if=virtio,format=qcow2 \
  -cdrom /path/to/fedora-server-arm64.iso \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -display default
```

**Parameters explained:**
- `-M virt,accel=hvf` - Use virt machine with Apple's Hypervisor Framework (fast!)
- `-cpu host` - Use host CPU features
- `-smp 2` - 2 CPU cores
- `-m 4096` - 4GB RAM
- `-netdev user` - NAT networking (use `-netdev bridge` for bridged)

4. **Install Linux** in the VM

5. **After installation**, run the test script as shown above

## Option 3: Other Hypervisors

### VMware Fusion

VMware Fusion supports Apple Silicon and can run ARM64 VMs. However, it's a paid product.

### Parallels Desktop

Parallels Desktop also supports Apple Silicon and ARM64 VMs. It's a paid product with good performance.

## Fresh Setup Testing

The service has been tested with a complete fresh VM setup:

1. ✅ VM created with `vm-create-native.sh`
2. ✅ Cloud-init completes successfully
3. ✅ Repository cloned automatically
4. ✅ Macvlan network created automatically
5. ✅ Interactive setup or manual configuration
6. ✅ Service deployment with `setup.sh`
7. ✅ All containers start successfully
8. ✅ All endpoints accessible
9. ✅ WebUI fully functional

**Critical Bugs Found and Fixed:**
- Missing logs directory creation - ✅ Fixed
- Logs directory permissions - ✅ Fixed

All fixes have been verified in fresh VM deployments. See [TEST_RESULTS.md](../TEST_RESULTS.md) for details.

---

## Test Script

The `test-vm-deployment.sh` script automates the entire test process:

1. ✅ Installs Podman, git, curl, yq
2. ✅ Clones the repository
3. ✅ Sets up test environment
4. ✅ Runs setup in HTTP-only mode (no SSL certs needed)
5. ✅ Verifies service is running
6. ✅ Tests endpoints

## Troubleshooting

### VM is slow

- **Are you using ARM64 Linux?** x86_64 VMs are emulated and very slow on Apple Silicon
- **Increase VM memory** to 4GB+ (8GB recommended)
- **Use UTM with "Virtualize" mode** instead of "Emulate"

### Network issues

- **For macvlan testing**: Use bridged networking
- **For basic testing**: NAT networking is fine
- **Check VM network settings** in your hypervisor

### Podman issues

- **Ensure you're using a recent Linux distribution** (Fedora 37+, Ubuntu 22.04+)
- **Check Podman version**: `podman --version` (should be 4.0+)
- **Verify systemd is running**: `systemctl status`

## Next Steps

After the test script completes successfully:

1. **Verify service is running:**
   ```bash
   sudo systemctl status ztpbootstrap-pod
   ```

2. **Test endpoints:**
   ```bash
   curl http://localhost/health
   curl http://localhost/bootstrap.py
   ```

3. **View logs:**
   ```bash
   sudo journalctl -u ztpbootstrap-pod -f
   ```

4. **Stop the service:**
   ```bash
   sudo systemctl stop ztpbootstrap-pod
   ```

## Resources

- **UTM**: https://mac.getutm.app/
- **Fedora ARM64**: https://download.fedoraproject.org/pub/fedora/linux/releases/
- **Ubuntu ARM64**: https://cdimage.ubuntu.com/releases/
- **QEMU Documentation**: https://www.qemu.org/docs/
