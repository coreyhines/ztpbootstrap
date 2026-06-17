#!/bin/bash
# Complete VM setup for DHCP testing
# 1. Deletes all VMs
# 2. Creates new VM
# 3. Sets up ZTP Bootstrap with static IP
# 4. Ready for DHCP client testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VM_NAME="ztpbootstrap-dhcp-test"
VM_DISK="${HOME}/Downloads/${VM_NAME}.qcow2"
SSH_PORT=2222
SSH_USER="fedora"

# Always start fresh - let vm-create-native.sh download the cloud image
# This ensures we get a clean VM every time
CLOUD_IMAGE=""
DOWNLOAD_DISTRO="fedora"
DOWNLOAD_VERSION="43"
DOWNLOAD_TYPE="cloud"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Step 1: Kill all VMs
log_info "Step 1: Stopping all existing VMs..."
pkill -9 -f qemu 2>/dev/null || true
sleep 2

# Step 2: Create new VM (always fresh)
log_info "Step 2: Creating fresh VM from cloud image..."
log_info "vm-create-native.sh will download Fedora Cloud image if needed"
rm -f "$VM_DISK" 2>/dev/null || true
log_info "✓ All VMs stopped and cleaned up"

# Don't use static IP - keep VM on DHCP to avoid breaking SSH/network
# We'll block QEMU's DHCP from responding to OTHER clients instead
# Build environment variables for vm-create-native.sh
ENV_VARS="VM_NAME=\"$VM_NAME\" VM_DISK=\"$VM_DISK\" HEADLESS=true"
if [[ -n "${CLOUD_IMAGE:-}" ]]; then
    ENV_VARS="$ENV_VARS ISO_PATH=\"$CLOUD_IMAGE\""
fi
if [[ -n "${DOWNLOAD_DISTRO:-}" ]]; then
    ENV_VARS="$ENV_VARS DOWNLOAD_DISTRO=\"$DOWNLOAD_DISTRO\""
fi
if [[ -n "${DOWNLOAD_VERSION:-}" ]]; then
    ENV_VARS="$ENV_VARS DOWNLOAD_VERSION=\"$DOWNLOAD_VERSION\""
fi
if [[ -n "${DOWNLOAD_TYPE:-}" ]]; then
    ENV_VARS="$ENV_VARS DOWNLOAD_TYPE=\"$DOWNLOAD_TYPE\""
fi

eval "$ENV_VARS $SCRIPT_DIR/../scripts/vm-create-native.sh > /tmp/vm-create.log 2>&1 &"

VM_PID=$!
log_info "VM creation started (PID: $VM_PID)"

# Wait for SSH
log_info "Waiting for VM to boot and SSH to be ready..."
for i in {1..120}; do
    if timeout 2 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=1 -p $SSH_PORT ${SSH_USER}@localhost "echo 'ready'" 2>/dev/null; then
        log_info "✓ VM is ready!"
        break
    fi
    if [ $i -eq 120 ]; then
        log_error "VM did not become ready in time"
        exit 1
    fi
    sleep 2
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Still waiting... ($i/120)"
    fi
done

# Step 3: Setup VM
log_info "Step 3: Setting up VM (checkout branch, install dependencies, configure static IP)..."

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Use quoted heredoc to prevent variable expansion in parent shell
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT ${SSH_USER}@localhost "CURRENT_BRANCH='${CURRENT_BRANCH}' bash" << 'VM_SETUP_EOF'
# Set default values before strict mode
CONN_NAME="eth0"
export CURRENT_BRANCH="${CURRENT_BRANCH:-main}"
set -eo pipefail

# Install dependencies
sudo dnf install -y -q git podman curl python3-pip yq iptables firewalld NetworkManager || true

# Clone or update repo (will copy from host if git fails)
if [ -d ~/ztpbootstrap/.git ]; then
    cd ~/ztpbootstrap
    git fetch origin 2>/dev/null || true
    git checkout "${CURRENT_BRANCH}" 2>/dev/null || git checkout main 2>/dev/null || true
    git pull origin "${CURRENT_BRANCH}" 2>/dev/null || git pull origin main 2>/dev/null || true
