#!/bin/bash
# Simple DHCP Client Test using system tools
# Uses dhclient or udhcpc if available

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Configuration
TEST_INTERFACE="${TEST_INTERFACE:-eth0}"
TIMEOUT="${TIMEOUT:-10}"

# Check for available DHCP client tools
check_dhcp_client_tools() {
    if command -v dhclient &> /dev/null; then
        echo "dhclient"
        return 0
    elif command -v udhcpc &> /dev/null; then
        echo "udhcpc"
        return 0
    elif command -v dhcpcd &> /dev/null; then
        echo "dhcpcd"
        return 0
    else
        return 1
    fi
}

# Test with dhclient
test_with_dhclient() {
    local interface="$1"
    log_info "Testing DHCP with dhclient on interface ${interface}"

    # Create a temporary lease file
    local lease_file=$(mktemp)

    # Release any existing lease first
    sudo dhclient -r "${interface}" 2>/dev/null || true

    # Request a new lease with timeout
    if timeout "${TIMEOUT}" sudo dhclient -v -lf "${lease_file}" "${interface}" 2>&1 | tee /tmp/dhcp_test.log; then
        # Parse lease file for IP address
        if [ -f "${lease_file}" ]; then
            local client_ip=$(grep "fixed-address" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            if [ -n "${client_ip}" ]; then
                log_info "DHCP lease obtained: ${client_ip}"
                echo "${client_ip}"

                # Cleanup
                sudo dhclient -r "${interface}" 2>/dev/null || true
                rm -f "${lease_file}"
                return 0
            fi
        fi
    fi

    # Cleanup
    sudo dhclient -r "${interface}" 2>/dev/null || true
    rm -f "${lease_file}"
    return 1
}

# Test with udhcpc
test_with_udhcpc() {
    local interface="$1"
    log_info "Testing DHCP with udhcpc on interface ${interface}"

    # Release any existing lease
    sudo udhcpc -R -i "${interface}" 2>/dev/null || true

    # Request a new lease
    local output=$(timeout "${TIMEOUT}" sudo udhcpc -i "${interface}" -v 2>&1 | tee /tmp/dhcp_test.log)

    if echo "${output}" | grep -q "Lease obtained"; then
        # Extract IP from output
        local client_ip=$(echo "${output}" | grep -oP "Lease of \K[0-9.]+" | head -1 || echo "")
        if [ -n "${client_ip}" ]; then
            log_info "DHCP lease obtained: ${client_ip}"
            echo "${client_ip}"
            return 0
        fi
    fi

    return 1
}

# Test with dhcpcd
test_with_dhcpcd() {
    local interface="$1"
    log_info "Testing DHCP with dhcpcd on interface ${interface}"

    # Release any existing lease
    sudo dhcpcd -k "${interface}" 2>/dev/null || true

    # Request a new lease
    local output=$(timeout "${TIMEOUT}" sudo dhcpcd -n "${interface}" 2>&1 | tee /tmp/dhcp_test.log)

    if echo "${output}" | grep -q "bound to"; then
        # Extract IP from output
        local client_ip=$(echo "${output}" | grep -oP "bound to \K[0-9.]+" | head -1 || echo "")
        if [ -n "${client_ip}" ]; then
            log_info "DHCP lease obtained: ${client_ip}"
            echo "${client_ip}"
            return 0
        fi
    fi

    return 1
}

# Main test function
main() {
    local interface="${1:-${TEST_INTERFACE}}"

    log_info "Starting DHCP client test on interface: ${interface}"

    # Check if interface exists
    if ! ip link show "${interface}" &> /dev/null; then
        log_error "Interface ${interface} not found"
        return 1
    fi

    # Check for DHCP client tools
    local tool=$(check_dhcp_client_tools)
    if [ -z "${tool}" ]; then
        log_error "No DHCP client tools found (dhclient, udhcpc, or dhcpcd)"
        log_error "Please install one of:"
        log_error "  - dhclient (isc-dhcp-client)"
        log_error "  - udhcpc (busybox)"
        log_error "  - dhcpcd"
        return 1
    fi

    log_info "Using DHCP client tool: ${tool}"

    # Run test with appropriate tool
    case "${tool}" in
        dhclient)
            test_with_dhclient "${interface}"
            ;;
        udhcpc)
            test_with_udhcpc "${interface}"
            ;;
        dhcpcd)
            test_with_dhcpcd "${interface}"
            ;;
        *)
            log_error "Unknown tool: ${tool}"
            return 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
