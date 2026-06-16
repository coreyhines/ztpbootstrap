#!/bin/bash
# Setup script to prepare VM for UI testing
# This script pulls the branch, runs non-interactive setup, and starts WebUI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if we're on the VM
if [[ ! -f /etc/fedora-release ]] && [[ ! -f /etc/redhat-release ]]; then
    log_warn "This script is intended to run on a Fedora/RHEL VM"
fi

# Set up repository
REPO_DIR="${HOME}/ztpbootstrap"
BRANCH="feature/dhcp-implementation"

log_info "Setting up repository in ${REPO_DIR}..."

if [[ -d "${REPO_DIR}/.git" ]]; then
    log_info "Repository exists, fetching and checking out branch..."
    cd "${REPO_DIR}"
    git fetch origin
    git checkout "${BRANCH}" || git checkout -b "${BRANCH}" origin/"${BRANCH}"
    git pull origin "${BRANCH}" || true
else
    log_info "Cloning repository..."
    cd "${HOME}"
    if [[ -d "${REPO_DIR}" ]]; then
        rm -rf "${REPO_DIR}"
    fi
    git clone https://github.com/arista-netdevops-community/ztpbootstrap.git "${REPO_DIR}"
    cd "${REPO_DIR}"
    git checkout "${BRANCH}" || git checkout -b "${BRANCH}" origin/"${BRANCH}"
fi

log_info "✓ Repository ready at ${REPO_DIR}"

# Install dependencies
log_info "Installing dependencies..."
if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y python3-pip yq podman || true
elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y python3-pip yq podman || true
fi

# Install Python dependencies
if [[ -f "${REPO_DIR}/webui/requirements.txt" ]]; then
    log_info "Installing Python dependencies..."
    pip3 install --user -r "${REPO_DIR}/webui/requirements.txt" || true
fi

cd "${REPO_DIR}"

# Create config.yaml with test values (non-interactive setup)
log_info "Creating config.yaml for non-interactive setup..."

python3 << 'PYTHON_SCRIPT'
import yaml
import sys
import os
import hashlib
import base64

