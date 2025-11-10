#!/bin/bash
# Test Interactive Setup with Production Backup
# This script tests the interactive setup by restoring a production backup
# and running the interactive setup script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="${1:-fedora}"
VERSION="${2:-43}"
SKIP_VM_CREATE="${SKIP_VM_CREATE:-false}"
BACKUP_HOST="${BACKUP_HOST:-fedora1.freeblizz.com}"
BACKUP_USER="${BACKUP_USER:-corey}"

# Check for --skip-vm flag
if [[ "${1:-}" == "--skip-vm" ]] || [[ "${2:-}" == "--skip-vm" ]] || [[ "${3:-}" == "--skip-vm" ]]; then
    SKIP_VM_CREATE=true
    # Remove --skip-vm from args
    if [[ "${1:-}" == "--skip-vm" ]]; then
        DISTRO="${2:-fedora}"
        VERSION="${3:-43}"
    elif [[ "${2:-}" == "--skip-vm" ]]; then
        DISTRO="${1:-fedora}"
        VERSION="${3:-43}"
    else
        DISTRO="${1:-fedora}"
        VERSION="${2:-43}"
    fi
fi

# Determine default user based on distribution
# Use current logged-in user for Fedora since it has SSH key authentication configured
CURRENT_USER="${USER:-$(whoami)}"
if [[ "$DISTRO" == "ubuntu" ]] || [[ "$DISTRO" == "debian" ]]; then
    DEFAULT_USER="ubuntu"
else
    DEFAULT_USER="$CURRENT_USER"
fi

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

