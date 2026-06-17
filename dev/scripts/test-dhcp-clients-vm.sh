#!/bin/bash
# Test DHCP clients on VM via SSH
# This script connects to the VM and runs DHCP client tests on the same macvlan network
# as the ztpbootstrap service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Configuration
VM_USER="${VM_USER:-fedora}"
VM_HOST="${VM_HOST:-localhost}"
VM_PORT="${VM_PORT:-222}"
VM_PATH="${VM_PATH:-~corey/ztpbootstrap}"
NUM_CLIENTS="${NUM_CLIENTS:-3}"
TIMEOUT="${TIMEOUT:-30}"

# Check SSH connection
check_ssh() {
    log_step "Checking SSH connection to VM..."

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "echo 'SSH connection successful'" 2>/dev/null; then
        log_info "✓ SSH connection successful"
        return 0
    else
        log_error "✗ Cannot connect to VM via SSH"
        log_info "  Host: ${VM_HOST}"
        log_info "  Port: ${VM_PORT}"
        log_info "  User: ${VM_USER}"
        log_info ""
        log_info "Make sure the VM is running and accessible at:"
        log_info "  ssh ${VM_USER}@${VM_HOST} -p ${VM_PORT}"
        return 1
    fi
}

# Check if test script exists on VM
check_test_script() {
    log_step "Checking if DHCP test script exists on VM..."

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "test -f ${VM_PATH}/dev/scripts/dhcp-test-macvlan.sh" 2>/dev/null; then
        log_info "✓ DHCP test script found on VM"
        return 0
    else
        log_warn "✗ DHCP test script not found on VM"
        log_info "  Expected path: ${VM_PATH}/dev/scripts/dhcp-test-macvlan.sh"
        log_info ""
        log_info "The script will be copied to the VM..."
        return 1
    fi
}

# Copy test script to VM if needed
copy_test_script() {
    local local_script="${SCRIPT_DIR}/dhcp-test-macvlan.sh"
    local remote_script="${VM_PATH}/dev/scripts/dhcp-test-macvlan.sh"

    if [[ ! -f "${local_script}" ]]; then
        log_error "Local test script not found: ${local_script}"
        return 1
    fi

    log_step "Copying DHCP test script to VM..."

    # Create directory on VM if it doesn't exist
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "mkdir -p ${VM_PATH}/dev/scripts" 2>/dev/null || true

    # Copy script
    if scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -P "${VM_PORT}" \
        "${local_script}" \
        "${VM_USER}@${VM_HOST}:${remote_script}" 2>/dev/null; then
        log_info "✓ Script copied to VM"

        # Make it executable
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
            "chmod +x ${remote_script}" 2>/dev/null || true

        return 0
    else
        log_error "Failed to copy script to VM"
        return 1
    fi
}

# Run DHCP test on VM
run_dhcp_test() {
    log_step "Running DHCP client test on VM..."
    log_info "  Number of clients: ${NUM_CLIENTS}"
    log_info "  Timeout: ${TIMEOUT}s"
    log_info ""

    # Run the test script on the VM
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "cd ${VM_PATH} && \
         NETWORK_NAME=\${NETWORK_NAME:-ztpbootstrap-net} \
         NUM_CLIENTS=${NUM_CLIENTS} \
         TIMEOUT=${TIMEOUT} \
         bash dev/scripts/dhcp-test-macvlan.sh"
}

# Main function
main() {
    log_info "=========================================="
    log_info "DHCP Client Test on VM"
    log_info "=========================================="
    log_info "VM: ${VM_USER}@${VM_HOST}:${VM_PORT}"
    log_info "Path: ${VM_PATH}"
    log_info "Number of clients: ${NUM_CLIENTS}"
    log_info "Timeout: ${TIMEOUT}s"
    log_info ""

    # Check prerequisites
    if ! command -v ssh >/dev/null 2>&1; then
        log_error "ssh is not available"
        exit 1
    fi

    if ! command -v scp >/dev/null 2>&1; then
        log_error "scp is not available"
        exit 1
    fi

    # Check SSH connection
    if ! check_ssh; then
        exit 1
    fi

    # Check if test script exists, copy if needed
    if ! check_test_script; then
        if ! copy_test_script; then
            log_error "Failed to prepare test script on VM"
            exit 1
        fi
    fi

    log_info ""

    # Run the test
    if run_dhcp_test; then
        log_info ""
        log_info "=========================================="
        log_info "✓ DHCP test completed"
        log_info "=========================================="
        exit 0
    else
        log_error ""
        log_error "=========================================="
        log_error "✗ DHCP test failed"
        log_error "=========================================="
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
