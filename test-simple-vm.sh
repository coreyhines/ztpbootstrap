#!/bin/bash
# Simple Fedora 43 VM test - minimal setup to test SSH
# This helps A/B test if the issue is with our complex script or the VM itself

set -euo pipefail

VM_DISK="test-simple-vm.qcow2"
VM_NAME="test-simple-vm"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup
cleanup() {
    log "Cleaning up..."
    pkill -f "qemu-system-aarch64.*$VM_NAME" 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

# Check if VM is already running
if ps aux | grep -i "qemu-system-aarch64.*$VM_NAME" | grep -v grep > /dev/null; then
    warn "VM is already running. Stopping it first..."
    pkill -f "qemu-system-aarch64.*$VM_NAME" 2>/dev/null || true
    sleep 2
fi

# Remove old disk if exists
if [[ -f "$VM_DISK" ]]; then
    warn "Removing old disk: $VM_DISK"
    rm -f "$VM_DISK"
fi

log "Creating simple test VM..."
log "This will test if basic Fedora 43 cloud image SSH works"

# Download Fedora 43 cloud image if needed
FEDORA_IMG="Fedora-Cloud-Base-43-1.6.aarch64.qcow2"
if [[ ! -f "$FEDORA_IMG" ]]; then
    log "Downloading Fedora 43 cloud image..."
    # Use the same download logic as vm-create-native.sh
    FEDORA_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/${FEDORA_IMG}"
    curl -L -o "$FEDORA_IMG" "$FEDORA_URL" || {
        error "Failed to download Fedora image"
        exit 1
    }
fi

# Create a copy for this test
log "Creating VM disk from cloud image..."
qemu-img create -f qcow2 -F qcow2 -b "$FEDORA_IMG" "$VM_DISK" 20G || {
    error "Failed to create VM disk"
    exit 1
}

# Create minimal cloud-init
log "Creating minimal cloud-init config..."
CLOUD_INIT_DIR="/tmp/cloud-init-${VM_NAME}"
rm -rf "$CLOUD_INIT_DIR"
mkdir -p "$CLOUD_INIT_DIR"

# Minimal user-data - just enable SSH with password
cat > "$CLOUD_INIT_DIR/user-data" << 'EOF'
#cloud-config
users:
  - name: fedora
    lock_passwd: false
    password: '$6$rounds=4096$salt$hashed'  # fedora/fedora
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTesting
    sudo: ALL=(ALL) NOPASSWD:ALL

# Enable password authentication
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: fedora
      password: fedora
      type: text

# Ensure SSH is enabled
runcmd:
  - systemctl enable sshd
  - systemctl start sshd
  - echo "Cloud-init completed at $(date)" >> /tmp/cloud-init-done
EOF

# Get host SSH key if available
if [[ -f ~/.ssh/id_ed25519.pub ]]; then
    HOST_KEY=$(cat ~/.ssh/id_ed25519.pub)
    sed -i.bak "s|ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTesting|$HOST_KEY|" "$CLOUD_INIT_DIR/user-data"
    rm -f "$CLOUD_INIT_DIR/user-data.bak"
    log "Added host SSH key to cloud-init"
fi

echo "instance-id: ${VM_NAME}-$(date +%s)" > "$CLOUD_INIT_DIR/meta-data"
echo "local-hostname: ${VM_NAME}" >> "$CLOUD_INIT_DIR/meta-data"

# Create cloud-init ISO
CLOUD_INIT_ISO="/tmp/cloud-init-${VM_NAME}.iso"
if command -v hdiutil >/dev/null 2>&1; then
    hdiutil makehybrid -iso -joliet -o "$CLOUD_INIT_ISO" "$CLOUD_INIT_DIR" 2>/dev/null || {
        error "Failed to create cloud-init ISO with hdiutil"
        exit 1
    }
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$CLOUD_INIT_ISO" -volid cidata -joliet -rock "$CLOUD_INIT_DIR"/* 2>/dev/null || {
        error "Failed to create cloud-init ISO with genisoimage"
        exit 1
    }
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -output "$CLOUD_INIT_ISO" -volid cidata -joliet -rock "$CLOUD_INIT_DIR"/* 2>/dev/null || {
        error "Failed to create cloud-init ISO with mkisofs"
        exit 1
    }
else
    error "No ISO creation tool found (hdiutil/genisoimage/mkisofs)"
    exit 1
fi

log "Created cloud-init ISO: $CLOUD_INIT_ISO"

# Start VM
log "Starting VM..."
log "VM will be accessible at: ssh -p 2223 fedora@localhost (password: fedora)"
log "Press Ctrl+C to stop the VM"
echo ""

qemu-system-aarch64 \
    -M virt,accel=hvf \
    -cpu host \
    -smp 2 \
    -m 4096 \
    -drive if=pflash,format=raw,file=/opt/homebrew/Cellar/qemu/10.1.2/share/qemu/edk2-aarch64-code.fd,readonly=on \
    -drive file="$VM_DISK",if=virtio,format=qcow2 \
    -cdrom "$CLOUD_INIT_ISO" \
    -netdev user,id=net0,hostfwd=tcp::2223-:22 \
    -device virtio-net-device,netdev=net0 \
    -display none \
    -nographic \
    -name "$VM_NAME" \
    2>&1 | tee "/tmp/qemu-${VM_NAME}.log" &

VM_PID=$!
log "VM started (PID: $VM_PID)"
log "Logs: tail -f /tmp/qemu-${VM_NAME}.log"
echo ""

# Wait a bit for VM to start
sleep 5

# Test SSH
log "Waiting for SSH (testing on port 2223)..."
for i in {1..60}; do
    # Check port
    if timeout 1 bash -c "echo > /dev/tcp/localhost/2223" 2>/dev/null; then
        log "Port 2223 is open (attempt $i)"
        # Try SSH
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -p 2223 fedora@localhost "echo 'SSH works'" 2>&1 | grep -q "SSH works"; then
            log "✓ SSH is working!"
            break
        elif ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p 2223 fedora@localhost "echo 'SSH works'" 2>/dev/null; then
            log "✓ SSH is working (key auth)!"
            break
        else
            log "Port open but SSH not ready yet..."
        fi
    fi
    if [ $((i % 10)) -eq 0 ]; then
        log "Still waiting... ($i attempts, ~$((i*2))s)"
    fi
    sleep 2
done

log ""
log "VM is running. Test SSH with:"
log "  ssh -p 2223 fedora@localhost"
log "  Password: fedora"
log ""
log "Or check cloud-init status:"
log "  ssh -p 2223 fedora@localhost 'sudo cloud-init status'"
log ""
log "Press Ctrl+C to stop the VM"

# Wait for user interrupt
wait $VM_PID

