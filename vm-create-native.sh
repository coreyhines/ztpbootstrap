#!/bin/bash
# Native VM Creation Script using Apple Hypervisor Framework
# Uses QEMU with HVF (Hypervisor Framework) acceleration for native performance

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="${VM_NAME:-ztpbootstrap-test-vm}"
VM_DISK="${VM_DISK:-ztpbootstrap-test.qcow2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-2}"
ISO_PATH="${ISO_PATH:-}"
DOWNLOAD_DISTRO="${DOWNLOAD_DISTRO:-}"
DOWNLOAD_VERSION="${DOWNLOAD_VERSION:-}"
DOWNLOAD_TYPE="${DOWNLOAD_TYPE:-iso}"  # iso or cloud
DOWNLOAD_ARCH="${DOWNLOAD_ARCH:-}"  # aarch64 or x86_64 (auto-detected if not set)
ISO_DIR="${ISO_DIR:-$HOME/Downloads}"
HEADLESS="${HEADLESS:-false}"
CONSOLE="${CONSOLE:-false}"
AUTO_SETUP="${AUTO_SETUP:-false}"  # Auto-run interactive setup after boot

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_download() {
    echo -e "${BLUE}[DOWNLOAD]${NC} $1"
}

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    log_error "This script is for macOS only"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
    log_warn "This script is optimized for Apple Silicon (ARM64)"
    log_warn "Intel Macs can use this but may have different performance characteristics"
fi

# Check for QEMU
if ! command -v qemu-system-aarch64 &> /dev/null; then
    log_error "QEMU is not installed"
    echo ""
    log_info "Install QEMU:"
    echo "  brew install qemu"
    echo ""
    exit 1
fi

QEMU_VERSION=$(qemu-system-aarch64 --version | head -1)
log_info "Found: $QEMU_VERSION"

# Check for Hypervisor Framework support
if [[ -d "/System/Library/Frameworks/Hypervisor.framework" ]]; then
    log_info "✓ Apple Hypervisor Framework available"
else
    log_warn "Hypervisor Framework not found (unusual on macOS)"
fi

# Function to create disk image
create_disk() {
    if [[ -f "$VM_DISK" ]]; then
        log_warn "Disk image $VM_DISK already exists"
        read -p "Delete and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$VM_DISK"
            log_info "Deleted existing disk image"
        else
            log_info "Using existing disk image"
            return 0
        fi
    fi
    
    log_info "Creating disk image: $VM_DISK (${VM_DISK_SIZE})"
    if qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"; then
        log_info "✓ Disk image created"
    else
        log_error "Failed to create disk image"
        exit 1
    fi
}

