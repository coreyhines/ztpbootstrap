#!/bin/bash
# macOS Firewall Rules to Block QEMU's DHCP Server
# Uses pfctl (packet filter) to block QEMU's DHCP responses

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF_RULES_FILE="/tmp/qemu-dhcp-block.pf.conf"
ANCHOR_NAME="qemu-dhcp-block"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    log_error "This script is for macOS only"
    exit 1
fi

# QEMU's default DHCP server IP in user-mode networking
# For 172.16.0.0/24 network, QEMU's gateway/DHCP is at 172.16.0.2
QEMU_DHCP_IP="172.16.0.2"
QEMU_DHCP_PORT="67"

show_help() {
    cat << EOF
Usage: $0 [enable|disable|status]

Commands:
  enable   - Enable firewall rules to block QEMU's DHCP server
  disable  - Disable firewall rules (allow QEMU's DHCP server)
  status   - Show current status of firewall rules

This script blocks QEMU's DHCP server (${QEMU_DHCP_IP}:${QEMU_DHCP_PORT})
so that only Kea DHCP server responds to DHCP requests from VMs.

EOF
}

enable_block() {
    log_info "Enabling firewall rules to block QEMU's DHCP server..."

    # Create pfctl rules file
    cat > "${PF_RULES_FILE}" << EOF
# Block QEMU's DHCP server responses
# This prevents QEMU's built-in DHCP (10.0.2.2) from responding to DHCP requests

# Block UDP port 67 (DHCP server) from QEMU's DHCP IP
# Note: QEMU's user-mode networking uses NAT, so we need to block from the VM's perspective
# Block both incoming and outgoing DHCP responses from QEMU
block drop in quick proto udp from ${QEMU_DHCP_IP} to any port 67
block drop out quick proto udp from ${QEMU_DHCP_IP} to any port 67

# Also block DHCP responses from the entire QEMU network range (more aggressive)
# For 172.16.0.0/24 network, block the entire subnet
block drop in quick proto udp from 172.16.0.0/24 to any port 67
block drop out quick proto udp from 172.16.0.0/24 to any port 67

# Block DHCP server responses on the loopback interface (QEMU might use this)
block drop in quick on lo0 proto udp from any to any port 67
block drop out quick on lo0 proto udp from any to any port 67

# Allow everything else
pass
EOF

    # Load the rules into pfctl
    if pfctl -f "${PF_RULES_FILE}" 2>/dev/null; then
        log_info "✓ Firewall rules loaded successfully"
    else
        # If pfctl isn't enabled, try to enable it
        log_warn "pfctl not enabled, attempting to enable..."
        if pfctl -e 2>/dev/null; then
            log_info "✓ pfctl enabled"
            if pfctl -f "${PF_RULES_FILE}" 2>/dev/null; then
                log_info "✓ Firewall rules loaded successfully"
            else
                log_error "Failed to load firewall rules"
                return 1
            fi
        else
            log_error "Failed to enable pfctl"
            log_info "You may need to enable it manually:"
            log_info "  sudo pfctl -e"
            return 1
        fi
    fi

    # Also add rules using anchor (more persistent)
    if pfctl -a "${ANCHOR_NAME}" -f "${PF_RULES_FILE}" 2>/dev/null; then
        log_info "✓ Rules added to anchor '${ANCHOR_NAME}'"
    fi

    log_info ""
    log_info "QEMU's DHCP server is now blocked"
    log_info "Kea DHCP server should now be able to respond to DHCP requests"
}

disable_block() {
    log_info "Disabling firewall rules (allowing QEMU's DHCP server)..."

    # Remove anchor rules
    if pfctl -a "${ANCHOR_NAME}" -F all 2>/dev/null; then
        log_info "✓ Removed rules from anchor '${ANCHOR_NAME}'"
    fi

    # Create a pass-all rules file
    cat > "${PF_RULES_FILE}" << EOF
# Allow all traffic (QEMU DHCP unblocked)
pass
EOF

    # Reload with pass-all rules
    if pfctl -f "${PF_RULES_FILE}" 2>/dev/null; then
        log_info "✓ Firewall rules disabled"
    else
        log_warn "Could not reload firewall rules (may already be disabled)"
    fi

    log_info "QEMU's DHCP server is now allowed"
}

show_status() {
    log_info "Checking firewall status..."

    if pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        log_info "✓ pfctl is enabled"

        # Check if our rules are active
        if pfctl -s rules 2>/dev/null | grep -q "${QEMU_DHCP_IP}"; then
            log_info "✓ QEMU DHCP blocking rules are active"
            log_info ""
            log_info "Active rules blocking QEMU DHCP:"
            pfctl -s rules 2>/dev/null | grep "${QEMU_DHCP_IP}" || true
        else
            log_warn "QEMU DHCP blocking rules are not active"
        fi
    else
        log_warn "pfctl is not enabled"
        log_info "Enable it with: sudo pfctl -e"
    fi

    log_info ""
    log_info "Current pfctl rules:"
    pfctl -s rules 2>/dev/null | head -20 || log_warn "Could not show rules"
}

# Main
case "${1:-}" in
    enable)
        enable_block
        ;;
    disable)
        disable_block
        ;;
    status)
        show_status
        ;;
    *)
        show_help
        exit 1
        ;;
esac
