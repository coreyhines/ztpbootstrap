#!/bin/sh
# Start Web UI Flask application
# This script should be run inside the container

set -euo pipefail

# Install dependencies if needed (flask, werkzeug, systemd-python)
if ! python3 -c "import flask" 2>/dev/null; then
    pip3 install --no-cache-dir flask werkzeug systemd-python || {
        echo "Warning: Failed to install some dependencies, continuing anyway..."
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