# Function to start VM
start_vm() {
    local iso_arg=""
    local drive_arg=""
    
    if [[ -n "$ISO_PATH" ]] && [[ -f "$ISO_PATH" ]]; then
        # Check if it's a disk image (cloud image) or ISO
        # First check if there's an extracted .raw file for .raw.xz files
        if [[ "$ISO_PATH" == *.raw.xz ]] && [[ -f "${ISO_PATH%.xz}" ]]; then
            ISO_PATH="${ISO_PATH%.xz}"
            log_info "Using extracted cloud image (raw): $ISO_PATH"
        fi
        
        if [[ "$ISO_PATH" == *.raw ]]; then
            # Raw cloud image - create a qcow2 copy so cloud-init can run fresh each time
            local qcow2_copy="${VM_DISK%.qcow2}-cloud.qcow2"
            if [[ ! -f "$qcow2_copy" ]] || [[ "$ISO_PATH" -nt "$qcow2_copy" ]]; then
                log_info "Creating qcow2 copy of cloud image for fresh cloud-init runs..."
                if qemu-img convert -f raw -O qcow2 "$ISO_PATH" "$qcow2_copy"; then
                    log_info "✓ Created qcow2 copy: $qcow2_copy"
                else
                    log_warn "Failed to create qcow2 copy, using raw image directly"
                    log_warn "Note: Cloud-init will only run on first boot with raw images"
                    qcow2_copy="$ISO_PATH"
                fi
            else
                log_info "Using existing qcow2 copy: $qcow2_copy"
            fi
            drive_arg="-drive file=$qcow2_copy,if=virtio,format=qcow2"
        elif [[ "$ISO_PATH" == *.qcow2 ]]; then
            # QCOW2 cloud image - use as primary disk
            log_info "Using cloud image (qcow2): $ISO_PATH"
            drive_arg="-drive file=$ISO_PATH,if=virtio,format=qcow2"
        elif [[ "$ISO_PATH" == *.img ]]; then
            # Check if it's a cloud image (cloudimg in filename) or generic disk image
            if [[ "$ISO_PATH" == *cloudimg* ]] || [[ "$ISO_PATH" == *cloud* ]]; then
                # Cloud image - detect actual format and create a qcow2 copy so cloud-init can run fresh each time
                # Ubuntu cloud images are often already qcow2 even with .img extension
                local actual_format=$(qemu-img info "$ISO_PATH" 2>/dev/null | grep "file format:" | awk '{print $3}' || echo "raw")
                local qcow2_copy="${VM_DISK%.qcow2}-cloud.qcow2"
                
                if [[ "$actual_format" == "qcow2" ]]; then
                    # Already qcow2 - create a standalone copy for fresh cloud-init runs
                    # Using standalone copy instead of snapshot to avoid boot issues
                    log_info "Cloud image is already qcow2 format, creating standalone copy for fresh cloud-init runs..."
                    if [[ ! -f "$qcow2_copy" ]] || [[ "$ISO_PATH" -nt "$qcow2_copy" ]]; then
                        if qemu-img convert -f qcow2 -O qcow2 "$ISO_PATH" "$qcow2_copy"; then
                            log_info "✓ Created qcow2 copy: $qcow2_copy"
                        else
                            log_warn "Failed to create qcow2 copy, using original image"
                            log_warn "Note: Cloud-init will only run on first boot with original image"
                            qcow2_copy="$ISO_PATH"
                        fi
                    else
                        log_info "Using existing qcow2 copy: $qcow2_copy"
                    fi
                else
                    # Raw format - convert to qcow2
                    log_info "Cloud image is raw format, converting to qcow2 for fresh cloud-init runs..."
                    if [[ ! -f "$qcow2_copy" ]] || [[ "$ISO_PATH" -nt "$qcow2_copy" ]]; then
                        if qemu-img convert -f raw -O qcow2 "$ISO_PATH" "$qcow2_copy"; then
                            log_info "✓ Created qcow2 copy: $qcow2_copy"
                        else
                            log_warn "Failed to create qcow2 copy, using raw image directly"
                            log_warn "Note: Cloud-init will only run on first boot with raw images"
                            qcow2_copy="$ISO_PATH"
                        fi
                    else
                        log_info "Using existing qcow2 copy: $qcow2_copy"
                    fi
                fi
                drive_arg="-drive file=$qcow2_copy,if=virtio,format=qcow2"
            else
                # Generic disk image - detect format
                local actual_format=$(qemu-img info "$ISO_PATH" 2>/dev/null | grep "file format:" | awk '{print $3}' || echo "raw")
                log_info "Using disk image: $ISO_PATH (format: $actual_format)"
                drive_arg="-drive file=$ISO_PATH,if=virtio,format=$actual_format"
            fi
        else
            # ISO - boot from CD
            iso_arg="-cdrom $ISO_PATH"
            log_info "Using ISO: $ISO_PATH"
        fi
    elif [[ -n "$ISO_PATH" ]]; then
        log_error "ISO file not found: $ISO_PATH"
        exit 1
    else
        if [[ "$CONSOLE" == "true" ]] || [[ "$HEADLESS" == "true" ]]; then
            log_error "ISO is required for console/headless mode"
            log_info "Use --download DISTRO or -i ISO_PATH to provide an ISO."
            exit 1
        fi
        log_warn "No ISO specified - VM will boot from disk (if OS installed)"
        log_warn "If the disk is empty, the VM will not boot!"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted. Use --download DISTRO or -i ISO_PATH to provide an ISO."
            exit 0
        fi
    fi
    
    log_info "Starting VM with native Hypervisor Framework acceleration..."
    log_info "VM Name: $VM_NAME"
    log_info "Memory: ${VM_MEMORY}MB"
    log_info "CPUs: $VM_CPUS"
    log_info "Disk: $VM_DISK"
    echo ""
    
    # Determine display/console options
    local display_opts=""
    local console_opts=""
    local monitor_opts=""
    
    if [[ "$HEADLESS" == "true" ]]; then
        display_opts="-display none"
        console_opts="-nographic"
        monitor_opts=""
        log_info "Running in headless mode (no display, no console)"
    elif [[ "$CONSOLE" == "true" ]]; then
        display_opts="-display none"
        # Use separate chardevs for serial and monitor to avoid conflicts
        # Serial console on stdio, monitor on a separate channel
        console_opts="-chardev stdio,id=serial0 -serial chardev:serial0"
        monitor_opts="-monitor none"
        log_info "Running in headless mode with serial console"
        log_info "Console output will appear in this terminal"
        log_info "Note: Boot output may take 10-30 seconds to appear"
    else
        # Determine best display type for macOS
        local display_type="cocoa"
        if ! qemu-system-aarch64 -display help 2>&1 | grep -q "^cocoa"; then
            display_type="default"
            log_warn "Cocoa display not available, using default"
        else
            log_info "Using Cocoa display (macOS native)"
        fi
        display_opts="-display $display_type"
        console_opts="-serial mon:stdio"
        monitor_opts=""
        log_info "Press Ctrl+Alt+G to release mouse/keyboard"
        log_info "Press Ctrl+Alt+Q to quit QEMU"
    fi
    
    # Create log file
    local log_file="/tmp/qemu-${VM_NAME}.log"
    log_info "QEMU output will be logged to: $log_file"
    echo ""
    
    log_info "Starting QEMU..."
    echo ""
    
    # Add kernel parameters for console output if using console mode
    local kernel_params=""
    if [[ "$CONSOLE" == "true" ]] && [[ -n "$iso_arg" ]]; then
        # For Fedora/Ubuntu/Debian, add console parameters to kernel
        kernel_params="console=ttyAMA0,115200 earlyprintk=serial,ttyAMA0,115200"
        log_info "Adding kernel parameters for serial console: $kernel_params"
    fi
    
    # If no drive_arg was set, use default disk
    if [[ -z "$drive_arg" ]]; then
        drive_arg="-drive file=$VM_DISK,if=virtio,format=qcow2"
    fi
    
    # Detect architecture from ISO_PATH or use detected arch
    local detected_arch=""
    if [[ "$ISO_PATH" == *".aarch64."* ]] || [[ "$ISO_PATH" == *".arm64."* ]]; then
        detected_arch="aarch64"
    elif [[ "$ISO_PATH" == *".x86_64."* ]] || [[ "$ISO_PATH" == *".amd64."* ]]; then
        detected_arch="x86_64"
    elif [[ -n "$DOWNLOAD_ARCH" ]]; then
        detected_arch="$DOWNLOAD_ARCH"
    elif [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
        detected_arch="aarch64"
    else
        detected_arch="x86_64"
    fi
    
    # Find UEFI firmware (required for booting disk images)
    local uefi_firmware=""
    if [[ "$ISO_PATH" == *.raw ]] || [[ "$ISO_PATH" == *.qcow2 ]] || [[ "$ISO_PATH" == *cloudimg* ]] || [[ "$ISO_PATH" == *cloud*.img ]] || [[ -z "$ISO_PATH" ]]; then
        # Cloud images and disk-only boots need UEFI firmware
        if [[ "$detected_arch" == "aarch64" ]]; then
            local firmware_paths=(
                "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
                "/usr/local/share/qemu/edk2-aarch64-code.fd"
                "/usr/share/qemu/edk2-aarch64-code.fd"
            )
            
            # Also try finding via Homebrew Cellar
            if command -v brew &> /dev/null; then
                local brew_prefix=$(brew --prefix 2>/dev/null)
                if [[ -n "$brew_prefix" ]]; then
                    local cellar_fw=$(find "$brew_prefix/Cellar/qemu" -name "edk2-aarch64-code.fd" 2>/dev/null | head -1)
                    if [[ -n "$cellar_fw" ]] && [[ -f "$cellar_fw" ]]; then
                        firmware_paths=("$cellar_fw" "${firmware_paths[@]}")
                    fi
                fi
            fi
        else
            # x86_64 firmware
            local firmware_paths=(
                "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
                "/usr/local/share/qemu/edk2-x86_64-code.fd"
                "/usr/share/qemu/edk2-x86_64-code.fd"
            )
            
            if command -v brew &> /dev/null; then
                local brew_prefix=$(brew --prefix 2>/dev/null)
                if [[ -n "$brew_prefix" ]]; then
                    local cellar_fw=$(find "$brew_prefix/Cellar/qemu" -name "edk2-x86_64-code.fd" 2>/dev/null | head -1)
                    if [[ -n "$cellar_fw" ]] && [[ -f "$cellar_fw" ]]; then
                        firmware_paths=("$cellar_fw" "${firmware_paths[@]}")
                    fi
                fi
            fi
        fi
        
        for fw_path in "${firmware_paths[@]}"; do
            if [[ -f "$fw_path" ]]; then
                uefi_firmware="$fw_path"
                log_info "Found UEFI firmware for ${detected_arch}: $uefi_firmware"
                break
            fi
        done
        
        if [[ -z "$uefi_firmware" ]]; then
            log_error "UEFI firmware not found for ${detected_arch}! Cloud images require UEFI firmware to boot."
            log_info "Install QEMU firmware: brew install qemu"
            log_info "Or download manually: https://www.kraxel.org/repos/jenkins/edk2/"
            log_info "Expected locations:"
            for fw_path in "${firmware_paths[@]}"; do
                log_info "  - $fw_path"
            done
            exit 1
        fi
    fi
    
    # Create cloud-init ISO if using cloud image
    local cloud_init_iso=""
    if [[ "$ISO_PATH" == *.raw ]] || [[ "$ISO_PATH" == *.qcow2 ]] || [[ "$ISO_PATH" == *cloudimg* ]] || [[ "$ISO_PATH" == *cloud*.img ]]; then
        local cloud_init_dir="/tmp/cloud-init-${VM_NAME}"
        mkdir -p "$cloud_init_dir"
        
        # Detect distribution from ISO path or download distro
        local distro_user="fedora"
        local distro_pkg_mgr="dnf"
        local distro_ssh_service="sshd"
        local distro_sudo_group="wheel"
        local distro_install_cmd="dnf install -y"
        
        if [[ "$ISO_PATH" == *ubuntu* ]] || [[ "$ISO_PATH" == *Ubuntu* ]] || [[ "$DOWNLOAD_DISTRO" == "ubuntu" ]] || [[ "$DOWNLOAD_DISTRO" == "Ubuntu" ]]; then
            distro_user="ubuntu"
            distro_pkg_mgr="apt"
            distro_ssh_service="ssh"
            distro_sudo_group="sudo"
            distro_install_cmd="apt-get update && apt-get install -y"
        elif [[ "$ISO_PATH" == *debian* ]] || [[ "$ISO_PATH" == *Debian* ]] || [[ "$DOWNLOAD_DISTRO" == "debian" ]] || [[ "$DOWNLOAD_DISTRO" == "Debian" ]]; then
            distro_user="debian"
            distro_pkg_mgr="apt"
            distro_ssh_service="ssh"
            distro_sudo_group="sudo"
            distro_install_cmd="apt-get update && apt-get install -y"
        fi
        
        # Create user-data for cloud-init (enable SSH, set password, clone repo, setup macvlan)
        # Use quoted heredoc delimiter to prevent variable expansion during parsing
        # Variables will be replaced with sed after heredoc creation
        cat > "$cloud_init_dir/user-data" << 'CLOUDINITEOF'
#cloud-config
# Disable default user (if any) and create our own
system_info:
  default_user:
    name: __DISTRO_USER__
    lock_passwd: false
    plain_text_passwd: '__DISTRO_USER__'
    groups: [__DISTRO_SUDO_GROUP__, adm, systemd-journal]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

users:
  - default
  - name: __DISTRO_USER__
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [__DISTRO_SUDO_GROUP__, adm, systemd-journal]
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: '__DISTRO_USER__'
    # SSH authorized keys will be added via write_files + runcmd for better compatibility
chpasswd:
  list: |
    __DISTRO_USER__:__DISTRO_USER__
  expire: false
ssh_pwauth: true
disable_root: false
password_authentication: true
write_files:
  - path: /etc/ssh/sshd_config.d/99-cloud-init.conf
    content: |
      PasswordAuthentication yes
      PubkeyAuthentication yes
      ChallengeResponseAuthentication yes
      UsePAM yes
    permissions: '0644'
    owner: root:root
  - path: /tmp/auto-setup-flag
    content: |
      Auto-setup enabled
    permissions: '0644'
    owner: root:root
  - path: /tmp/host_ssh_key.pub
    content: |
      __SSH_KEY_CONTENT__
    permissions: '0644'
    owner: root:root
  - path: /home/__DISTRO_USER__/README_VM_SETUP.txt
    content: |
      ZTP Bootstrap VM Setup Complete!

      The repository has been cloned to: /home/__DISTRO_USER__/ztpbootstrap

      Next steps:
      1. cd /home/__DISTRO_USER__/ztpbootstrap
      2. Run interactive setup: ./setup-interactive.sh
         OR
         Run manual setup: ./setup.sh

      The macvlan network 'ztpbootstrap-net' has been created (if ethernet interface was found).

      SSH access:
        User: __DISTRO_USER__
        Password: __DISTRO_USER__
        From host: ssh __DISTRO_USER__@localhost -p 2222
      
      Service access (if running on port 80/443):
        HTTP:  http://localhost:8080
        HTTPS: https://localhost:8443
    permissions: '0644'
    owner: __DISTRO_USER__:__DISTRO_USER__
runcmd:
  - |
    # Configure SSH to allow password authentication - do this FIRST
    mkdir -p /etc/ssh/sshd_config.d
    # Also update main config file
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
    # Ensure user exists and has password set
    if ! id __DISTRO_USER__ &>/dev/null; then
      useradd -m -G __DISTRO_SUDO_GROUP__ -s /bin/bash __DISTRO_USER__
    fi
    echo '__DISTRO_USER__:__DISTRO_USER__' | chpasswd
    usermod -aG __DISTRO_SUDO_GROUP__ __DISTRO_USER__
  - systemctl enable __DISTRO_SSH_SERVICE__
  - systemctl restart __DISTRO_SSH_SERVICE__
  - |
    # Wait a moment for SSH to restart, then verify
    sleep 2
    systemctl status __DISTRO_SSH_SERVICE__ || true
  - |
    # Install required packages
    __DISTRO_INSTALL_CMD__ git podman curl yq
  - |
    # Set up SSH authorized_keys from host if available
    # Cloud-init write_files section copies the key to /tmp/host_ssh_key.pub
    if [ -f /tmp/host_ssh_key.pub ]; then
      mkdir -p /home/__DISTRO_USER__/.ssh
      cat /tmp/host_ssh_key.pub >> /home/__DISTRO_USER__/.ssh/authorized_keys
      chmod 700 /home/__DISTRO_USER__/.ssh
      chmod 600 /home/__DISTRO_USER__/.ssh/authorized_keys
      chown -R __DISTRO_USER__:__DISTRO_USER__ /home/__DISTRO_USER__/.ssh
      echo "SSH key from host added to authorized_keys"
    else
      echo "No SSH key found at /tmp/host_ssh_key.pub - password authentication will be required"
    fi
  - |
    # Clone the repository
    if [ ! -d /home/__DISTRO_USER__/ztpbootstrap ]; then
      sudo -u __DISTRO_USER__ git clone https://github.com/coreyhines/ztpbootstrap.git /home/__DISTRO_USER__/ztpbootstrap || \
      sudo -u __DISTRO_USER__ git clone https://github.com/YOUR_USERNAME/ztpbootstrap.git /home/__DISTRO_USER__/ztpbootstrap || \
      echo "Repository clone failed. Please clone manually."
    fi
  - |
    # Create minimal ztpbootstrap.env file for automated testing
    # This allows setup.sh to run without manual configuration
    mkdir -p /opt/containerdata/ztpbootstrap
    cat > /opt/containerdata/ztpbootstrap/ztpbootstrap.env << 'ENVFILEEOF'
# Minimal configuration for automated testing
CV_ADDR=www.arista.io
ENROLLMENT_TOKEN=test_token_for_automated_testing
CV_PROXY=
EOS_URL=
NTP_SERVER=time.nist.gov
TZ=UTC
NGINX_HOST=ztpboot.example.com
NGINX_PORT=443
ENVFILEEOF
    chmod 644 /opt/containerdata/ztpbootstrap/ztpbootstrap.env
    # Also copy bootstrap.py and nginx.conf to expected location for setup.sh
    if [ -f /home/__DISTRO_USER__/ztpbootstrap/bootstrap.py ]; then
      cp /home/__DISTRO_USER__/ztpbootstrap/bootstrap.py /opt/containerdata/ztpbootstrap/bootstrap.py
      chmod 644 /opt/containerdata/ztpbootstrap/bootstrap.py
    fi
    if [ -f /home/__DISTRO_USER__/ztpbootstrap/nginx.conf ]; then
      cp /home/__DISTRO_USER__/ztpbootstrap/nginx.conf /opt/containerdata/ztpbootstrap/nginx.conf
      chmod 644 /opt/containerdata/ztpbootstrap/nginx.conf
    fi
    echo "Created minimal ztpbootstrap.env for automated testing"
  - |
    # Setup macvlan network on the primary ethernet interface
    # Find the primary ethernet interface (usually eth0 or ens*)
    ETH_IFACE=$(ip -o link show | grep -E '^[0-9]+: (eth|ens|enp)' | head -1 | cut -d: -f2 | tr -d ' ')
    if [ -n "$ETH_IFACE" ]; then
      echo "Found ethernet interface: $ETH_IFACE"
      # Get network info from the interface
      SUBNET=$(ip -4 addr show $ETH_IFACE | grep -oP 'inet \K[\d.]+/[\d]+' | head -1 || echo "192.168.1.0/24")
      GATEWAY=$(ip route | grep default | grep $ETH_IFACE | awk '{print $3}' | head -1 || echo "192.168.1.1")
      echo "Detected subnet: $SUBNET, gateway: $GATEWAY"
      # Check if macvlan network already exists
      if ! podman network exists ztpbootstrap-net 2>/dev/null; then
        echo "Creating macvlan network ztpbootstrap-net on interface $ETH_IFACE"
        podman network create -d macvlan \
          --subnet=$SUBNET \
          --gateway=$GATEWAY \
          -o parent=$ETH_IFACE \
          ztpbootstrap-net || \
        echo "Failed to create macvlan network. You may need to configure it manually."
      else
        echo "Macvlan network ztpbootstrap-net already exists"
      fi
    else
      echo "No ethernet interface found. Macvlan setup skipped."
      echo "Note: In a VM, the interface might be different. Check with: ip link show"
    fi
  - |
    # Set ownership of cloned repo
    chown -R __DISTRO_USER__:__DISTRO_USER__ /home/__DISTRO_USER__/ztpbootstrap 2>/dev/null || true
  - |
    # Ensure README file has correct ownership (created by write_files)
    chown __DISTRO_USER__:__DISTRO_USER__ /home/__DISTRO_USER__/README_VM_SETUP.txt 2>/dev/null || true
  - echo "Cloud-init completed. Repository cloned and macvlan network configured."
  - cat /home/__DISTRO_USER__/README_VM_SETUP.txt
  - |
    # Optionally run interactive setup automatically
    # Check if auto-setup flag file exists (created by cloud-init write_files)
    AUTO_SETUP_VAL=$(if [ -f /tmp/auto-setup-flag ]; then echo "true"; else echo "false"; fi)
    if [ -f /home/__DISTRO_USER__/ztpbootstrap/setup-interactive.sh ] && [ "$AUTO_SETUP_VAL" = "true" ]; then
      echo ""
      echo "Auto-running interactive setup..."
      cd /home/__DISTRO_USER__/ztpbootstrap
      sudo -u __DISTRO_USER__ bash -c "cd /home/__DISTRO_USER__/ztpbootstrap && ./setup-interactive.sh" || \
      echo "Interactive setup failed or was cancelled. Run manually: ./setup-interactive.sh"
    else
      echo "Auto-setup disabled. Run manually: cd /home/__DISTRO_USER__/ztpbootstrap && ./setup-interactive.sh"
    fi
CLOUDINITEOF
        
        # Get host SSH public key if available (will be embedded in user-data via write_files)
        # This allows passwordless SSH access from the host machine
        local host_ssh_key=""
        local ssh_key_content=""
        if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
            host_ssh_key="$HOME/.ssh/id_ed25519.pub"
        elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
            host_ssh_key="$HOME/.ssh/id_rsa.pub"
        fi
        
        if [[ -n "$host_ssh_key" ]] && [[ -f "$host_ssh_key" ]]; then
            ssh_key_content=$(cat "$host_ssh_key" 2>/dev/null || echo "")
            log_info "Including host SSH key in cloud-init: $host_ssh_key"
        else
            log_info "No SSH public key found in ~/.ssh/ - password authentication will be required"
            # Remove the SSH key write_files entry if no key available
            sed -i.bak '/path: \/tmp\/host_ssh_key.pub/,/owner: root:root/d' "$cloud_init_dir/user-data" 2>/dev/null || true
            rm -f "$cloud_init_dir/user-data.bak" 2>/dev/null || true
        fi
        
        # Replace all placeholders with actual values (after heredoc creation to avoid expansion issues)
        sed -i.bak \
          -e "s|__DISTRO_USER__|${distro_user}|g" \
          -e "s|__DISTRO_SUDO_GROUP__|${distro_sudo_group}|g" \
          -e "s|__DISTRO_SSH_SERVICE__|${distro_ssh_service}|g" \
          -e "s|__DISTRO_INSTALL_CMD__|${distro_install_cmd}|g" \
          -e "s|__SSH_KEY_CONTENT__|${ssh_key_content}|g" \
          "$cloud_init_dir/user-data" 2>/dev/null || true
        rm -f "$cloud_init_dir/user-data.bak" 2>/dev/null || true
        
        # Create meta-data
        echo "instance-id: ${VM_NAME}-$(date +%s)" > "$cloud_init_dir/meta-data"
        echo "local-hostname: ${VM_NAME}" >> "$cloud_init_dir/meta-data"
        
        # Remove auto-setup flag file creation if auto-setup is disabled
        if [[ "$AUTO_SETUP" != "true" ]]; then
            # Remove only the auto-setup-flag write_files entry, not the entire write_files section
            sed -i.bak '/path: \/tmp\/auto-setup-flag/,/owner: root:root/d' "$cloud_init_dir/user-data" 2>/dev/null || true
            rm -f "$cloud_init_dir/user-data.bak" 2>/dev/null || true
        fi
        
        # Create cloud-init ISO
        cloud_init_iso="/tmp/cloud-init-${VM_NAME}.iso"
        # Include SSH key file if it exists
        local iso_files=("$cloud_init_dir/user-data" "$cloud_init_dir/meta-data")
        if [[ -f "$cloud_init_dir/host_ssh_key.pub" ]]; then
            iso_files+=("$cloud_init_dir/host_ssh_key.pub")
        fi
        
        if command -v mkisofs &> /dev/null; then
            mkisofs -output "$cloud_init_iso" -volid cidata -joliet -rock "${iso_files[@]}" 2>/dev/null
        elif command -v genisoimage &> /dev/null; then
            genisoimage -output "$cloud_init_iso" -volid cidata -joliet -rock "${iso_files[@]}" 2>/dev/null
        elif command -v hdiutil &> /dev/null; then
            # macOS fallback - create ISO using hdiutil
            log_warn "mkisofs/genisoimage not found, trying hdiutil..."
            hdiutil makehybrid -iso -joliet -o "$cloud_init_iso" "$cloud_init_dir" 2>/dev/null || {
                log_warn "Could not create cloud-init ISO. SSH may not work without cloud-init."
                cloud_init_iso=""
            }
        else
            log_warn "No ISO creation tool found (mkisofs/genisoimage/hdiutil). SSH may not work without cloud-init."
            cloud_init_iso=""
        fi
        
        if [[ -n "$cloud_init_iso" ]] && [[ -f "$cloud_init_iso" ]]; then
            log_info "Created cloud-init ISO: $cloud_init_iso"
            log_info "Default user: ${distro_user} / Password: ${distro_user}"
            # Verify the ISO has the correct volume ID
            if command -v file &> /dev/null; then
                local iso_info=$(file "$cloud_init_iso" 2>/dev/null || echo "")
                log_info "Cloud-init ISO info: $iso_info"
            fi
        else
            log_error "Failed to create cloud-init ISO! SSH password authentication will not work."
            log_info "Install cdrtools for cloud-init ISO support: brew install cdrtools"
        fi
    fi
    
    # QEMU command with HVF (Hypervisor Framework) acceleration
    # Run in foreground so user can see output
    local cloud_init_drive=""
    if [[ -n "$cloud_init_iso" ]] && [[ -f "$cloud_init_iso" ]]; then
        # Mount cloud-init ISO as CD-ROM so cloud-init can detect it
        # Cloud-init looks for volume ID "cidata" or "CIDATA" on CD-ROM devices
        cloud_init_drive="-cdrom $cloud_init_iso"
        log_info "Cloud-init ISO mounted as CD-ROM for detection"
    fi
    
    # Determine QEMU binary and machine type based on architecture
    local qemu_bin=""
    local machine_type=""
    if [[ "$detected_arch" == "aarch64" ]]; then
        qemu_bin="qemu-system-aarch64"
        machine_type="virt,accel=hvf"
    else
        qemu_bin="qemu-system-x86_64"
        # For x86_64 on Apple Silicon, use TCG (software emulation) - no HVF
        if [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
            machine_type="q35"
            log_warn "Using software emulation for x86_64 on ARM64 - performance will be SLOW"
        else
            machine_type="q35,accel=hvf"
        fi
    fi
    
    # Build QEMU command
    local qemu_cmd="$qemu_bin \
        -M $machine_type \
        -cpu host \
        -smp $VM_CPUS \
        -m $VM_MEMORY"
    
    # Add UEFI firmware if needed (for disk images)
    if [[ -n "$uefi_firmware" ]]; then
        qemu_cmd="$qemu_cmd -drive if=pflash,format=raw,file=$uefi_firmware,readonly=on"
    fi
    
    # Add drives
    qemu_cmd="$qemu_cmd \
        $drive_arg \
        $iso_arg \
        $cloud_init_drive \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443 \
        -device virtio-net-device,netdev=net0 \
        -device qemu-xhci,id=xhci \
        -device usb-tablet,bus=xhci.0 \
        $display_opts \
        $console_opts \
        $monitor_opts \
        -name $VM_NAME"
    
    # Add kernel parameters if specified (requires appending to kernel command line)
    # Note: This is complex for ISOs, so we'll rely on the OS detecting serial console
    # Most modern Linux distros auto-detect serial console on ARM64
    
    # Execute QEMU - output goes to both console and log file
    if [[ "$CONSOLE" == "true" ]]; then
        # In console mode, run directly so output appears in terminal
        log_info "VM starting... Console output will appear below:"
        echo ""
        exec $qemu_cmd
    else
        # In other modes, log to file
        exec $qemu_cmd 2>&1 | tee "$log_file"
    fi
}

# Function to download ISO
download_iso() {
    local distro="$1"
    local version="${2:-latest}"
    local iso_file=""
    local download_url=""
    local iso_path=""
    
    # Create ISO directory if it doesn't exist
    mkdir -p "$ISO_DIR"
    
    case "$distro" in
        fedora|Fedora)
            if [[ "$version" == "latest" ]]; then
                log_info "Fetching latest Fedora release..."
                # Get latest Fedora version from releases.json
                local fedora_json=$(curl -s -L https://fedoraproject.org/releases.json 2>/dev/null)
                if [[ -n "$fedora_json" ]]; then
                    version=$(echo "$fedora_json" | grep -o '"version":"[0-9]*"' | head -1 | cut -d'"' -f4)
                    if [[ -z "$version" ]]; then
                        log_warn "Could not parse version from JSON, using fallback"
                        version="41"  # Current stable as fallback
                    fi
                else
                    log_warn "Could not fetch version info, using fallback"
                    version="41"  # Current stable as fallback
                fi
                log_info "Latest Fedora version: $version"
            fi
            
            # Detect architecture if not specified
            local arch="${DOWNLOAD_ARCH}"
            if [[ -z "$arch" ]]; then
                # Auto-detect: prefer native ARM64 on Apple Silicon, but allow x86_64
                if [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
                    arch="aarch64"
                    log_info "Detected ARM64 architecture (native performance)"
                else
                    arch="x86_64"
                    log_info "Detected x86_64 architecture"
                fi
            fi
            
            # Warn if using x86_64 on ARM64 (will be slow)
            if [[ "$arch" == "x86_64" ]] && [[ "$(uname -m)" == "arm64" ]]; then
                log_warn "Using x86_64 image on ARM64 system - performance will be SLOW (emulated)"
                log_warn "Consider using aarch64 for native performance"
            fi
            
            if [[ "$DOWNLOAD_TYPE" == "cloud" ]]; then
                # Fedora Cloud image (raw format, boots directly)
                # Try to find available image by checking common patterns
                log_info "Finding available Fedora Cloud image for ${arch}..."
                
                # Try different version patterns (1.6, 1.5, 1.2, 1.1, etc.)
                local found_url=""
                local found_file=""
                local version_patterns=("1.6" "1.5" "1.2" "1.1" "1.0")
                
                for vp in "${version_patterns[@]}"; do
                    # Try generic QEMU/KVM qcow2 image first (best for local virtualization)
                    local test_file="Fedora-Cloud-Base-${version}-${vp}.${arch}.qcow2"
                    local test_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/${test_file}"
                    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -L --head "$test_url" 2>/dev/null)
                    
                    if [[ "$http_code" == "200" ]]; then
                        found_url="$test_url"
                        found_file="$test_file"
                        log_info "Found generic QEMU qcow2 image: $test_file (best for local VMs)"
                        break
                    fi
                    
                    # Try generic QEMU compressed
                    test_file="Fedora-Cloud-Base-${version}-${vp}.${arch}.qcow2.xz"
                    test_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/${test_file}"
                    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L --head "$test_url" 2>/dev/null)
                    
                    if [[ "$http_code" == "200" ]]; then
                        found_url="$test_url"
                        found_file="$test_file"
                        log_info "Found generic QEMU qcow2 compressed image: $test_file"
                        break
                    fi
                    
                    # Try AmazonEC2 raw.xz as fallback (EC2-specific, may have issues with cloud-init)
                    test_file="Fedora-Cloud-Base-AmazonEC2-${version}-${vp}.${arch}.raw.xz"
                    test_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/${test_file}"
                    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L --head "$test_url" 2>/dev/null)
                    
                    if [[ "$http_code" == "200" ]]; then
                        found_url="$test_url"
                        found_file="$test_file"
                        log_warn "Found AmazonEC2 raw image: $test_file"
                        log_warn "Note: EC2 images are AWS-specific and may not work well with standard cloud-init"
                        break
                    fi
                    
                    # Try GCE tar.gz as last resort
                    test_file="Fedora-Cloud-Base-GCE-${version}-${vp}.${arch}.tar.gz"
                    test_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/${arch}/images/${test_file}"
                    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L --head "$test_url" 2>/dev/null)
                    
                    if [[ "$http_code" == "200" ]]; then
                        found_url="$test_url"
                        found_file="$test_file"
                        log_warn "Found GCE tar.gz image: $test_file (GCE-specific)"
                        break
                    fi
                done
                
                if [[ -z "$found_url" ]]; then
                    log_error "Could not find Fedora Cloud image for version ${version} architecture ${arch}"
                    log_info "Tried patterns:"
                    log_info "  - Fedora-Cloud-Base-${version}-{1.6,1.5,1.2,1.1,1.0}.${arch}.qcow2[.xz]"
                    log_info "  - Fedora-Cloud-Base-AmazonEC2-${version}-{1.6,1.5,1.2,1.1,1.0}.${arch}.raw.xz"
                    log_info "  - Fedora-Cloud-Base-GCE-${version}-{1.6,1.5,1.2,1.1,1.0}.${arch}.tar.gz"
                    log_info "You may need to specify a different version/architecture or download manually"
                    return 1
                fi
                
                iso_file="$found_file"
                download_url="$found_url"
                iso_path="${ISO_DIR}/${iso_file}"
                log_info "Downloading Fedora Cloud image (boots directly, SSH enabled)"
            else
                # Fedora Server ISO (requires installation)
                iso_file="Fedora-Server-netinst-aarch64-${version}.iso"
                download_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Server/aarch64/iso/${iso_file}"
                iso_path="${ISO_DIR}/${iso_file}"
                
                # Verify URL exists before downloading
                log_info "Checking if ISO URL is valid..."
                if ! curl -s --head "$download_url" | grep -q "200 OK"; then
                    log_warn "Primary URL not found, trying alternative..."
                    # Try alternative URL pattern
                    download_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Server/aarch64/iso/Fedora-Server-${version}-aarch64-netinst.iso"
                    iso_file="Fedora-Server-${version}-aarch64-netinst.iso"
                    iso_path="${ISO_DIR}/${iso_file}"
                fi
            fi
            ;;
            
        ubuntu|Ubuntu)
            if [[ "$version" == "latest" ]]; then
                version="22.04"
                log_info "Using Ubuntu LTS: $version"
            fi
            
            if [[ "$DOWNLOAD_TYPE" == "cloud" ]]; then
                # Ubuntu Cloud image (pre-built, boots directly)
                iso_file="ubuntu-${version}-server-cloudimg-arm64.img"
                download_url="https://cloud-images.ubuntu.com/releases/${version}/release/${iso_file}"
                iso_path="${ISO_DIR}/${iso_file}"
                log_info "Downloading Ubuntu Cloud image (boots directly, SSH enabled)"
            else
                # Ubuntu Server ISO (requires installation)
                iso_file="ubuntu-${version}-server-arm64.iso"
                download_url="https://cdimage.ubuntu.com/releases/${version}/release/${iso_file}"
                iso_path="${ISO_DIR}/${iso_file}"
            fi
            ;;
            
        debian|Debian)
            if [[ "$version" == "latest" ]]; then
                version="12"
                log_info "Using Debian stable: $version"
            fi
            
            iso_file="debian-${version}.0.0-arm64-netinst.iso"
            # Try multiple mirrors
            local mirrors=(
                "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/${iso_file}"
                "https://mirror.rackspace.com/debian-cd/current/arm64/iso-cd/${iso_file}"
            )
            download_url="${mirrors[0]}"
            iso_path="${ISO_DIR}/${iso_file}"
            ;;
            
        *)
            log_error "Unsupported distribution: $distro"
            log_info "Supported: fedora, ubuntu, debian"
            return 1
            ;;
    esac
    
    # Check if ISO already exists
    if [[ -f "$iso_path" ]]; then
        log_info "ISO already exists: $iso_path"
        read -p "Use existing ISO? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            ISO_PATH="$iso_path"
            return 0
        fi
        log_info "Will re-download..."
    fi
    
    log_download "Downloading $distro $version..."
    log_download "URL: $download_url"
    log_download "Destination: $iso_path"
    echo ""
    
    # Download with progress (follow redirects with -L)
    if command -v curl &> /dev/null; then
        # First verify URL is valid
        log_info "Verifying download URL..."
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -L --head "$download_url" 2>/dev/null)
        if [[ "$http_code" != "200" ]]; then
            log_error "URL returned HTTP $http_code (file may not exist)"
            log_info "URL: $download_url"
            return 1
        fi
        
        if curl -L --progress-bar -o "$iso_path" "$download_url"; then
            # Verify it's not an HTML error page
            if head -1 "$iso_path" 2>/dev/null | grep -q "<!DOCTYPE\|<html"; then
                log_error "Download returned HTML error page instead of image file"
                log_info "This usually means the file doesn't exist at that URL"
                rm -f "$iso_path"
                return 1
            fi
            
            # Check file size (should be > 1MB for images)
            local file_size=$(stat -f%z "$iso_path" 2>/dev/null || stat -c%s "$iso_path" 2>/dev/null || echo "0")
            if [[ "$file_size" -lt 1048576 ]]; then
                log_error "Downloaded file is too small ($file_size bytes) - likely an error page"
                rm -f "$iso_path"
                return 1
            fi
            
            log_info "✓ Download complete: $iso_path ($(numfmt --to=iec-i --suffix=B $file_size 2>/dev/null || echo "${file_size} bytes"))"
            
            # If it's a compressed cloud image, extract it
            if [[ "$iso_path" == *.xz ]]; then
                log_info "Extracting compressed image..."
                local extracted_path="${iso_path%.xz}"
                
                # Check if already extracted
                if [[ -f "$extracted_path" ]]; then
                    log_info "Extracted image already exists: $extracted_path"
                    ISO_PATH="$extracted_path"
                    return 0
                fi
                
                if command -v xz &> /dev/null; then
                    if xz -d "$iso_path" 2>&1; then
                        log_info "✓ Extracted to: $extracted_path"
                        ISO_PATH="$extracted_path"
                    else
                        log_error "Failed to extract image"
                        log_info "File type: $(file "$iso_path" 2>/dev/null || echo 'unknown')"
                        return 1
                    fi
                else
                    log_error "xz not found. Install with: brew install xz"
                    return 1
                fi
            else
                ISO_PATH="$iso_path"
            fi
            return 0
        else
            log_error "Download failed"
            # Try alternative mirrors for Debian
            if [[ "$distro" == "debian" ]] && [[ -n "${mirrors[1]}" ]]; then
                log_info "Trying alternative mirror..."
                download_url="${mirrors[1]}"
                if curl -L --progress-bar -o "$iso_path" "$download_url"; then
                    log_info "✓ Download complete from mirror: $iso_path"
                    ISO_PATH="$iso_path"
                    return 0
                fi
            fi
            return 1
        fi
    elif command -v wget &> /dev/null; then
        if wget --progress=bar:force -O "$iso_path" "$download_url" 2>&1; then
            log_info "✓ Download complete: $iso_path"
            
            # If it's a compressed cloud image, extract it
            if [[ "$iso_path" == *.xz ]]; then
                log_info "Extracting compressed image..."
                local extracted_path="${iso_path%.xz}"
                if command -v xz &> /dev/null; then
                    if xz -d "$iso_path"; then
                        log_info "✓ Extracted to: $extracted_path"
                        ISO_PATH="$extracted_path"
                    else
                        log_error "Failed to extract image"
                        return 1
                    fi
                else
                    log_error "xz not found. Install with: brew install xz"
                    return 1
                fi
            else
                ISO_PATH="$iso_path"
            fi
            return 0
        else
            log_error "Download failed"
            return 1
        fi
    else
        log_error "Neither curl nor wget found. Cannot download ISO."
        return 1
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Create and run a native ARM64 Linux VM using Apple's Hypervisor Framework.

