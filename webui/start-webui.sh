#!/bin/bash
# Start Web UI Flask application
# This script should be run inside the container

set -euo pipefail

cd /opt/containerdata/ztpbootstrap/webui || exit 1

# Activate virtual environment if it exists
if [[ -d "venv" ]]; then
    source venv/bin/activate
fi

# Install dependencies if needed
if ! python3 -c "import flask" 2>/dev/null; then
    pip3 install -r requirements.txt --user
fi

# Set environment variables
export ZTP_CONFIG_DIR="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}"
export FLASK_APP=app.py
export FLASK_ENV=production

# Start Flask app
exec python3 app.py
