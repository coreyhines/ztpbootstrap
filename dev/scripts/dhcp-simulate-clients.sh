#!/bin/bash
# Simulate multiple DHCP clients that complete the full DHCP handshake
# This script creates temporary network namespaces to simulate clients

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[DHCP-SIM]"

log_info() {
    echo "${LOG_PREFIX} [INFO] $*"
}

log_step() {
    echo "${LOG_PREFIX} [STEP] $*"
}

log_error() {
    echo "${LOG_PREFIX} [ERROR] $*" >&2
}

log_success() {
    echo "${LOG_PREFIX} [SUCCESS] $*"
}

# Configuration
NUM_CLIENTS="${NUM_CLIENTS:-3}"
TIMEOUT="${TIMEOUT:-30}"
INTERFACE="${INTERFACE:-eth0}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

cleanup() {
    log_info "Cleaning up network namespaces..."
    for i in $(seq 1 "${NUM_CLIENTS}"); do
        local ns="dhcp-client-${i}"
        if ip netns list | grep -q "^${ns}"; then
            ip netns delete "${ns}" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (for network namespaces)"
    exit 1
fi

log_info "=========================================="
log_info "DHCP Client Simulation"
log_info "=========================================="
log_info "Number of clients: ${NUM_CLIENTS}"
log_info "Interface: ${INTERFACE}"
log_info "Timeout: ${TIMEOUT}s"
log_info ""

# Get the host's IP and network info
HOST_IP=$(ip -4 addr show "${INTERFACE}" | grep -oP 'inet \K[0-9.]+' | head -1)
HOST_NETWORK=$(ip route | grep "${INTERFACE}" | grep -v default | head -1 | awk '{print $1}')

log_info "Host IP: ${HOST_IP}"
log_info "Host Network: ${HOST_NETWORK}"
log_info ""

# Create virtual network interfaces for each client
log_step "Creating network namespaces and virtual interfaces..."

for i in $(seq 1 "${NUM_CLIENTS}"); do
    ns="dhcp-client-${i}"
    veth_host="veth-host-${i}"
    veth_client="veth-client-${i}"
    mac="02:00:00:00:00:$(printf "%02x" "${i}")"

    log_info "Creating namespace ${ns} with MAC ${mac}..."

    # Create namespace
    ip netns add "${ns}" || {
        log_error "Failed to create namespace ${ns}"
        continue
    }

    # Create veth pair
    ip link add "${veth_host}" type veth peer name "${veth_client}" netns "${ns}" || {
        log_error "Failed to create veth pair for ${ns}"
        ip netns delete "${ns}" 2>/dev/null || true
        continue
    }

    # Configure host-side veth
    ip link set "${veth_host}" up
    ip link set "${veth_host}" address "${mac}"

    # Configure client-side veth in namespace
    ip netns exec "${ns}" ip link set "${veth_client}" up
    ip netns exec "${ns}" ip link set "${veth_client}" address "${mac}"

    # Add host-side veth to bridge or connect to main interface
    # For simplicity, we'll use macvlan or just connect directly
    # In a real scenario, you'd bridge these or use macvlan

    log_success "Created namespace ${ns}"
done

log_info ""
log_step "Starting DHCP clients in namespaces..."

# Function to run dhclient in a namespace
run_dhcp_client() {
    ns="$1"
    veth="$2"
    client_num="$3"

    log_info "Starting DHCP client ${client_num} in namespace ${ns}..."

    # Run dhclient in the namespace with timeout
    lease_file="/tmp/dhcp-lease-${client_num}.lease"
    log_file="/tmp/dhcp-client-${client_num}.log"

    # Start dhclient in background
    (
        ip netns exec "${ns}" timeout "${TIMEOUT}" dhclient -v -lf "${lease_file}" "${veth}" 2>&1 | tee "${log_file}" || true
    ) &

    pid=$!
    echo "${pid}"
}

# Start all clients
declare -a CLIENT_PIDS=()
for i in $(seq 1 "${NUM_CLIENTS}"); do
    ns="dhcp-client-${i}"
    veth="veth-client-${i}"

    pid=$(run_dhcp_client "${ns}" "${veth}" "${i}")
    CLIENT_PIDS+=("${pid}")

    # Small delay between clients
    sleep 1
done

log_info ""
log_info "Waiting for DHCP clients to complete handshake..."
log_info ""

# Wait for all clients
for i in $(seq 1 "${NUM_CLIENTS}"); do
    pid="${CLIENT_PIDS[$((i-1))]}"
    log_file="/tmp/dhcp-client-${i}.log"
    lease_file="/tmp/dhcp-lease-${i}.lease"

        if wait "${pid}" 2>/dev/null; then
        # Check if we got a lease
        if [ -f "${log_file}" ] && grep -qE "DHCPACK|bound to" "${log_file}"; then
            # Extract IP from log or lease file
            client_ip=""
            if [ -f "${lease_file}" ]; then
                client_ip=$(grep -E "fixed-address|lease.*address" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            fi

            if [ -z "${client_ip}" ] && [ -f "${log_file}" ]; then
                client_ip=$(grep -oP "DHCPACK of \K[0-9.]+" "${log_file}" | head -1 || echo "")
            fi

            if [ -n "${client_ip}" ]; then
                log_success "Client ${i}: Got IP ${client_ip}"
            else
                log_info "Client ${i}: Got lease but couldn't extract IP"
            fi
        else
            log_error "Client ${i}: Failed to get DHCP lease"
        fi
    else
        log_error "Client ${i}: Process failed or timed out"
    fi
done

log_info ""
log_step "Checking Kea leases in database..."

# Check PostgreSQL for active leases
if command -v podman >/dev/null 2>&1; then
    if podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-postgresql"; then
        log_info "Querying PostgreSQL for active leases..."
        podman exec ztpbootstrap-postgresql psql -U kea -d kea -c \
            "SELECT address, encode(hwaddr, 'hex') as mac_address, expire, hostname FROM lease4 WHERE expire > NOW() ORDER BY expire DESC;" 2>&1 | \
            grep -v "^-" | grep -v "rows)" | tail -n +3 || log_info "No active leases found"
    else
        log_info "PostgreSQL container not running, skipping database check"
    fi
fi

log_info ""
log_step "Checking Kea logs for DHCPACK messages..."

if command -v podman >/dev/null 2>&1; then
    if podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-dhcp"; then
        log_info "Recent DHCPACK messages:"
        podman logs ztpbootstrap-dhcp 2>&1 | grep -i "dhcpack\|lease.*allocated\|lease.*granted" | tail -10 || log_info "No DHCPACK messages found"
    fi
fi

log_info ""
log_success "DHCP client simulation complete!"
log_info "=========================================="