Options:
    -n, --name NAME          VM name (default: $VM_NAME)
    -d, --disk FILE          Disk image file (default: $VM_DISK)
    -s, --size SIZE          Disk size (default: $VM_DISK_SIZE)
    -m, --memory MB          Memory in MB (default: $VM_MEMORY)
    -c, --cpus NUM           Number of CPUs (default: $VM_CPUS)
    -i, --iso PATH           Path to ARM64 Linux ISO
    -D, --download DISTRO    Download image (fedora, ubuntu, debian)
    -T, --type TYPE          Image type: iso (installer) or cloud (pre-built) (default: iso)
    -V, --version VERSION    Distribution version (default: latest)
    -a, --arch ARCH          Architecture: aarch64 or x86_64 (auto-detected if not set)
    -I, --iso-dir DIR        Directory for images (default: ~/Downloads)
    -C, --console            Run headless with serial console (no GUI)
    -H, --headless           Run headless (no display, no console)
    -A, --auto-setup         Auto-run interactive setup after boot (cloud images only)
    -h, --help               Show this help

Examples:
    # Download and create VM with latest Fedora Cloud (recommended - boots fast, SSH ready)
    $0 --download fedora --type cloud

    # Download Fedora Cloud and run with console
    $0 --download fedora --type cloud --console

    # Download Fedora Cloud and auto-run setup
    $0 --download fedora --type cloud --auto-setup

    # Download Fedora installer ISO (requires installation)
    $0 --download fedora --type iso

    # Download specific Ubuntu version
    $0 --download ubuntu --version 22.04

    # Use existing image
    $0 -i ~/Downloads/Fedora-Cloud-Base-41-1.2.aarch64.raw

    # Create VM with custom settings
    $0 -n my-vm -m 8192 -c 4 --download fedora --type cloud

    # Start existing VM (no ISO)
    $0 -n my-vm

