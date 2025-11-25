#!/bin/bash
# Setup script for DHCP testing with isolation
# This script sets up an isolated network environment for DHCP testing
# while maintaining web UI access on localhost:8080

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

NETWORK_NAME="ztpbootstrap-net"
CONFIG_FILE="${1:-config.yaml}"

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

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script requires root privileges for network operations"
        error "Please run with: sudo $0"
        exit 1
    fi
}

# Normalize subnet to base subnet (e.g., 172.16.0.15/24 -> 172.16.0.0/24)
normalize_subnet() {
    local subnet="$1"
    local ip_part=$(echo "$subnet" | cut -d'/' -f1)
    local cidr=$(echo "$subnet" | cut -d'/' -f2)

    if [[ -z "$ip_part" ]] || [[ -z "$cidr" ]]; then
        echo "$subnet"
        return
    fi

    # Use Python for reliable subnet calculation
    if command -v python3 >/dev/null 2>&1; then
        local normalized=$(python3 -c "
import ipaddress
try:
    net = ipaddress.ip_network('$subnet', strict=False)
    print(f'{net.network_address}/{net.prefixlen}')
except:
    print('$subnet')
" 2>/dev/null)
        echo "$normalized"
        return
    fi

    # Fallback: simple calculation for common CIDR values
    # Parse IP address
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip_part"

    # For /24, zero out the last octet
    if [[ "$cidr" == "24" ]]; then
        echo "${i1}.${i2}.${i3}.0/${cidr}"
    # For /16, zero out last two octets
    elif [[ "$cidr" == "16" ]]; then
        echo "${i1}.${i2}.0.0/${cidr}"
    # For /8, zero out last three octets
    elif [[ "$cidr" == "8" ]]; then
        echo "${i1}.0.0.0/${cidr}"
    else
        # For other CIDR values, try to use ipcalc if available
        if command -v ipcalc >/dev/null 2>&1; then
            ipcalc -n "$subnet" 2>/dev/null | grep -oP 'Network:\s*\K[^\s]+' || echo "$subnet"
        else
            # Last resort: return as-is (may cause issues but better than failing)
            warn "Could not normalize subnet $subnet, using as-is"
            echo "$subnet"
        fi
    fi
}

# Detect network interface and subnet
detect_network_info() {
    log "Detecting network configuration..."

    # Find the primary ethernet interface
    ETH_IFACE=$(ip -o link show 2>/dev/null | grep -E '^[0-9]+: (eth|ens|enp|enx)' | head -1 | cut -d: -f2 | tr -d ' ' || echo "")

    if [[ -z "$ETH_IFACE" ]]; then
        # Try to find any non-loopback interface
        ETH_IFACE=$(ip -o link show 2>/dev/null | grep -v '^[0-9]*: lo' | grep -E '^[0-9]+: ' | head -1 | cut -d: -f2 | tr -d ' ' || echo "")
    fi

    if [[ -z "$ETH_IFACE" ]]; then
        error "Could not detect network interface"
        return 1
    fi

    log "Detected interface: $ETH_IFACE"

    # Get subnet from interface
    INTERFACE_SUBNET=$(ip -4 addr show "$ETH_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+/[\d]+' | head -1 || echo "")

    if [[ -z "$INTERFACE_SUBNET" ]]; then
        error "Could not detect subnet from interface $ETH_IFACE"
        return 1
    fi

    # Normalize to base subnet for Podman network creation
    SUBNET=$(normalize_subnet "$INTERFACE_SUBNET")

    log "Detected interface subnet: $INTERFACE_SUBNET"
    log "Normalized subnet: $SUBNET"

    # Get gateway
    GATEWAY=$(ip route show default 2>/dev/null | grep "$ETH_IFACE" | awk '{print $3}' | head -1 || echo "")
    if [[ -z "$GATEWAY" ]]; then
        # Try to get gateway from default route
        GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1 || echo "")
    fi

    if [[ -z "$GATEWAY" ]]; then
        # Extract gateway from subnet (first IP)
        SUBNET_BASE=$(echo "$SUBNET" | cut -d'/' -f1)
        GATEWAY=$(echo "$SUBNET_BASE" | sed "s/\.[0-9]*$/.1/")
        warn "Could not detect gateway, using first IP in subnet: $GATEWAY"
    else
        log "Detected gateway: $GATEWAY"
    fi

    # Extract a suitable IP for the pod (use .10 if available, otherwise .100)
    SUBNET_BASE=$(echo "$SUBNET" | cut -d'/' -f1)
    if [[ "$SUBNET_BASE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. ]]; then
        POD_IP="${BASH_REMATCH[1]}.10"
        # Check if .10 is the gateway, if so use .100
        if [[ "$POD_IP" == "$GATEWAY" ]]; then
            POD_IP="${BASH_REMATCH[1]}.100"
        fi
    else
        POD_IP=""
    fi

    export ETH_IFACE SUBNET GATEWAY POD_IP
    return 0
}

# Create macvlan network
create_macvlan_network() {
    log "Creating macvlan network '$NETWORK_NAME'..."

    if podman network exists "$NETWORK_NAME" 2>/dev/null; then
        warn "Network '$NETWORK_NAME' already exists"
        info "Checking if it matches current configuration..."

        # Check if network matches
        EXISTING_SUBNET=$(podman network inspect "$NETWORK_NAME" 2>/dev/null | grep -oP '"subnet":\s*"\K[^"]+' | head -1 || echo "")

        # Normalize existing subnet for comparison
        if [[ -n "$EXISTING_SUBNET" ]]; then
            EXISTING_SUBNET_NORMALIZED=$(normalize_subnet "$EXISTING_SUBNET")
        else
            EXISTING_SUBNET_NORMALIZED=""
        fi

        if [[ "$EXISTING_SUBNET_NORMALIZED" == "$SUBNET" ]]; then
            log "✓ Existing network matches current subnet"
            return 0
        else
            warn "Existing network has different subnet: $EXISTING_SUBNET"
            warn "Current subnet: $SUBNET"
            warn ""
            warn "Removing existing network to recreate with correct configuration..."

            # Remove existing network
            if podman network rm "$NETWORK_NAME" 2>/dev/null; then
                log "✓ Removed existing network"
            else
                error "Failed to remove existing network"
                error "Please remove manually: podman network rm $NETWORK_NAME"
                return 1
            fi
        fi
    fi

    log "Creating network with subnet=$SUBNET, gateway=$GATEWAY, parent=$ETH_IFACE"
    if podman network create -d macvlan \
        --subnet="$SUBNET" \
        --gateway="$GATEWAY" \
        -o parent="$ETH_IFACE" \
        "$NETWORK_NAME" 2>&1; then
        log "✓ Successfully created macvlan network '$NETWORK_NAME'"
        return 0
    else
        error "Failed to create macvlan network"
        return 1
    fi
}

# Update config.yaml with correct network settings
update_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "Config file not found: $CONFIG_FILE"
        return 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        error "yq is required to update config file"
        return 1
    fi

    log "Updating config file: $CONFIG_FILE"

    # Update network settings
    yq eval ".network.network = \"$NETWORK_NAME\"" -i "$CONFIG_FILE" 2>/dev/null || true
    yq eval ".network.ipv4 = \"$POD_IP\"" -i "$CONFIG_FILE" 2>/dev/null || true

    log "✓ Updated config file"
    log "  Network: $NETWORK_NAME"
    log "  IPv4: $POD_IP"

    # Also update the installation directory config if it exists
    # This ensures setup-interactive.sh picks up the correct values
    local install_config="/opt/containerdata/ztpbootstrap/config.yaml"
    if [[ -f "$install_config" ]]; then
        log "Updating installation config file: $install_config"
        yq eval ".network.network = \"$NETWORK_NAME\"" -i "$install_config" 2>/dev/null || true
        yq eval ".network.ipv4 = \"$POD_IP\"" -i "$install_config" 2>/dev/null || true
        log "✓ Updated installation config file"
    fi

    return 0
}

# Check if web UI will be accessible
check_webui_access() {
    log "Checking web UI access configuration..."

    if command -v yq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
        HOST_NETWORK=$(yq eval '.container.host_network // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

        if [[ "$HOST_NETWORK" == "true" ]]; then
            info "Host networking mode enabled - web UI will be accessible on localhost:8080"
            info "Note: DHCP will bind to host interfaces (may conflict with existing DHCP)"
        else
            info "Macvlan networking mode - web UI access depends on port forwarding"
            info "If running in VM with port forwarding (8080->80), web UI will be accessible"
            info "Otherwise, you may need to enable host_network: true in config.yaml"
        fi
    else
        warn "Could not check web UI configuration"
    fi
}

# Main function
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}DHCP Testing Network Setup${NC}                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Check root
    check_root

    # Detect network info
    if ! detect_network_info; then
        error "Failed to detect network configuration"
        exit 1
    fi

    echo ""
    info "Network Configuration:"
    echo "  Interface: $ETH_IFACE"
    echo "  Subnet: $SUBNET"
    echo "  Gateway: $GATEWAY"
    echo "  Pod IP: $POD_IP"
    echo ""

    # Create macvlan network
    if ! create_macvlan_network; then
        error "Failed to create macvlan network"
        exit 1
    fi

    # Update config
    if [[ -f "$CONFIG_FILE" ]]; then
        update_config
    else
        warn "Config file not found, skipping config update"
    fi

    # Check web UI access
    echo ""
    check_webui_access

    echo ""
    log "Setup complete!"
    echo ""
    info "Next steps:"
    echo "  1. Review config.yaml to ensure settings are correct"
    echo "  2. Run: ./setup-interactive.sh --non-interactive"
    echo "  3. Start services: sudo systemctl start ztpbootstrap-pod"
    echo "  4. Access web UI: http://localhost:8080/ui"
    echo ""
    info "For DHCP testing:"
    echo "  - DHCP server will be isolated on macvlan network"
    echo "  - Use a separate interface or VM for DHCP client testing"
    echo "  - Ensure DHCP client is on the same subnet: $SUBNET"
    echo ""
}

main "$@"