log_step() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Cleanup function
cleanup() {
    echo ""
    log_warn "Cleaning up..."
    pkill -f qemu-system-aarch64 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT

echo "=========================================="
echo "Interactive Setup Test"
echo "=========================================="
echo "Distribution: $DISTRO $VERSION"
echo "Backup source: ${BACKUP_USER}@${BACKUP_HOST}"
echo "Date: $(date +'%Y-%m-%d %H:%M:%S')"
echo ""
echo "Usage:"
echo "  $0 [--skip-vm] [distro] [version]"
echo ""
echo "  --skip-vm    Skip VM creation, assume VM is already running"
echo "               Use this if you have a VM already set up"
echo ""

# Step 1: Get backup from fedora1
log_step "Step 1: Retrieving backup from ${BACKUP_HOST}"
BACKUP_FILE=$(ssh "${BACKUP_USER}@${BACKUP_HOST}" "ls -t ~corey/ztpbootstrap-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null || echo "")

if [[ -z "$BACKUP_FILE" ]]; then
    log_error "No backup found on ${BACKUP_HOST}"
    log_info "Please create a backup first:"
    echo "  ssh ${BACKUP_USER}@${BACKUP_HOST} 'sudo bash -c \"BACKUP_DIR=\"/tmp/ztpbootstrap-backup-\$(date +%Y%m%d_%H%M%S)\"; mkdir -p \"\$BACKUP_DIR\"; cp -r /opt/containerdata/ztpbootstrap \"\$BACKUP_DIR/containerdata_ztpbootstrap\" && cp -r /etc/containers/systemd/ztpbootstrap \"\$BACKUP_DIR/etc_containers_systemd_ztpbootstrap\" && cp -r /opt/containerdata/certs/wild \"\$BACKUP_DIR/certs_wild\" && cd /tmp && tar -czf ~corey/ztpbootstrap-backup-\$(date +%Y%m%d_%H%M%S).tar.gz -C \"\$BACKUP_DIR\" . && rm -rf \"\$BACKUP_DIR\" && echo \"Backup: ~corey/ztpbootstrap-backup-\$(date +%Y%m%d_%H%M%S).tar.gz\"'"
    exit 1
fi

log_info "Found backup: $BACKUP_FILE"
LOCAL_BACKUP="/tmp/$(basename "$BACKUP_FILE")"
log_info "Copying backup to local machine..."
scp "${BACKUP_USER}@${BACKUP_HOST}:${BACKUP_FILE}" "$LOCAL_BACKUP" 2>/dev/null || {
    log_error "Failed to copy backup"
    exit 1
}
log_info "✓ Backup copied to: $LOCAL_BACKUP"

# Step 2: Create or use existing VM
log_step "Step 2: Setting up test VM"

if [[ "$SKIP_VM_CREATE" == "true" ]]; then
    log_info "Skipping VM creation (--skip-vm flag set)"
    log_info "Assuming VM is already running and accessible"
    VM_RUNNING=true
else
    # Check if VM is already running
    if ps aux | grep -i "qemu-system-aarch64" | grep -v grep > /dev/null; then
        log_info "VM is already running. Using existing VM."
        VM_RUNNING=true
    elif [[ -f "ztpbootstrap-test-cloud.qcow2" ]] || [[ -f "ztpbootstrap-test.qcow2" ]]; then
        log_warn "VM disk exists but VM is not running."
        log_info "To use existing disk, start VM manually or delete it to create fresh"
        log_info "Creating new VM..."
        ./vm-create-native.sh --download "$DISTRO" --type cloud --arch aarch64 --version "$VERSION" --headless 2>&1 | tee /tmp/test-vm-create.log &
        VM_PID=$!
        log_info "VM creation started (PID: $VM_PID)"
        sleep 5
        VM_RUNNING=false
    else
        log_info "Creating new VM..."
        ./vm-create-native.sh --download "$DISTRO" --type cloud --arch aarch64 --version "$VERSION" --headless 2>&1 | tee /tmp/test-vm-create.log &
        VM_PID=$!
        log_info "VM creation started (PID: $VM_PID)"
        sleep 5
        VM_RUNNING=false
    fi

    # Wait for VM to be running (if we just started it)
    if [[ "$VM_RUNNING" != "true" ]]; then
        log_info "Waiting for VM process..."
        for i in {1..30}; do
            if ps aux | grep -i "qemu-system-aarch64" | grep -v grep > /dev/null; then
                log_info "✓ VM is running"
                VM_RUNNING=true
                break
            fi
            sleep 2
            if [ $i -eq 30 ]; then
                log_error "VM failed to start"
                exit 1
            fi
        done
    fi
fi

# Step 3: Wait for SSH and cloud-init (best practice approach)
log_step "Step 3: Waiting for SSH and cloud-init"
log_info "This may take 2-5 minutes for cloud-init to complete on first boot..."
log_info "Using best practice: wait for SSH, then verify cloud-init completion"

# Phase 1: Wait for SSH port to be open (fast check)
log_info "Phase 1: Waiting for SSH port 2222 to be open..."
PORT_OPEN=false
for i in {1..150}; do
    if timeout 1 bash -c "echo > /dev/tcp/localhost/2222" 2>/dev/null; then
        log_info "✓ Port 2222 is open (~$((i*2))s)"
        PORT_OPEN=true
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        log_info "  Still waiting for port... (~$((i*2))s elapsed)"
    fi
    sleep 2
done

if [ "$PORT_OPEN" != "true" ]; then
    log_error "SSH port did not open within 5 minutes"
    log_info "Check VM logs: tail -f /tmp/qemu-ztpbootstrap-test-vm.log"
    exit 1
fi

# Phase 2: Wait for SSH to accept connections
log_info ""
log_info "Phase 2: Waiting for SSH to accept connections..."
SSH_READY=false
for i in {1..150}; do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p 2222 "${DEFAULT_USER}@localhost" "echo 'SSH ready'" 2>/dev/null; then
        log_info "✓ SSH is accepting connections (~$((i*2))s)"
        SSH_READY=true
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        log_info "  Still waiting for SSH... (~$((i*2))s elapsed)"
    fi
    sleep 2
done

if [ "$SSH_READY" != "true" ]; then
    log_error "SSH did not become ready within 5 minutes"
    log_info "Check VM logs: tail -f /tmp/qemu-ztpbootstrap-test-vm.log"
    exit 1
fi

# Phase 3: Wait for cloud-init to complete (best practice)
log_info ""
log_info "Phase 3: Waiting for cloud-init to complete..."
log_info "Using 'cloud-init status --wait' (best practice for Fedora cloud images)"
log_info "This will block until cloud-init is fully complete..."

# Use cloud-init status --wait (best practice - blocks until done)
# We run it with a timeout wrapper since --wait can hang if cloud-init is stuck
CLOUD_INIT_OUTPUT=$(timeout 300 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo cloud-init status --wait 2>&1" 2>&1 || echo "timeout_or_error")

if echo "$CLOUD_INIT_OUTPUT" | grep -q "status: done"; then
    log_info "✓ Cloud-init completed successfully"
elif echo "$CLOUD_INIT_OUTPUT" | grep -q "timeout_or_error"; then
    log_warn "cloud-init status --wait timed out or failed"
    log_info "Checking current cloud-init status..."
    CLOUD_INIT_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo cloud-init status 2>&1" 2>&1 || echo "unknown")
    log_info "Current status: $CLOUD_INIT_STATUS"
    if echo "$CLOUD_INIT_STATUS" | grep -q "status: done"; then
        log_info "✓ Cloud-init is actually done (status check succeeded)"
    else
        log_warn "Cloud-init may still be running, but continuing with test..."
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo cloud-init status --long 2>&1" 2>&1 | head -15 || true
    fi
else
    log_info "Cloud-init status: $CLOUD_INIT_OUTPUT"
fi

log_info "✓ Ready to proceed"

# Step 4: Copy backup to VM and restore
log_step "Step 4: Restoring backup in VM"
log_info "Copying backup to VM..."
scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2222 "$LOCAL_BACKUP" "${DEFAULT_USER}@localhost:~/backup.tar.gz" 2>&1 || {
    log_error "Failed to copy backup to VM"
    exit 1
}

log_info "Extracting and restoring backup in VM..."
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" << 'RESTORE_EOF'
set -e
cd ~
mkdir -p restore-tmp
cd restore-tmp
tar -xzf ../backup.tar.gz

# Restore directories
sudo mkdir -p /opt/containerdata/ztpbootstrap
sudo mkdir -p /etc/containers/systemd/ztpbootstrap

if [ -d containerdata_ztpbootstrap ]; then
    sudo cp -r containerdata_ztpbootstrap/* /opt/containerdata/ztpbootstrap/
    echo "✓ Restored /opt/containerdata/ztpbootstrap"
fi

if [ -d etc_containers_systemd_ztpbootstrap ]; then
    sudo cp -r etc_containers_systemd_ztpbootstrap/* /etc/containers/systemd/ztpbootstrap/
    echo "✓ Restored /etc/containers/systemd/ztpbootstrap"
fi

if [ -d certs_wild ]; then
    sudo mkdir -p /opt/containerdata/certs/wild
    sudo cp -r certs_wild/* /opt/containerdata/certs/wild/
    echo "✓ Restored /opt/containerdata/certs/wild"
fi

# Set permissions
sudo chown -R root:root /opt/containerdata/ztpbootstrap
sudo chown -R root:root /etc/containers/systemd/ztpbootstrap

cd ~
rm -rf restore-tmp backup.tar.gz

echo "✓ Backup restored successfully"
RESTORE_EOF

log_info "✓ Backup restored in VM"

# Step 5: Clone repo and prepare for interactive setup
log_step "Step 5: Preparing repository in VM"
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" << 'PREP_EOF'
set -e
if [ ! -d ~/ztpbootstrap ]; then
    git clone https://github.com/coreyhines/ztpbootstrap.git ~/ztpbootstrap || {
        echo "Repository may already exist or clone failed"
    }
fi
cd ~/ztpbootstrap
git pull || true

# Ensure yq is installed
if ! command -v yq &> /dev/null; then
    echo "Installing yq..."
    sudo dnf install -y yq 2>/dev/null || sudo apt-get install -y yq 2>/dev/null || {
        echo "Failed to install yq automatically"
    }
fi

echo "✓ Repository ready"
PREP_EOF

log_info "✓ Repository prepared"

# Step 6: Verify restored installation
log_step "Step 6: Verifying restored installation"
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" << 'VERIFY_EOF'
echo "Checking restored files..."
if [ -f /opt/containerdata/ztpbootstrap/ztpbootstrap.env ]; then
    echo "✓ ztpbootstrap.env exists"
    echo "  CV_ADDR: $(grep '^CV_ADDR=' /opt/containerdata/ztpbootstrap/ztpbootstrap.env | cut -d= -f2 || echo 'not found')"
    echo "  NTP_SERVER: $(grep '^NTP_SERVER=' /opt/containerdata/ztpbootstrap/ztpbootstrap.env | cut -d= -f2 || echo 'not found')"
else
    echo "✗ ztpbootstrap.env not found"
fi

if [ -f /opt/containerdata/ztpbootstrap/nginx.conf ]; then
    echo "✓ nginx.conf exists"
    DOMAIN=$(grep -oP 'server_name\s+\K[^;]+' /opt/containerdata/ztpbootstrap/nginx.conf | awk '{print $1}' | head -1 || echo 'not found')
    echo "  Domain: $DOMAIN"
else
    echo "✗ nginx.conf not found"
fi

if [ -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container ]; then
    echo "✓ ztpbootstrap.container exists"
    NETWORK=$(grep '^Network=' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container | cut -d= -f2 || echo 'not found')
    IP=$(grep '^IP=' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container | cut -d= -f2 || echo 'not found')
    echo "  Network: $NETWORK"
    echo "  IP: $IP"
elif [ -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod ]; then
    echo "✓ ztpbootstrap.pod exists"
else
    echo "✗ Container file not found"
fi

echo ""
echo "✓ Verification complete"
VERIFY_EOF

log_info "✓ Installation verified"

echo ""
echo "=========================================="
echo "✅ VM READY FOR TESTING"
echo "=========================================="
echo ""
echo "Setup completed:"
echo "  1. ✓ VM created and ready"
echo "  2. ✓ Backup restored from ${BACKUP_HOST}"
echo "  3. ✓ Repository cloned and updated"
echo ""
echo "Next steps - Test interactive setup:"
echo "  1. SSH into the VM:"
echo "     ssh -p 2222 ${DEFAULT_USER}@localhost"
echo ""
echo "  2. Run interactive setup:"
echo "     cd ~/ztpbootstrap"
echo "     ./setup-interactive.sh"
echo ""
echo "  3. The interactive setup should:"
echo "     - Detect the restored installation"
echo "     - Load existing values from restored files"
echo "     - Use them as defaults in prompts"
echo "     - Offer to create backup (of the restored installation)"
echo "     - Clean directories"
echo "     - Install/upgrade the service"
echo "     - Start services"
echo ""
echo "VM is ready for interactive testing!"
echo ""
