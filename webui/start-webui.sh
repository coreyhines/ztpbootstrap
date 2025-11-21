#!/bin/sh
# Start Web UI Flask application
# This script should be run inside the container

set -euo pipefail

# Install system packages needed (Python, podman, journalctl)
# These are installed in the container rather than mounted from host for better compatibility
# Note: If using a pre-built image (see webui/Containerfile), packages will already be installed
# and this step will be skipped, resulting in much faster startup times.
if ! command -v python3 >/dev/null 2>&1 || ! command -v podman >/dev/null 2>&1 || ! command -v journalctl >/dev/null 2>&1; then
    echo "Installing Python, podman, systemd, and dependencies..."
    echo "Note: This is a one-time installation. Consider building a local image (see webui/README-IMAGE-BUILD.md) for faster startups."
    if ! dnf install -y -q python3 python3-pip podman systemd 2>&1; then
        echo "Error: Failed to install required packages. Cannot continue."
        exit 1
    fi
fi

# Install Python dependencies from requirements.txt if needed
# Note: Using Fedora-based image for native compatibility with host binaries
if [ -f /app/requirements.txt ]; then
    pip3 install --no-cache-dir -r /app/requirements.txt || {
        echo "Error: Failed to install dependencies from requirements.txt. Cannot continue."
        exit 1
    }
elif ! python3 -c "import flask" 2>/dev/null; then
    # Fallback: install flask and werkzeug if requirements.txt doesn't exist
    pip3 install --no-cache-dir flask werkzeug || {
        echo "Error: Failed to install flask or werkzeug. Cannot continue."
        exit 1
    }
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