try:
    config_file = 'config.yaml'

    # Start with template if it exists
    config = {}
    if os.path.exists('config.yaml.template'):
        with open('config.yaml.template', 'r') as f:
            config = yaml.safe_load(f) or {}

    # Ensure network section exists
    if 'network' not in config:
        config['network'] = {}

    # Set HTTP-only mode for testing
    config['network']['http_only'] = True
    config['network']['http_port'] = 8080
    config['network']['https_port'] = 8443

    # Set admin password for authentication using a securely salted hash
    from werkzeug.security import generate_password_hash

    test_password = "admin"
    password_hash = generate_password_hash(test_password)

    if 'auth' not in config:
        config['auth'] = {}
    config['auth']['admin_password_hash'] = password_hash

    # Ensure container section exists
    if 'container' not in config:
        config['container'] = {}

    # Set container config for host networking
    config['container']['host_network'] = True

    # Ensure cvaas section exists with dummy token for testing
    if 'cvaas' not in config:
        config['cvaas'] = {}

    config['cvaas']['address'] = 'www.arista.io'
    config['cvaas']['enrollment_token'] = 'arista'

    # Write config back
    with open(config_file, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

    print(f"✓ Created config.yaml with test values")
    print(f"  - HTTP port: {config['network'].get('http_port', 8080)}")
    print(f"  - Host networking: {config['container'].get('host_network', False)}")
    print(f"  - Enrollment token: {config['cvaas'].get('enrollment_token', '')[:20]}...")

except Exception as e:
    print(f"Error configuring config.yaml: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT

# Run setup script (non-interactive)
log_info "Running non-interactive setup..."
export NON_INTERACTIVE=true
export ENROLLMENT_TOKEN="arista"

# Extract admin_password_hash from config.yaml
ADMIN_PASSWORD_HASH_FROM_CONFIG=$(python3 -c "import yaml; f=open('config.yaml'); c=yaml.safe_load(f); f.close(); print(c.get('auth', {}).get('admin_password_hash', '') or '')" 2>/dev/null || echo "")
if [[ -n "$ADMIN_PASSWORD_HASH_FROM_CONFIG" ]]; then
    export ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH_FROM_CONFIG"
    log_info "✓ Found admin_password_hash in config.yaml"
fi

# Run setup
if sudo -E bash ./setup-interactive.sh; then
    log_info "✓ Setup completed successfully"
else
    setup_exit=$?
    log_warn "Setup exit code was ${setup_exit}, checking if systemd files exist..."
    if [[ -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod ]]; then
        log_info "✓ Systemd files exist (setup succeeded despite exit code)"
    else
        log_error "Setup failed and systemd files not found"
        exit 1
    fi
fi

# Verify and fix host networking in pod file
log_info "Verifying host networking configuration..."
if [[ -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod ]]; then
    if ! grep -q "^Network=host" /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod; then
        log_info "Fixing pod file to use host networking..."
        sudo sed -i 's/^Network=.*/Network=host/' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
        sudo sed -i '/^IP=/d' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
        sudo sed -i '/^IP6=/d' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
        sudo systemctl daemon-reload
        log_info "✓ Pod file updated for host networking"
    else
        log_info "✓ Pod file already configured for host networking"
    fi
fi

# Ensure admin_password_hash is set in final config
log_info "Verifying authentication configuration..."
if [[ -n "$ADMIN_PASSWORD_HASH_FROM_CONFIG" ]] && [[ -f /opt/containerdata/ztpbootstrap/config.yaml ]]; then
    if command -v yq >/dev/null 2>&1; then
        sudo yq eval '.auth = (.auth // {})' -i /opt/containerdata/ztpbootstrap/config.yaml
        sudo yq eval ".auth.admin_password_hash = \"${ADMIN_PASSWORD_HASH_FROM_CONFIG}\"" -i /opt/containerdata/ztpbootstrap/config.yaml
        log_info "✓ Set admin_password_hash in final config"
    fi
fi

# Start services
log_info "Starting ZTP Bootstrap services..."
sudo systemctl daemon-reload
sudo systemctl enable ztpbootstrap-pod ztpbootstrap-webui || true
sudo systemctl start ztpbootstrap-pod || true
sleep 2
sudo systemctl start ztpbootstrap-webui || true

# Wait for WebUI to be ready
log_info "Waiting for WebUI to be ready..."
for i in {1..30}; do
    if curl -s --connect-timeout 2 --max-time 5 http://localhost:5000/api/health >/dev/null 2>&1; then
        log_info "✓ WebUI is ready on port 5000"
        break
    elif curl -s --connect-timeout 2 --max-time 5 http://localhost:8080/api/health >/dev/null 2>&1; then
        log_info "✓ WebUI is ready on port 8080"
        break
    fi
    sleep 2
    if [[ $i -eq 30 ]]; then
        log_warn "WebUI did not become ready after 60 seconds"
        log_info "Checking service status..."
        sudo systemctl status ztpbootstrap-webui --no-pager -l | head -10
    fi
done

# Show status
log_info "Service status:"
sudo systemctl is-active ztpbootstrap-pod && echo "  ✓ ztpbootstrap-pod: active" || echo "  ✗ ztpbootstrap-pod: inactive"
sudo systemctl is-active ztpbootstrap-webui && echo "  ✓ ztpbootstrap-webui: active" || echo "  ✗ ztpbootstrap-webui: inactive"

log_info ""
log_info "========================================="
log_info "Setup complete!"
log_info "========================================="
log_info "WebUI should be accessible at:"
log_info "  - http://localhost:5000 (direct)"
log_info "  - http://localhost:8080 (via nginx, if enabled)"
log_info ""
log_info "Default credentials:"
log_info "  Password: admin"
log_info ""
log_info "To check status: sudo systemctl status ztpbootstrap-webui"
log_info "To view logs: sudo podman logs ztpbootstrap-webui"
log_info "========================================="
