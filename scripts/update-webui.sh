#!/bin/bash
# Update webui files after pulling git changes
# This copies the webui directory from the repo to the installation location

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Get script_dir from config.yaml or use default
CONFIG_FILE="${REPO_DIR}/config.yaml"
if [[ -f "$CONFIG_FILE" ]] && command -v yq >/dev/null 2>&1; then
    SCRIPT_DIR_INSTALL=$(yq eval '.paths.script_dir // "/opt/containerdata/ztpbootstrap"' "$CONFIG_FILE" 2>/dev/null || echo "/opt/containerdata/ztpbootstrap")
else
    SCRIPT_DIR_INSTALL="/opt/containerdata/ztpbootstrap"
fi

WEBUI_SOURCE="${REPO_DIR}/webui"
WEBUI_DEST="${SCRIPT_DIR_INSTALL}/webui"

if [[ ! -d "$WEBUI_SOURCE" ]]; then
    echo "ERROR: Web UI source directory not found: $WEBUI_SOURCE" >&2
    exit 1
fi

if [[ ! -d "$WEBUI_DEST" ]]; then
    echo "ERROR: Web UI destination directory not found: $WEBUI_DEST" >&2
    echo "Please run setup-interactive.sh first to create the installation." >&2
    exit 1
fi

echo "Updating Web UI files..."
echo "  Source: $WEBUI_SOURCE"
echo "  Destination: $WEBUI_DEST"

# Copy webui files
if [[ $EUID -eq 0 ]]; then
    cp -r "${WEBUI_SOURCE}"/* "$WEBUI_DEST/" 2>/dev/null || {
        echo "ERROR: Failed to copy webui directory" >&2
        exit 1
    }
    # Ensure start-webui.sh is executable
    if [[ -f "${WEBUI_DEST}/start-webui.sh" ]]; then
        chmod +x "${WEBUI_DEST}/start-webui.sh" 2>/dev/null || true
    fi
else
    sudo cp -r "${WEBUI_SOURCE}"/* "$WEBUI_DEST/" 2>/dev/null || {
        echo "ERROR: Failed to copy webui directory" >&2
        exit 1
    }
    # Ensure start-webui.sh is executable
    if [[ -f "${WEBUI_DEST}/start-webui.sh" ]]; then
        sudo chmod +x "${WEBUI_DEST}/start-webui.sh" 2>/dev/null || true
    fi
fi

echo "✓ Web UI files updated successfully"
echo ""
echo "Restarting webui service..."

if [[ $EUID -eq 0 ]]; then
    systemctl restart ztpbootstrap-webui.service 2>/dev/null || {
        echo "WARNING: Failed to restart webui service. You may need to restart it manually:" >&2
        echo "  sudo systemctl restart ztpbootstrap-webui.service" >&2
        exit 1
    }
else
    sudo systemctl restart ztpbootstrap-webui.service 2>/dev/null || {
        echo "WARNING: Failed to restart webui service. You may need to restart it manually:" >&2
        echo "  sudo systemctl restart ztpbootstrap-webui.service" >&2
        exit 1
    }
fi

echo "✓ Web UI service restarted"
echo ""
echo "Web UI has been updated and restarted successfully!"

