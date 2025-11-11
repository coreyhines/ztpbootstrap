#!/bin/sh
# Start Web UI Flask application
# This script should be run inside the container

set -euo pipefail

# Install dependencies from requirements.txt if needed
# Note: systemd-python requires build dependencies (pkg-config, gcc, etc.) which aren't in alpine
# If systemd integration is needed, install build dependencies first or use a different base image
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
