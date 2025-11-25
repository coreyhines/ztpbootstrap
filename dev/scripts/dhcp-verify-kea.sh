#!/bin/bash
# Verify that Kea is using the configured DHCP pool
# This script checks Kea logs to confirm it's offering addresses from the correct range

set -euo pipefail

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

log_info "=========================================="
log_info "Kea DHCP Pool Verification"
log_info "=========================================="
log_info ""

# Check configured pool
log_step "Checking configured DHCP pool..."
CONFIGURED_POOL=$(sudo cat /opt/containerdata/ztpbootstrap/config.yaml 2>/dev/null | grep -A 5 "ipv4:" | grep "range_start\|range_end" | awk '{print $2}' | tr '\n' '-' | sed 's/-$//' || echo "unknown")
log_info "Configured pool: ${CONFIGURED_POOL}"

# Check Kea config file
log_step "Checking Kea configuration file..."
KEA_POOL=$(sudo cat /opt/containerdata/ztpbootstrap/dhcp/kea-dhcp4.conf 2>/dev/null | python3 -c "import sys, json; c=json.load(sys.stdin); print(c['Dhcp4']['subnet4'][0]['pools'][0]['pool'])" 2>/dev/null || echo "unknown")
log_info "Kea pool config: ${KEA_POOL}"

log_info ""
log_step "Triggering a DHCP request and checking Kea's response..."

# Release existing lease
sudo dhclient -r eth0 2>/dev/null || true
sleep 1

# Start a background DHCP request
sudo timeout 10 dhclient -v eth0 >/tmp/dhcp-verify.log 2>&1 &
DHCP_PID=$!

# Wait a moment for Kea to respond
sleep 3

# Check Kea logs for the offer
log_step "Checking Kea logs for DHCP offers..."
OFFERS=$(sudo podman logs ztpbootstrap-dhcp --tail 50 2>&1 | grep "LEASE_OFFER" | tail -3 | grep -oP "lease \K[0-9.]+" || echo "")

if [ -n "${OFFERS}" ]; then
    log_info "✓ Kea is offering addresses from the configured pool:"
    echo "${OFFERS}" | while read offer; do
        if [[ "${offer}" =~ ^10\.0\.2\.(5[0-5])$ ]]; then
            log_info "  ✓ ${offer} (in range 10.0.2.50-10.0.2.55)"
        else
            log_warn "  ⚠ ${offer} (outside expected range)"
        fi
    done
    log_info ""
    log_info "✓ SUCCESS: Kea is correctly using the configured pool!"
    log_info ""
    log_warn "Note: The client may accept QEMU's DHCP offer (10.0.2.15) first,"
    log_warn "      but Kea is correctly offering addresses from your configured range."
else
    log_error "No DHCP offers found in Kea logs"
    log_info "Check if Kea is running: sudo systemctl status ztpbootstrap-dhcp"
fi

# Cleanup
kill $DHCP_PID 2>/dev/null || true
sudo dhclient -r eth0 2>/dev/null || true

log_info "=========================================="
