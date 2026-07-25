#!/bin/sh
# Start Web UI Flask application
# This script should be run inside the container

set -euo pipefail

# Always fix DNS first (common issue in containers with pod networking)
# If using host networking, preserve the host's DNS, otherwise use 8.8.8.8
echo "Configuring DNS..."
if grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
    echo "Using host DNS (systemd-resolved)"
elif ! getent hosts pypi.org >/dev/null 2>&1; then
    echo "DNS not working, configuring fallback..."
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    echo "DNS configured: $(cat /etc/resolv.conf)"
fi

# Ensure ip(8) exists for ZTP Network parent discovery (Fedora base image is minimal)
if ! command -v ip >/dev/null 2>&1; then
    echo "Installing iproute for network discovery..."
    dnf install -y iproute >/dev/null 2>&1 || true
fi

# Change to app directory (mounted at /app)
cd /app || {
    echo "Error: /app directory not found"
    exit 1
}

# Set environment variables
export ZTP_CONFIG_DIR="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}"
export FLASK_APP="${FLASK_APP:-app.py}"
export FLASK_ENV="${FLASK_ENV:-production}"

# Wait a moment for any initialization
sleep 2

# Start Flask app
exec python3 app.py
