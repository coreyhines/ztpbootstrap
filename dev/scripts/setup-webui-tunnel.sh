#!/bin/bash
# Setup SSH tunnel to access web UI when pod is on macvlan network
# This script creates a tunnel through the VM to access the web UI container

set -euo pipefail

VM_USER="${VM_USER:-fedora}"
VM_HOST="${VM_HOST:-localhost}"
VM_PORT="${VM_PORT:-2222}"
LOCAL_PORT="${LOCAL_PORT:-8080}"

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

# Kill existing tunnel
cleanup() {
    log_info "Cleaning up existing tunnels..."
    pkill -f "ssh.*${LOCAL_PORT}.*${VM_HOST}" 2>/dev/null || true
}

# Get web UI container IP
get_webui_ip() {
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "sudo podman inspect ztpbootstrap-webui --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1" 2>/dev/null || echo ""
}

# Get web UI port (check if nginx is used or direct Flask)
get_webui_port() {
    # Check if nginx is running and proxying
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "sudo systemctl is-active ztpbootstrap-nginx >/dev/null 2>&1" 2>/dev/null; then
        echo "80"
    else
        echo "5000"
    fi
}

main() {
    log_info "Setting up SSH tunnel for web UI access..."
    log_info "VM: ${VM_USER}@${VM_HOST}:${VM_PORT}"

    # Cleanup existing tunnels
    cleanup
    sleep 1

    # Get container IP and port
    log_info "Discovering web UI container..."
    WEBUI_IP=$(get_webui_ip)
    WEBUI_PORT=$(get_webui_port)

    if [[ -z "${WEBUI_IP}" ]]; then
        log_error "Could not find web UI container IP"
        exit 1
    fi

    log_info "Web UI container IP: ${WEBUI_IP}"
    log_info "Web UI port: ${WEBUI_PORT}"

    # Try method 1: Direct tunnel to container IP (if VM can route to it)
    log_info "Attempting direct tunnel to container..."
    if ssh -L "${LOCAL_PORT}:${WEBUI_IP}:${WEBUI_PORT}" -N -f \
        -o StrictHostKeyChecking=no \
        -o ExitOnForwardFailure=yes \
        "${VM_USER}@${VM_HOST}" -p "${VM_PORT}" 2>/dev/null; then
        sleep 2
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/ui" | grep -q "200\|30"; then
            log_info "✓ Tunnel established successfully!"
            log_info "Web UI available at: http://localhost:${LOCAL_PORT}/ui"
            exit 0
        fi
    fi

    # Method 2: Use socat on VM to forward port
    log_info "Trying alternative method with socat..."
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "which socat >/dev/null 2>&1 || (dnf install -y -q socat >/dev/null 2>&1 || yum install -y -q socat >/dev/null 2>&1)" 2>/dev/null || true

    # Forward through VM's localhost using socat
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
        "socat TCP-LISTEN:9000,fork,reuseaddr TCP:${WEBUI_IP}:${WEBUI_PORT} &" 2>/dev/null || true

    sleep 2

    # Tunnel to VM's socat listener
    if ssh -L "${LOCAL_PORT}:localhost:9000" -N -f \
        -o StrictHostKeyChecking=no \
        -o ExitOnForwardFailure=yes \
        "${VM_USER}@${VM_HOST}" -p "${VM_PORT}" 2>/dev/null; then
        sleep 2
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/ui" | grep -q "200\|30"; then
            log_info "✓ Tunnel established via socat!"
            log_info "Web UI available at: http://localhost:${LOCAL_PORT}/ui"
            exit 0
        fi
    fi

    log_error "Failed to establish tunnel"
    log_info "You can try manually:"
    log_info "  ssh -L ${LOCAL_PORT}:${WEBUI_IP}:${WEBUI_PORT} -N ${VM_USER}@${VM_HOST} -p ${VM_PORT}"
    exit 1
}

# Handle script termination
trap cleanup EXIT

main "$@"
