#!/bin/bash
# Simulate multiple DHCP clients using Podman containers with host networking
# This completes the full DHCP handshake (DISCOVER, OFFER, REQUEST, ACK)

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

cleanup() {
    log_info "Cleaning up DHCP client containers..."
    for i in $(seq 1 "${NUM_CLIENTS}"); do
        local container="dhcp-client-${i}"
        if podman ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            podman stop "${container}" 2>/dev/null || true
            podman rm "${container}" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

log_info "=========================================="
log_info "DHCP Client Simulation (Podman)"
log_info "=========================================="
log_info "Number of clients: ${NUM_CLIENTS}"
log_info "Timeout: ${TIMEOUT}s"
log_info ""

# Check if podman is available
if ! command -v podman >/dev/null 2>&1; then
    log_error "podman is not available"
    exit 1
fi

# Check if dhclient is available in the container image
log_step "Checking for suitable container image..."

# Use fedora:latest or alpine:latest - both should have dhclient or udhcpc
CONTAINER_IMAGE="fedora:latest"
if ! podman image exists "${CONTAINER_IMAGE}" 2>/dev/null; then
    log_info "Pulling container image ${CONTAINER_IMAGE}..."
    podman pull "${CONTAINER_IMAGE}" || {
        log_error "Failed to pull ${CONTAINER_IMAGE}, trying alpine:latest..."
        CONTAINER_IMAGE="alpine:latest"
        podman pull "${CONTAINER_IMAGE}" || {
            log_error "Failed to pull container image"
            exit 1
        }
    }
fi

log_info ""
log_step "Starting DHCP clients in Podman containers..."

# Function to run a DHCP client in a container
run_dhcp_client() {
    local client_num="$1"
    local container="dhcp-client-${client_num}"
    local mac="02:00:00:00:00:$(printf "%02x" "${client_num}")"
    local lease_file="/tmp/dhcp-lease-${client_num}.lease"
    local log_file="/tmp/dhcp-client-${client_num}.log"

    log_info "Starting client ${client_num} (MAC: ${mac})..."

    # Remove container if it exists
    podman rm -f "${container}" 2>/dev/null || true

    # Determine which DHCP client to use based on image
    local dhcp_client="dhclient"
    if [[ "${CONTAINER_IMAGE}" == *"alpine"* ]]; then
        dhcp_client="udhcpc"
    fi

    # Start container with host networking
    # For Alpine, we'll need to install udhcpc or use busybox's built-in
    if [[ "${CONTAINER_IMAGE}" == *"alpine"* ]]; then
        # Alpine has udhcpc in busybox
        podman run -d --name "${container}" \
            --network host \
            --mac-address "${mac}" \
            "${CONTAINER_IMAGE}" \
            sh -c "apk add --no-cache dhcpcd 2>/dev/null || true; \
                   udhcpc -i eth0 -f -q -t 5 -T 3 2>&1 || \
                   (if command -v dhcpcd >/dev/null 2>&1; then dhcpcd -n eth0 2>&1; fi)" \
            > "${log_file}" 2>&1 || true
    else
        # Fedora should have dhclient
        podman run -d --name "${container}" \
            --network host \
            --mac-address "${mac}" \
            "${CONTAINER_IMAGE}" \
            bash -c "dnf install -y dhcp-client 2>/dev/null || yum install -y dhcp 2>/dev/null || true; \
                     timeout ${TIMEOUT} dhclient -v -lf ${lease_file} eth0 2>&1 || true" \
            > "${log_file}" 2>&1 || true
    fi

    echo "${container}"
}

# Start all clients
declare -a CLIENT_CONTAINERS=()
for i in $(seq 1 "${NUM_CLIENTS}"); do
    container=$(run_dhcp_client "${i}")
    CLIENT_CONTAINERS+=("${container}")

    # Small delay between clients
    sleep 2
done

log_info ""
log_info "Waiting for DHCP clients to complete handshake (${TIMEOUT}s)..."
log_info ""

# Wait for clients to finish
sleep "${TIMEOUT}"

# Check results
log_step "Checking DHCP client results..."

for i in $(seq 1 "${NUM_CLIENTS}"); do
    container="${CLIENT_CONTAINERS[$((i-1))]}"
    log_file="/tmp/dhcp-client-${i}.log"
    lease_file="/tmp/dhcp-lease-${i}.lease"

    # Get container logs
    if podman ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        podman logs "${container}" 2>&1 >> "${log_file}" || true

        # Check if we got a lease
        if grep -qE "DHCPACK|bound to|lease obtained|Lease of" "${log_file}" 2>/dev/null; then
            # Try to extract IP
            client_ip=""
            if [ -f "${lease_file}" ]; then
                client_ip=$(grep -E "fixed-address|lease.*address" "${lease_file}" | head -1 | awk '{print $2}' | tr -d ';' || echo "")
            fi

            if [ -z "${client_ip}" ]; then
                client_ip=$(grep -oP "DHCPACK of \K[0-9.]+" "${log_file}" | head -1 || echo "")
            fi

            if [ -z "${client_ip}" ]; then
                client_ip=$(grep -oP "bound to \K[0-9.]+" "${log_file}" | head -1 || echo "")
            fi

            if [ -n "${client_ip}" ]; then
                log_success "Client ${i}: Got IP ${client_ip}"
            else
                log_info "Client ${i}: Got lease but couldn't extract IP"
            fi
        else
            log_error "Client ${i}: Failed to get DHCP lease"
            log_info "  Last few log lines:"
            tail -3 "${log_file}" 2>/dev/null | sed 's/^/    /' || true
        fi
    else
        log_error "Client ${i}: Container not found"
    fi
done

log_info ""
log_step "Checking Kea leases in database..."

# Check PostgreSQL for active leases
if podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-postgresql"; then
    log_info "Querying PostgreSQL for active leases..."
    podman exec ztpbootstrap-postgresql psql -U kea -d kea -c \
        "SELECT address, encode(hwaddr, 'hex') as mac_address, expire, hostname FROM lease4 WHERE expire > NOW() ORDER BY expire DESC;" 2>&1 | \
        grep -v "^-" | grep -v "rows)" | tail -n +3 || log_info "No active leases found"
else
    log_info "PostgreSQL container not running, skipping database check"
fi

log_info ""
log_step "Checking Kea logs for DHCPACK messages..."

if podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-dhcp"; then
    log_info "Recent DHCPACK messages:"
    podman logs ztpbootstrap-dhcp 2>&1 | grep -iE "dhcpack|lease.*allocated|lease.*granted" | tail -10 || log_info "No DHCPACK messages found"

    log_info ""
    log_info "Recent DHCP activity:"
    podman logs ztpbootstrap-dhcp 2>&1 | grep -iE "dhcpdiscover|dhcpoffer|dhcprequest|dhcpack" | tail -20 || log_info "No DHCP activity found"
fi

log_info ""
log_success "DHCP client simulation complete!"
log_info "=========================================="
