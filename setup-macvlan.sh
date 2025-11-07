#!/bin/bash
# Check macvlan network for ZTP Bootstrap pod
# This script verifies that the required macvlan network exists
# It does NOT create networks - you must create them yourself

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
NETWORK_NAME="ztpbootstrap-net"

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# Check if macvlan network exists
check_network() {
    log "Checking for macvlan network: $NETWORK_NAME"
    echo ""
    
    if podman network exists "$NETWORK_NAME" 2>/dev/null; then
        log "✓ Network '$NETWORK_NAME' exists"
        echo ""
        
        # Show network details
        info "Network details:"
        podman network inspect "$NETWORK_NAME" 2>/dev/null | grep -E "Name|Driver|Subnet|Gateway" || true
        echo ""
        
        return 0
    else
        error "✗ Network '$NETWORK_NAME' does not exist"
        echo ""
        return 1
    fi
}

# Show instructions for creating macvlan network
show_instructions() {
    warn "The macvlan network must be created before starting the pod."
    echo ""
    info "To create a macvlan network, you need to:"
    echo ""
    echo "1. Identify your network interface and subnet:"
    echo "   ip addr show"
    echo "   ip route show"
    echo ""
    echo "2. Create the macvlan network using podman:"
    echo "   podman network create \\"
    echo "     --driver macvlan \\"
    echo "     --subnet <your-subnet> \\"
    echo "     --gateway <your-gateway> \\"
    echo "     -o parent=<interface> \\"
    echo "     $NETWORK_NAME"
    echo ""
    echo "Example:"
    echo "   podman network create \\"
    echo "     --driver macvlan \\"
    echo "     --subnet 10.0.0.0/24 \\"
    echo "     --gateway 10.0.0.1 \\"
    echo "     -o parent=eth0 \\"
    echo "     $NETWORK_NAME"
    echo ""
    info "For authoritative documentation, see:"
    echo "  - Podman network create: man podman-network-create"
    echo "  - Macvlan networks: https://docs.podman.io/en/latest/markdown/podman-network-create.1.html"
    echo "  - Linux macvlan: https://www.kernel.org/doc/Documentation/networking/macvlan.txt"
    echo ""
    warn "Important considerations:"
    echo "  - Macvlan requires root privileges"
    echo "  - The parent interface must support macvlan"
    echo "  - IP addresses must be within your network's subnet"
    echo "  - Ensure IP addresses don't conflict with existing devices"
    echo "  - Some cloud providers may not support macvlan"
    echo ""
}

# Main function
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Macvlan Network Check${NC}                                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if check_network; then
        log "Network check passed. You can proceed with pod setup."
        exit 0
    else
        show_instructions
        exit 1
    fi
}

main "$@"
