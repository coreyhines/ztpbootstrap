#!/bin/bash
# Simple script to create SSH tunnel for web UI access
# Run this and keep it running in the background

VM_USER="${VM_USER:-fedora}"
VM_HOST="${VM_HOST:-localhost}"
VM_PORT="${VM_PORT:-2222}"
LOCAL_PORT="${LOCAL_PORT:-8080}"

echo "Setting up web UI tunnel..."
echo "This will forward localhost:${LOCAL_PORT} to the web UI container"
echo ""
echo "Press Ctrl+C to stop the tunnel"
echo ""

# Get web UI container IP and verify it's accessible from within the container
WEBUI_IP=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
    "sudo podman inspect ztpbootstrap-webui --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1" 2>/dev/null)

if [[ -z "${WEBUI_IP}" ]]; then
    echo "Error: Could not find web UI container"
    exit 1
fi

echo "Web UI container IP: ${WEBUI_IP}"
echo ""

# Use podman exec to create a port forward inside the container's network namespace
# We'll use socat inside the container to forward port 5000 to a port we can tunnel to
echo "Setting up port forward inside container..."
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" \
    "sudo podman exec -d ztpbootstrap-webui sh -c 'which socat >/dev/null 2>&1 || (dnf install -y -q socat 2>/dev/null || yum install -y -q socat 2>/dev/null); socat TCP-LISTEN:9000,fork,reuseaddr TCP:localhost:5000' 2>/dev/null" || true

sleep 2

# Now tunnel to the container's port 9000
echo "Creating SSH tunnel..."
echo "Web UI will be available at: http://localhost:${LOCAL_PORT}/ui"
echo ""

ssh -L "${LOCAL_PORT}:localhost:9000" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    "${VM_USER}@${VM_HOST}" -p "${VM_PORT}" \
    "echo 'Tunnel established. Web UI accessible on host at localhost:${LOCAL_PORT}'; sleep infinity"
