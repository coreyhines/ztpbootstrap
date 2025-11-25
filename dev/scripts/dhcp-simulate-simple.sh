#!/bin/bash
# Simple DHCP client simulation using dhclient
# Simulates multiple clients completing the full DHCP handshake

set -euo pipefail

LOG_PREFIX="[DHCP-SIM]"
NUM_CLIENTS="${NUM_CLIENTS:-3}"
TIMEOUT="${TIMEOUT:-15}"

log_info() { echo "${LOG_PREFIX} [INFO] $*"; }
log_step() { echo "${LOG_PREFIX} [STEP] $*"; }
log_success() { echo "${LOG_PREFIX} [SUCCESS] $*"; }
log_error() { echo "${LOG_PREFIX} [ERROR] $*" >&2; }

log_info "=========================================="
log_info "DHCP Client Simulation (Simple)"
log_info "=========================================="
log_info "Number of clients: ${NUM_CLIENTS}"
log_info "Timeout: ${TIMEOUT}s"
log_info ""

# Check if dhclient is available
if ! command -v dhclient >/dev/null 2>&1; then
    log_error "dhclient is not available"
    exit 1
fi

# Get the main interface
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "${INTERFACE}" ]; then
    INTERFACE="eth0"
fi

log_info "Using interface: ${INTERFACE}"
log_info ""

# Function to simulate a single client
simulate_client() {
    local client_num="$1"
    local lease_file="/tmp/dhcp-lease-${client_num}.lease"
    local log_file="/tmp/dhcp-client-${client_num}.log"

    log_info "Client ${client_num}: Starting DHCP handshake..."

    # Release any existing lease first
    sudo dhclient -r "${INTERFACE}" 2>/dev/null || true
    sleep 1

    # Request a new lease
    if timeout "${TIMEOUT}" sudo dhclient -v -lf "${lease_file}" "${INTERFACE}" > "${log_file}" 2>&1; then
        # Check if we got a lease
        if grep -qE "DHCPACK|bound to" "${log_file}"; then
            # Extract IP
            local client_ip=""
            if [ -f "${lease_file}" ]; then
                client_ip=$(grep -E "fixed-address|lease.*address" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            fi

            if [ -z "${client_ip}" ]; then
                client_ip=$(grep -oP "DHCPACK of \K[0-9.]+" "${log_file}" | head -1 || echo "")
            fi

            if [ -z "${client_ip}" ]; then
                client_ip=$(ip -4 addr show "${INTERFACE}" | grep -oP 'inet \K[0-9.]+' | head -1 || echo "")
            fi

            if [ -n "${client_ip}" ]; then
                log_success "Client ${client_num}: Got IP ${client_ip}"
                echo "${client_ip}"
                return 0
            else
                log_error "Client ${client_num}: Got lease but couldn't extract IP"
                return 1
            fi
        else
            log_error "Client ${client_num}: No DHCPACK in output"
            return 1
        fi
    else
        log_error "Client ${client_num}: dhclient failed or timed out"
        return 1
    fi
}

# Simulate clients sequentially
successful=0
declare -a CLIENT_IPS=()

for i in $(seq 1 "${NUM_CLIENTS}"); do
    log_step "Simulating client ${i}/${NUM_CLIENTS}..."

    if client_ip=$(simulate_client "${i}"); then
        CLIENT_IPS+=("${client_ip}")
        ((successful++))
    fi

    # Small delay between clients
    if [ "${i}" -lt "${NUM_CLIENTS}" ]; then
        sleep 2
    fi
done

log_info ""
log_step "Checking Kea leases in database..."

if command -v podman >/dev/null 2>&1 && podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-postgresql"; then
    log_info "Active leases in PostgreSQL:"
    podman exec ztpbootstrap-postgresql psql -U kea -d kea -c \
        "SELECT address, encode(hwaddr, 'hex') as mac_address, expire FROM lease4 WHERE expire > NOW() ORDER BY expire DESC;" 2>&1 | \
        grep -v "^-" | grep -v "rows)" | tail -n +3 || log_info "  No active leases found"
else
    log_info "PostgreSQL container not running, skipping database check"
fi

log_info ""
log_step "Checking Kea logs for DHCPACK messages..."

if command -v podman >/dev/null 2>&1 && podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-dhcp"; then
    log_info "Recent DHCPACK messages:"
    podman logs ztpbootstrap-dhcp 2>&1 | grep -iE "dhcpack|lease.*allocated|lease.*granted" | tail -10 || log_info "  No DHCPACK messages found"

    log_info ""
    log_info "Recent DHCP activity (last 20 messages):"
    podman logs ztpbootstrap-dhcp 2>&1 | grep -iE "dhcpdiscover|dhcpoffer|dhcprequest|dhcpack" | tail -20 || log_info "  No DHCP activity found"
fi

log_info ""
log_info "=========================================="
if [ "${successful}" -eq "${NUM_CLIENTS}" ]; then
    log_success "All ${NUM_CLIENTS} clients completed DHCP handshake!"
    log_info "Client IPs: ${CLIENT_IPS[*]}"
else
    log_info "Summary: ${successful}/${NUM_CLIENTS} clients completed handshake"
    if [ "${successful}" -gt 0 ]; then
        log_info "Successful client IPs: ${CLIENT_IPS[*]}"
    fi
fi
log_info "=========================================="

exit $((NUM_CLIENTS - successful))
