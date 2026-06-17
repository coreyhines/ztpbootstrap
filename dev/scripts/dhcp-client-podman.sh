#!/bin/bash
# DHCP Client Test using Podman container on host network
# This bypasses QEMU's DHCP server and tests Kea directly

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
CLIENT_NAME="${CLIENT_NAME:-dhcp-test-client}"
TIMEOUT="${TIMEOUT:-15}"
INTERFACE="${INTERFACE:-eth0}"

# Check if running as root or with sudo
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root or with sudo"
        log_info "Usage: sudo $0"
        exit 1
    fi
}

# Test using Podman container with host networking
test_with_podman() {
    local interface="$1"
    log_step "Testing DHCP using Podman container with host networking"

    # Use a lightweight image with network tools
    local image="docker.io/library/alpine:latest"

    log_info "Pulling image if needed: ${image}"
    podman pull "${image}" >/dev/null 2>&1 || true

    log_info "Running DHCP client in container on host network..."
    log_info "This will bypass QEMU's DHCP and test Kea directly"

    # Run container with host networking and dhclient
    # Note: With host networking, the container shares the host's network stack
    if podman run --rm --network=host \
        "${image}" \
        sh -c "
            apk update -q >/dev/null 2>&1
            apk add --no-cache dhcp-client >/dev/null 2>&1
            echo 'Requesting DHCP lease on host network...'
            timeout ${TIMEOUT} dhclient -v ${interface} 2>&1 || exit 1
            echo 'Lease obtained!'
            ip addr show ${interface} | grep 'inet '
            dhclient -r ${interface} 2>/dev/null || true
        "; then
        log_info "✓ DHCP lease obtained via container!"
        return 0
    else
        log_error "DHCP request failed in container"
        return 1
    fi
}

# Main function
main() {
    local interface="${1:-${INTERFACE}}"

    log_info "=========================================="
    log_info "DHCP Client Test (Podman - Host Network)"
    log_info "=========================================="
    log_info "Interface: ${interface}"
    log_info "Timeout: ${TIMEOUT}s"
    log_info ""

    # Check permissions
    check_permissions

    # Check if DHCP server is running
    log_step "Checking if DHCP server is running..."
    if ! systemctl is-active --quiet ztpbootstrap-dhcp 2>/dev/null; then
        log_warn "DHCP service may not be running"
        if ! podman ps | grep -q ztpbootstrap-dhcp; then
            log_error "DHCP container is not running!"
            log_info "Start it with: sudo systemctl start ztpbootstrap-dhcp"
            exit 1
        fi
    else
        log_info "✓ DHCP service is running"
    fi

    log_info ""

    # Test with Podman container
    if test_with_podman "${interface}"; then
        log_info "=========================================="
        log_info "✓ DHCP Client Test: SUCCESS"
        log_info "=========================================="
        exit 0
    else
        log_error "=========================================="
        log_error "✗ DHCP Client Test: FAILED"
        log_error "=========================================="
        log_info "Troubleshooting:"
        log_info "1. Check DHCP server logs: sudo podman logs ztpbootstrap-dhcp"
        log_info "2. Check DHCP service status: sudo systemctl status ztpbootstrap-dhcp"
        log_info "3. Verify DHCP config: Check /opt/containerdata/ztpbootstrap/dhcp/kea-dhcp4.conf"
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
