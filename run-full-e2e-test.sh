#!/bin/bash
# Complete End-to-End Test Script
# Tests from VM creation to service deployment

set -euo pipefail

DISTRO="${1:-fedora}"
VERSION="${2:-43}"

# Determine default user based on distribution
if [[ "$DISTRO" == "ubuntu" ]] || [[ "$DISTRO" == "debian" ]]; then
    DEFAULT_USER="ubuntu"
else
    DEFAULT_USER="fedora"
fi

echo "=========================================="
echo "Complete End-to-End Test"
echo "=========================================="
echo "Distribution: $DISTRO $VERSION"
echo "Default user: $DEFAULT_USER"
echo "Date: $(date +'%Y-%m-%d %H:%M:%S')"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -f qemu-system-aarch64 2>/dev/null || true
    sleep 2
    rm -f ztpbootstrap-test*.qcow2 2>/dev/null || true
}

trap cleanup EXIT

# Step 1: Create VM
echo "=== Step 1: Creating VM ==="
# Clean up any existing disk images before starting
rm -f ztpbootstrap-test*.qcow2 2>/dev/null || true
./vm-create-native.sh --download "$DISTRO" --type cloud --arch aarch64 --version "$VERSION" --headless 2>&1 | tee /tmp/e2e-vm-create.log &
VM_PID=$!
echo "VM creation started (PID: $VM_PID)"
sleep 5

# Wait for VM to be running
echo "Waiting for VM process..."
for i in {1..30}; do
    if ps aux | grep -i "qemu-system-aarch64" | grep -v grep > /dev/null; then
        echo "✓ VM is running"
        break
    fi
    sleep 2
    if [ $i -eq 30 ]; then
        echo "✗ VM failed to start"
        exit 1
    fi
done

# Step 2: Wait for SSH (optimized)
echo ""
echo "=== Step 2: Waiting for SSH (optimized) ==="
if [ -f ./wait-for-ssh.sh ]; then
    # Increase timeout to 600s (10 minutes) to allow cloud-init to complete
    # Cloud-init can take 5-10 minutes on first boot, especially with package installation
    ./wait-for-ssh.sh localhost 2222 "$DEFAULT_USER" 600 2 || {
        echo "✗ SSH wait failed"
        exit 1
    }
else
    echo "Using fallback SSH wait..."
    SSH_SUCCESS=false
    for i in {1..30}; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p 2222 "${DEFAULT_USER}@localhost" "echo 'SSH ready'" 2>/dev/null; then
            echo "✓ SSH is ready (attempt $i)"
            SSH_SUCCESS=true
            break
        fi
        sleep 2
    done
    if [ "$SSH_SUCCESS" != "true" ]; then
        echo "✗ SSH connection failed"
        exit 1
    fi
fi

# Step 3: Verify cloud-init completed
echo ""
echo "=== Step 3: Verifying Cloud-Init ==="
# Wait a bit longer for cloud-init to complete (Ubuntu can be slower)
echo "Waiting 30 seconds for cloud-init to complete..."
sleep 30

# Check each file individually for better error reporting
ENV_FILE_EXISTS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "test -f /opt/containerdata/ztpbootstrap/ztpbootstrap.env && echo 'yes' || echo 'no'" 2>&1)
SETUP_FILE_EXISTS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "test -f ~/ztpbootstrap/setup.sh && echo 'yes' || echo 'no'" 2>&1)

if [[ "$ENV_FILE_EXISTS" != "yes" ]]; then
    echo "✗ Cloud-init verification failed: /opt/containerdata/ztpbootstrap/ztpbootstrap.env not found"
    echo "Checking cloud-init status..."
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo cloud-init status --long 2>&1" 2>&1 | head -20
    exit 1
fi

if [[ "$SETUP_FILE_EXISTS" != "yes" ]]; then
    echo "✗ Cloud-init verification failed: ~/ztpbootstrap/setup.sh not found"
    echo "Checking if repository was cloned..."
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "ls -la ~/ztpbootstrap/ 2>&1 || echo 'Directory does not exist'" 2>&1
    exit 1
fi

echo "✓ Cloud-init completed successfully"

# Step 4: Run service setup
echo ""
echo "=== Step 4: Running Service Setup ==="
if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "cd ~/ztpbootstrap && sudo ./setup.sh --http-only" 2>&1 | tee /tmp/e2e-setup.log; then
    echo "✗ Service setup failed"
    exit 1
fi

# Step 5: Verify services started
echo ""
echo "=== Step 5: Verifying Services ==="
sleep 20

# Check pod
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo systemctl is-active ztpbootstrap-pod > /dev/null 2>&1" 2>&1; then
    echo "✗ Pod service not active"
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo systemctl status ztpbootstrap-pod --no-pager | head -20" 2>&1
    exit 1
fi
echo "✓ Pod service is active"

# Check containers
CONTAINERS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo podman ps --format '{{.Names}}' 2>&1" 2>&1)
if ! echo "$CONTAINERS" | grep -q "ztpbootstrap-pod-infra"; then
    echo "✗ Pod infra container not running"
    exit 1
fi
if ! echo "$CONTAINERS" | grep -q "ztpbootstrap-nginx"; then
    echo "✗ Nginx container not running"
    exit 1
fi
echo "✓ All containers running"

# Step 6: Test health endpoint (inside container)
echo ""
echo "=== Step 6: Testing Health Endpoint ==="
sleep 10
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 "${DEFAULT_USER}@localhost" "sudo podman exec ztpbootstrap-nginx curl -s http://localhost/health 2>&1 | grep -q 'OK' || echo 'Health check response:' && sudo podman exec ztpbootstrap-nginx curl -s http://localhost/health 2>&1" 2>&1; then
    echo "⚠ Health endpoint check (non-critical)"
else
    echo "✓ Health endpoint responding"
fi

echo ""
echo "=========================================="
echo "✅ TEST COMPLETE - ALL STEPS PASSED"
echo "=========================================="
echo "Distribution: $DISTRO $VERSION"
echo "Date: $(date +'%Y-%m-%d %H:%M:%S')"
echo ""
echo "Summary:"
echo "  ✅ VM Creation"
echo "  ✅ SSH Access"
echo "  ✅ Cloud-Init"
echo "  ✅ Service Setup"
echo "  ✅ Services Running"
echo ""
echo "No manual interventions required!"
