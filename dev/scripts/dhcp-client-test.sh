#!/bin/bash
# DHCP Client Test Script
# Simulates a DHCP client on the same host network to request an address from Kea

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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

# Check for available DHCP client tools
check_dhcp_client() {
    if command -v dhclient &> /dev/null; then
        echo "dhclient"
        return 0
    elif command -v udhcpc &> /dev/null; then
        echo "udhcpc"
        return 0
    else
        return 1
    fi
}

# Test with dhclient
test_with_dhclient() {
    local interface="$1"
    log_step "Testing DHCP with dhclient on interface ${interface}"

    # Create a temporary lease file
    local lease_file=$(mktemp)
    local log_file=$(mktemp)

    # Release any existing lease first
    log_info "Releasing any existing DHCP lease..."
    dhclient -r "${interface}" 2>/dev/null || true
    sleep 1

    # Request a new lease with timeout
    log_info "Requesting DHCP lease (timeout: ${TIMEOUT}s)..."
    local dhcp_output=$(timeout "${TIMEOUT}" dhclient -v -lf "${lease_file}" "${interface}" 2>&1 | tee "${log_file}" || true)

    # Check if we got a lease (look for DHCPACK or "bound to")
    if echo "${dhcp_output}" | grep -qE "DHCPACK|bound to"; then
        # Try to get IP from lease file first
        local client_ip=""
        if [ -f "${lease_file}" ]; then
            client_ip=$(grep -E "fixed-address|lease.*address" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
        fi

        # If not in lease file, extract from output or interface
        if [ -z "${client_ip}" ]; then
            # Try to extract from DHCPACK line
            client_ip=$(echo "${dhcp_output}" | grep -oP "DHCPACK of \K[0-9.]+" | head -1 || echo "")
        fi

        # If still not found, check interface directly
        if [ -z "${client_ip}" ]; then
            client_ip=$(ip addr show "${interface}" | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1 || echo "")
        fi

        if [ -n "${client_ip}" ]; then
            log_info "✓ DHCP lease obtained successfully!"
            log_info "  IP Address: ${client_ip}"

            # Get additional info from lease file
            local subnet=$(grep "subnet-mask" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            local router=$(grep "routers" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            local dns=$(grep "domain-name-servers" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            local domain=$(grep "domain-name" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")

            if [ -n "${subnet}" ]; then
                log_info "  Subnet Mask: ${subnet}"
            fi
            if [ -n "${router}" ]; then
                log_info "  Gateway: ${router}"
            fi
            if [ -n "${dns}" ]; then
                log_info "  DNS Servers: ${dns}"
            fi
            if [ -n "${domain}" ]; then
                log_info "  Domain: ${domain}"
            fi

            # Show lease file location
            log_info "  Lease file: ${lease_file}"

            # Cleanup
            log_info "Releasing lease..."
            dhclient -r "${interface}" 2>/dev/null || true
            rm -f "${lease_file}" "${log_file}"
            return 0
        fi
    fi

    # Check log file for errors
    if [ -f "${log_file}" ]; then
        log_error "DHCP request failed. Log output:"
        cat "${log_file}" | tail -20
    fi

    # Cleanup
    dhclient -r "${interface}" 2>/dev/null || true
    rm -f "${lease_file}" "${log_file}"
    return 1
}

# Test with udhcpc
test_with_udhcpc() {
    local interface="$1"
    log_step "Testing DHCP with udhcpc on interface ${interface}"

    # Release any existing lease
    log_info "Releasing any existing DHCP lease..."
    udhcpc -R -i "${interface}" 2>/dev/null || true
    sleep 1

    # Request a new lease
    log_info "Requesting DHCP lease (timeout: ${TIMEOUT}s)..."
    local output=$(timeout "${TIMEOUT}" udhcpc -i "${interface}" -v 2>&1 | tee /tmp/dhcp_test.log)

    if echo "${output}" | grep -q "Lease obtained\|bound"; then
        # Extract IP from output
        local client_ip=$(echo "${output}" | grep -oP "Lease of \K[0-9.]+" | head -1 || \
                         echo "${output}" | grep -oP "bound to \K[0-9.]+" | head -1 || echo "")
        if [ -n "${client_ip}" ]; then
            log_info "✓ DHCP lease obtained successfully!"
            log_info "  IP Address: ${client_ip}"

            # Get IP info
            local ip_info=$(ip addr show "${interface}" | grep "inet " | head -1 || echo "")
            if [ -n "${ip_info}" ]; then
                log_info "  Interface info: ${ip_info}"
            fi

            # Release lease
            log_info "Releasing lease..."
            udhcpc -R -i "${interface}" 2>/dev/null || true
            return 0
        fi
    fi

    log_error "DHCP request failed. Output:"
    echo "${output}" | tail -20
    return 1
}

# Test using Podman container with host networking
test_with_podman() {
    local interface="$1"
    log_step "Testing DHCP using Podman container with host networking"

    # Check if interface exists
    if ! ip link show "${interface}" &> /dev/null; then
        log_error "Interface ${interface} not found"
        return 1
    fi

    # Use a lightweight image with network tools
    local image="docker.io/library/alpine:latest"

    log_info "Pulling image if needed: ${image}"
    podman pull "${image}" >/dev/null 2>&1 || true

    log_info "Running DHCP client in container..."
    log_info "Container will use host networking to access DHCP server"

    # Run container with host networking and dhclient
    if podman run --rm --network=host \
        -v /tmp:/tmp \
        "${image}" \
        sh -c "
            apk add --no-cache dhcp-client >/dev/null 2>&1
            echo 'Requesting DHCP lease...'
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
    log_info "DHCP Client Test"
    log_info "=========================================="
    log_info "Interface: ${interface}"
    log_info "Timeout: ${TIMEOUT}s"
    log_info ""

    # Check permissions
    check_permissions

    # Check if interface exists
    if ! ip link show "${interface}" &> /dev/null; then
        log_error "Interface ${interface} not found"
        log_info "Available interfaces:"
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'
        exit 1
    fi

    # Check if DHCP server is running
    log_step "Checking if DHCP server is running..."
    if ! systemctl is-active --quiet ztpbootstrap-dhcp 2>/dev/null; then
        log_warn "DHCP service may not be running"
        log_info "Checking container status..."
        if ! podman ps | grep -q ztpbootstrap-dhcp; then
            log_error "DHCP container is not running!"
            log_info "Start it with: sudo systemctl start ztpbootstrap-dhcp"
            exit 1
        fi
    else
        log_info "✓ DHCP service is running"
    fi

    log_info ""

    # Try different methods
    local success=0

    # Method 1: Try system dhclient
    if command -v dhclient &> /dev/null; then
        log_info "Method 1: Using system dhclient"
        if test_with_dhclient "${interface}"; then
            success=1
        fi
        log_info ""
    fi

    # Method 2: Try udhcpc if dhclient failed
    if [ ${success} -eq 0 ] && command -v udhcpc &> /dev/null; then
        log_info "Method 2: Using udhcpc"
        if test_with_udhcpc "${interface}"; then
            success=1
        fi
        log_info ""
    fi

    # Method 3: Try Podman container if both failed
    if [ ${success} -eq 0 ]; then
        log_info "Method 3: Using Podman container"
        if test_with_podman "${interface}"; then
            success=1
        fi
        log_info ""
    fi

    if [ ${success} -eq 1 ]; then
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
        log_info "4. Check for port conflicts: sudo netstat -ulnp | grep -E '67|68'"
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
