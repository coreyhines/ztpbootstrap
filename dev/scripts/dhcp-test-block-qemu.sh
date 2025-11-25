#!/bin/bash
# DHCP Test Script that blocks QEMU's DHCP server to test Kea
# This temporarily blocks QEMU's DHCP (10.0.2.2) so Kea can respond first

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

INTERFACE="${1:-eth0}"
QEMU_DHCP="10.0.2.2"

log_info "Blocking QEMU's DHCP server (${QEMU_DHCP}) to test Kea..."
log_info "This will allow Kea to respond first to DHCP requests"

# Block QEMU's DHCP server using iptables
if command -v iptables >/dev/null 2>&1; then
    # Block UDP port 67 from QEMU's DHCP server
    iptables -I INPUT -i ${INTERFACE} -s ${QEMU_DHCP} -p udp --dport 67 -j DROP 2>/dev/null || true
    log_info "✓ Blocked QEMU DHCP using iptables"

    # Cleanup function
    cleanup() {
        log_info "Restoring QEMU DHCP..."
        iptables -D INPUT -i ${INTERFACE} -s ${QEMU_DHCP} -p udp --dport 67 -j DROP 2>/dev/null || true
    }
    trap cleanup EXIT

    # Release existing lease
    log_info "Releasing existing DHCP lease..."
    dhclient -r ${INTERFACE} 2>/dev/null || true
    sleep 2

    # Request new lease
    log_info "Requesting DHCP lease (should get address from Kea pool 10.0.2.50-10.0.2.55)..."
    if timeout 15 dhclient -v ${INTERFACE} 2>&1 | tee /tmp/dhcp-test.log; then
        # Check what IP we got
        local client_ip=$(grep -oP "DHCPACK of \K[0-9.]+" /tmp/dhcp-test.log | head -1 || \
                         ip addr show ${INTERFACE} | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)

        if [ -n "${client_ip}" ]; then
            log_info "✓ DHCP lease obtained: ${client_ip}"

            # Check if it's in the expected range
            if [[ "${client_ip}" =~ ^10\.0\.2\.(5[0-5])$ ]]; then
                log_info "✓ SUCCESS: Got address ${client_ip} from Kea's configured pool (10.0.2.50-10.0.2.55)!"
                exit 0
            else
                log_error "Got ${client_ip}, but expected address in range 10.0.2.50-10.0.2.55"
                exit 1
            fi
        fi
    fi

    log_error "DHCP request failed"
    cat /tmp/dhcp-test.log | tail -20
    exit 1
else
    log_error "iptables not found - cannot block QEMU DHCP"
    exit 1
fi
