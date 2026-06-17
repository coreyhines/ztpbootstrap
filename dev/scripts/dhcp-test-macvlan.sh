#!/bin/bash
# Test DHCP clients on macvlan network
# Creates Podman containers connected to the ztpbootstrap-net macvlan network

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
NETWORK_NAME="${NETWORK_NAME:-ztpbootstrap-net}"
NUM_CLIENTS="${NUM_CLIENTS:-3}"
TIMEOUT="${TIMEOUT:-30}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-registry.fedoraproject.org/fedora:latest}"

cleanup() {
    log_info "Cleaning up DHCP client containers..."
    for i in $(seq 1 "${NUM_CLIENTS}"); do
        local container="dhcp-client-macvlan-${i}"
        if podman ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            podman stop "${container}" 2>/dev/null || true
            podman rm "${container}" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT

# Check if network exists
check_network() {
    if ! podman network exists "${NETWORK_NAME}" 2>/dev/null; then
        log_error "Macvlan network '${NETWORK_NAME}' does not exist!"
        log_info "Create it with: sudo ./setup-dhcp-testing.sh"
        exit 1
    fi

    log_info "✓ Found macvlan network: ${NETWORK_NAME}"

    # Get network info
    local network_info=$(podman network inspect "${NETWORK_NAME}" 2>/dev/null || echo "")
    if echo "${network_info}" | grep -q "macvlan"; then
        log_info "✓ Network type: macvlan"
    fi
}

# Check if DHCP server is running
check_dhcp_server() {
    log_step "Checking DHCP server status..."

    if podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-dhcp"; then
        log_info "✓ DHCP container is running"
    elif systemctl is-active --quiet ztpbootstrap-dhcp 2>/dev/null; then
        log_info "✓ DHCP service is active"
    else
        log_warn "DHCP server may not be running"
        log_info "Start it with: sudo systemctl start ztpbootstrap-dhcp"
    fi
}

# Function to run a DHCP client in a container on macvlan network
run_dhcp_client() {
    local client_num="$1"
    local container="dhcp-client-macvlan-${client_num}"
    local mac="02:00:00:00:00:$(printf "%02x" "${client_num}")"
    local log_file="/tmp/dhcp-client-macvlan-${client_num}.log"

    log_info "Starting client ${client_num} (MAC: ${mac}) on macvlan network..."

    # Remove container if it exists
    podman rm -f "${container}" 2>/dev/null || true

    # Start container on macvlan network
    # The container will run dhclient and then keep running
    local container_id=$(podman run -d --name "${container}" \
        --network "${NETWORK_NAME}" \
        --mac-address "${mac}" \
        "${CONTAINER_IMAGE}" \
        bash -c "
            set -e
            echo \"=== DHCP Client ${client_num} (MAC: ${mac}) ===\"

            # Install DHCP client
            echo \"Installing DHCP client...\"
            dnf install -y -q dhcp-client 2>/dev/null || \
            yum install -y -q dhcp 2>/dev/null || \
            (echo 'Failed to install dhcp-client' && sleep 60 && exit 1)

            # Find the interface (usually eth0 on macvlan)
            INTERFACE=\$(ip route | grep default | awk '{print \$5}' | head -1)
            if [ -z \"\${INTERFACE}\" ]; then
                INTERFACE=\$(ip link show | grep -E '^[0-9]+: eth' | head -1 | cut -d: -f2 | tr -d ' ')
            fi
            if [ -z \"\${INTERFACE}\" ]; then
                INTERFACE=eth0
            fi

            echo \"Using interface: \${INTERFACE}\"
            ip link show \${INTERFACE}

            # Release any existing lease first
            dhclient -r \${INTERFACE} 2>/dev/null || true
            sleep 1

            echo \"Requesting DHCP lease...\"

            # Request DHCP lease with timeout
            if timeout ${TIMEOUT} dhclient -v -1 -lf /tmp/dhcp.lease \${INTERFACE} 2>&1; then
                echo \"✓ DHCP lease obtained!\"

                # Wait a moment for lease to be processed
                sleep 2

                echo \"Lease file contents:\"
                cat /tmp/dhcp.lease 2>/dev/null || echo \"No lease file\"

                echo \"Interface configuration:\"
                ip addr show \${INTERFACE}

                echo \"Routing table:\"
                ip route show
            else
                echo \"✗ DHCP request failed or timed out\"
                exit 1
            fi

            # Keep container running for inspection
            echo \"Container will stay running for ${TIMEOUT} seconds...\"
            sleep ${TIMEOUT}
        " 2>&1) || true

    # Wait a moment for container to start
    sleep 2

    # Check if container is running
    if podman ps --format "{{.Names}}" | grep -q "^${container}$"; then
        log_info "  Container started successfully"
    elif podman ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        log_warn "  Container exited immediately (check logs)"
        podman logs "${container}" 2>&1 | head -20 >> "${log_file}" || true
    else
        log_error "  Failed to create container"
    fi

    echo "${container}"
}

# Main function
main() {
    log_info "=========================================="
    log_info "DHCP Client Test on Macvlan Network"
    log_info "=========================================="
    log_info "Network: ${NETWORK_NAME}"
    log_info "Number of clients: ${NUM_CLIENTS}"
    log_info "Timeout: ${TIMEOUT}s"
    log_info ""

    # Check prerequisites
    if ! command -v podman >/dev/null 2>&1; then
        log_error "podman is not available"
        exit 1
    fi

    check_network
    check_dhcp_server

    log_info ""
    log_step "Pulling container image if needed..."
    if ! podman image exists "${CONTAINER_IMAGE}" 2>/dev/null; then
        log_info "Pulling ${CONTAINER_IMAGE}..."
        podman pull "${CONTAINER_IMAGE}" || {
            log_error "Failed to pull container image"
            exit 1
        }
    fi

    log_info ""
    log_step "Starting ${NUM_CLIENTS} DHCP clients on macvlan network..."

    # Start all clients
    declare -a CLIENT_CONTAINERS=()
    for i in $(seq 1 "${NUM_CLIENTS}"); do
        container=$(run_dhcp_client "${i}")
        CLIENT_CONTAINERS+=("${container}")
        sleep 1  # Small delay between clients
    done

    log_info ""
    log_info "Waiting for DHCP clients to complete (${TIMEOUT}s)..."
    log_info ""

    # Wait for clients to finish
    sleep "${TIMEOUT}"

    # Check results
    log_step "Checking DHCP client results..."

    local success_count=0
    for i in $(seq 1 "${NUM_CLIENTS}"); do
        container="${CLIENT_CONTAINERS[$((i-1))]}"
        log_file="/tmp/dhcp-client-macvlan-${i}.log"

        log_info ""
        log_info "Client ${i} (${container}):"

        # Check if container exists (running or stopped)
        if podman ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            # Get container logs
            podman logs "${container}" 2>&1 >> "${log_file}" || true

            # Check container exit code
            exit_code=$(podman inspect "${container}" --format '{{.State.ExitCode}}' 2>/dev/null || echo "-1")

            # Try to get IP from container (if still running or recently stopped)
            client_ip=$(podman exec "${container}" ip addr show 2>/dev/null | grep -oP "inet \K[0-9.]+" | head -1 || echo "")

            # Also check logs for IP
            if [ -z "${client_ip}" ]; then
                client_ip=$(grep -oP "DHCPACK of \K[0-9.]+" "${log_file}" | head -1 || echo "")
            fi
            if [ -z "${client_ip}" ]; then
                client_ip=$(grep -oP "bound to \K[0-9.]+" "${log_file}" | head -1 || echo "")
            fi
            if [ -z "${client_ip}" ]; then
                # Try to get from lease file in container
                client_ip=$(podman exec "${container}" grep -oP "fixed-address \K[0-9.]+" /tmp/dhcp.lease 2>/dev/null | head -1 || echo "")
            fi

            # Check if we got a lease
            if [ -n "${client_ip}" ]; then
                log_info "  ✓ Got IP: ${client_ip}"
                success_count=$((success_count + 1))
            elif grep -qE "DHCPACK|bound to|lease obtained|Lease obtained|✓ DHCP lease obtained" "${log_file}" 2>/dev/null; then
                log_info "  ✓ Got lease (IP extraction failed)"
                success_count=$((success_count + 1))
            elif [ "${exit_code}" = "0" ]; then
                log_info "  ? Container exited with code 0 (check logs)"
                log_info "  Last few log lines:"
                tail -10 "${log_file}" 2>/dev/null | sed 's/^/    /' || true
            else
                log_error "  ✗ Failed to get DHCP lease (exit code: ${exit_code})"
                log_info "  Last few log lines:"
                tail -10 "${log_file}" 2>/dev/null | sed 's/^/    /' || true
            fi
        else
            log_error "  ✗ Container not found"
        fi
    done

    log_info ""
    log_step "Checking Kea leases..."

    # Check Kea container logs for DHCPACK messages
    if podman ps --format "{{.Names}}" | grep -q "ztpbootstrap-dhcp"; then
        log_info "Recent DHCPACK messages from Kea:"
        podman logs ztpbootstrap-dhcp 2>&1 | grep -i "dhcpack" | tail -10 || log_info "  No DHCPACK messages found"

        log_info ""
        log_info "Recent DHCP activity from Kea:"
        podman logs ztpbootstrap-dhcp 2>&1 | grep -iE "dhcpdiscover|dhcpoffer|dhcprequest|dhcpack" | tail -20 || log_info "  No DHCP activity found"
    fi

    log_info ""
    if [ "${success_count}" -eq "${NUM_CLIENTS}" ]; then
        log_info "=========================================="
        log_info "✓ All ${NUM_CLIENTS} clients got DHCP leases!"
        log_info "=========================================="
        exit 0
    elif [ "${success_count}" -gt 0 ]; then
        log_warn "=========================================="
        log_warn "⚠ ${success_count}/${NUM_CLIENTS} clients got DHCP leases"
        log_warn "=========================================="
        exit 1
    else
        log_error "=========================================="
        log_error "✗ No clients got DHCP leases"
        log_error "=========================================="
        log_info "Troubleshooting:"
        log_info "1. Check DHCP server logs: sudo podman logs ztpbootstrap-dhcp"
        log_info "2. Check DHCP service: sudo systemctl status ztpbootstrap-dhcp"
        log_info "3. Verify network: sudo podman network inspect ${NETWORK_NAME}"
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