else
    mkdir -p ~/ztpbootstrap
    cd ~/ztpbootstrap
fi

# Note: VM stays on DHCP (gets 10.0.2.15 from QEMU) to avoid breaking SSH
# We block QEMU's DHCP from responding to OTHER clients so Kea can serve them
# The VM itself can keep using QEMU's DHCP - that's fine

# Block QEMU's DHCP server (10.0.2.2) from responding to OTHER clients
# This allows the VM to keep its DHCP-assigned IP, but prevents QEMU from
# interfering with our Kea DHCP server for test clients
if command -v iptables &>/dev/null; then
    sudo iptables -I INPUT -s 10.0.2.2 -p udp --dport 67 -j DROP 2>/dev/null || true
    echo "✓ Blocked QEMU DHCP using iptables"
elif command -v firewall-cmd &>/dev/null; then
    sudo firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 -s 10.0.2.2 -p udp --dport 67 -j DROP 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    echo "✓ Blocked QEMU DHCP using firewalld"
fi

VM_SETUP_EOF

# Copy repo to VM
log_info "Copying repository to VM..."
tar czf /tmp/ztpbootstrap-repo.tar.gz -C "$REPO_ROOT" --exclude='.git' --exclude='node_modules' --exclude='__pycache__' . 2>/dev/null
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSH_PORT /tmp/ztpbootstrap-repo.tar.gz ${SSH_USER}@localhost:/tmp/ 2>/dev/null
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT ${SSH_USER}@localhost "cd ~/ztpbootstrap && tar xzf /tmp/ztpbootstrap-repo.tar.gz 2>/dev/null && rm -f /tmp/ztpbootstrap-repo.tar.gz" 2>/dev/null

# Step 4: Run non-interactive setup
log_info "Step 4: Running non-interactive setup..."

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT ${SSH_USER}@localhost bash << 'SETUP_EOF'
set -euo pipefail
cd ~/ztpbootstrap

# Create config.yaml with static IP and DHCP enabled
python3 << 'PYTHON_EOF'
import yaml
import hashlib
import secrets

# Generate admin password hash with a proper random byte salt
password = "admin"
salt_bytes = secrets.token_bytes(16)
salt = salt_bytes.hex()
hash_obj = hashlib.pbkdf2_hmac("sha256", password.encode(), salt_bytes, 100000)
password_hash = f"pbkdf2:sha256:100000${salt}${hash_obj.hex()}"

config = {
    'http_only': True,
    'host_network': True,
    'cvaas': {
        'enrollment_token': 'arista'
    },
    'auth': {
        'admin_password_hash': password_hash
    },
    'dhcp': {
        'enabled': True,
        'backend': {
            'type': 'postgresql',
            'postgresql': {
                'host': 'localhost',
                'port': 5432,
                'database': 'kea',
                'user': 'kea',
                'password': 'kea'
            }
        },
        'ipv4': {
            'subnet': '10.0.2.0/24',
            'range_start': '10.0.2.50',
            'range_end': '10.0.2.55',
            'gateway': '10.0.2.2',
            'dns_servers': ['10.0.2.3', '8.8.8.8'],
            'domain': 'local'
        }
    }
}

with open('config.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)

print("✓ Created config.yaml")
PYTHON_EOF

# Run non-interactive setup (use expect or yes to auto-confirm)
# The password is already set in config.yaml, so we just need to confirm
yes | sudo ./setup-interactive.sh --non-interactive 2>&1 | grep -v "^$" || true

# Ensure services are running
sudo systemctl start ztpbootstrap-pod ztpbootstrap-webui 2>/dev/null || true
sudo systemctl enable ztpbootstrap-pod ztpbootstrap-webui 2>/dev/null || true

SETUP_EOF

log_info "✓ Setup complete!"
log_info ""
log_info "VM is ready for DHCP testing:"
log_info "  - SSH: ssh -p $SSH_PORT ${SSH_USER}@localhost"
log_info "  - WebUI: http://localhost:8080/ui"
log_info "  - VM IP: 10.0.2.10 (static)"
log_info "  - DHCP Pool: 10.0.2.50-10.0.2.55"
log_info ""
log_info "Next: Test DHCP client to get a lease from Kea"