Notes:
    - Uses Apple's native Hypervisor Framework (HVF) for best performance
    - Requires ARM64 Linux images for native performance
    - Port forwarding:
        * SSH: localhost:2222 -> VM:22
        * HTTP: localhost:8080 -> VM:80
        * HTTPS: localhost:8443 -> VM:443
    - Network: NAT (user mode networking)
    - Cloud images boot directly with SSH enabled (no installation needed)
    - ISO images require installation before use

Image Types:
    - cloud: Pre-built disk images, boot directly, SSH enabled (recommended)
    - iso: Installer images, require installation process

Download ARM64 Images:
    - Fedora Cloud: https://download.fedoraproject.org/pub/fedora/linux/releases/
    - Fedora Server ISO: https://download.fedoraproject.org/pub/fedora/linux/releases/
    - Ubuntu: https://cdimage.ubuntu.com/releases/
    - Debian: https://www.debian.org/CD/http-ftp/#stable

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -d|--disk)
            VM_DISK="$2"
            shift 2
            ;;
        -s|--size)
            VM_DISK_SIZE="$2"
            shift 2
            ;;
        -m|--memory)
            VM_MEMORY="$2"
            shift 2
            ;;
        -c|--cpus)
            VM_CPUS="$2"
            shift 2
            ;;
        -i|--iso)
            ISO_PATH="$2"
            shift 2
            ;;
        -D|--download)
            DOWNLOAD_DISTRO="$2"
            shift 2
            ;;
        -T|--type)
            DOWNLOAD_TYPE="$2"
            shift 2
            ;;
        -V|--version)
            DOWNLOAD_VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            DOWNLOAD_ARCH="$2"
            shift 2
            ;;
        -I|--iso-dir)
            ISO_DIR="$2"
            shift 2
            ;;
        -C|--console)
            CONSOLE="true"
            shift
            ;;
        -H|--headless)
            HEADLESS="true"
            shift
            ;;
        -A|--auto-setup)
            AUTO_SETUP="true"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
echo "=========================================="
echo "Native VM Creation (Apple Hypervisor)"
echo "=========================================="
echo ""

# Download ISO if requested
if [[ -n "$DOWNLOAD_DISTRO" ]]; then
    if download_iso "$DOWNLOAD_DISTRO" "$DOWNLOAD_VERSION"; then
        log_info "ISO ready: $ISO_PATH"
    else
        log_error "Failed to download ISO"
        exit 1
    fi
fi

# Validate ISO if provided
if [[ -n "$ISO_PATH" ]] && [[ ! -f "$ISO_PATH" ]]; then
    log_error "ISO file not found: $ISO_PATH"
    exit 1
fi

# Create disk if needed
if [[ ! -f "$VM_DISK" ]] || [[ -n "$ISO_PATH" ]]; then
    create_disk
fi

# Start VM
start_vm
