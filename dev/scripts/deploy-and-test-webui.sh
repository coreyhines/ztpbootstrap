#!/bin/bash
# Deploy updated webui code to VM and test login
# Assumes VM is accessible at localhost:2222

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

# VM connection details
VM_HOST="${VM_HOST:-localhost}"
VM_PORT="${VM_PORT:-2222}"
VM_USER="${VM_USER:-$(whoami)}"
VM_REPO_DIR="${VM_REPO_DIR:-~/ztpbootstrap}"

log_info "Deploying updated webui code to VM..."
log_info "  VM: ${VM_USER}@${VM_HOST}:${VM_PORT}"
log_info "  Repo: ${VM_REPO_DIR}"

# Check SSH connection
log_info "Checking SSH connection..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" "echo 'SSH OK'" 2>/dev/null; then
    log_error "Cannot connect to VM. Is it running?"
    log_info "Try: ssh ${VM_USER}@${VM_HOST} -p ${VM_PORT}"
    exit 1
fi

log_info "✓ SSH connection OK"

# Copy updated files to VM
log_info "Copying updated files to VM..."

# Ensure directory structure exists on VM
ssh -o StrictHostKeyChecking=no -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" "mkdir -p ${VM_REPO_DIR}/webui/templates" || {
    log_error "Failed to create directories on VM"
    exit 1
}

# Files to copy
FILES_TO_COPY=(
    "webui/app.py"
    "webui/templates/index.html"
    "webui/dhcp_deploy.py"
)

for file in "${FILES_TO_COPY[@]}"; do
    local_file="${REPO_ROOT}/${file}"
    remote_file="${VM_REPO_DIR}/${file}"

    if [[ ! -f "${local_file}" ]]; then
        log_warn "File not found: ${local_file}"
        continue
    fi

    log_info "  Copying ${file}..."
    scp -P "${VM_PORT}" -o StrictHostKeyChecking=no "${local_file}" "${VM_USER}@${VM_HOST}:${remote_file}" || {
        log_error "Failed to copy ${file}"
        exit 1
    }
done

log_info "✓ Files copied"

# Also copy to container's mounted directory if it exists
log_info "Copying files to container mount directory..."
ssh -o StrictHostKeyChecking=no -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" << 'ENDSSH'
    CONTAINER_DIR="/opt/containerdata/ztpbootstrap/webui"
    if [[ -d "${CONTAINER_DIR}" ]]; then
        sudo mkdir -p "${CONTAINER_DIR}/templates"
        sudo cp ~/ztpbootstrap/webui/app.py "${CONTAINER_DIR}/app.py" 2>/dev/null || true
        sudo cp ~/ztpbootstrap/webui/templates/index.html "${CONTAINER_DIR}/templates/index.html" 2>/dev/null || true
        sudo cp ~/ztpbootstrap/webui/dhcp_deploy.py "${CONTAINER_DIR}/dhcp_deploy.py" 2>/dev/null || true
        echo "✓ Files copied to container directory"
    else
        echo "⚠ Container directory not found, will copy from repo on restart"
    fi
ENDSSH

# Restart webui service on VM
log_info "Restarting webui service on VM..."
ssh -o StrictHostKeyChecking=no -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" << 'ENDSSH'
    sudo systemctl restart ztpbootstrap-webui || {
        echo "Failed to restart webui service"
        exit 1
    }
    echo "✓ WebUI service restarted"

    # Wait for service to be ready
    echo "Waiting for WebUI to be ready..."
    for i in {1..30}; do
        if curl -s --connect-timeout 2 --max-time 5 http://localhost:5000/api/health >/dev/null 2>&1; then
            echo "✓ WebUI is ready on port 5000"
            exit 0
        elif curl -s --connect-timeout 2 --max-time 5 http://localhost:8080/api/health >/dev/null 2>&1; then
            echo "✓ WebUI is ready on port 8080"
            exit 0
        fi
        sleep 1
    done
    echo "⚠ WebUI did not become ready after 30 seconds"
    exit 1
ENDSSH

if [[ $? -eq 0 ]]; then
    log_info "✓ WebUI service restarted and ready"
else
    log_error "Failed to restart WebUI service"
    exit 1
fi

# Test login
log_info "Testing login with password 'admin'..."
WEBUI_URL="http://${VM_HOST}:5000"
if ! curl -s --connect-timeout 2 --max-time 5 "${WEBUI_URL}/api/health" >/dev/null 2>&1; then
    WEBUI_URL="http://${VM_HOST}:8080"
fi

log_info "WebUI URL: ${WEBUI_URL}"

# Test authentication endpoint
LOGIN_RESPONSE=$(curl -s -X POST "${WEBUI_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"password":"admin"}' \
    -c /tmp/webui_cookies.txt \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "${LOGIN_RESPONSE}" | tail -1)
RESPONSE_BODY=$(echo "${LOGIN_RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" == "200" ]] || [[ "${HTTP_CODE}" == "201" ]]; then
    if echo "${RESPONSE_BODY}" | grep -q '"success".*true'; then
        log_info "✓ Login successful!"
        log_info "  Response: ${RESPONSE_BODY}"

        # Test authenticated endpoint
        log_info "Testing authenticated endpoint..."
        AUTH_RESPONSE=$(curl -s -X GET "${WEBUI_URL}/api/config" \
            -b /tmp/webui_cookies.txt \
            -w "\n%{http_code}")

        AUTH_HTTP_CODE=$(echo "${AUTH_RESPONSE}" | tail -1)
        AUTH_RESPONSE_BODY=$(echo "${AUTH_RESPONSE}" | sed '$d')
        if [[ "${AUTH_HTTP_CODE}" == "200" ]]; then
            log_info "✓ Authenticated endpoint access successful!"
        elif [[ "${AUTH_HTTP_CODE}" == "401" ]]; then
            log_error "✗ Authentication failed - got 401 on protected endpoint"
            log_info "  Response: ${AUTH_RESPONSE_BODY}"
        else
            log_warn "⚠ Unexpected response code: ${AUTH_HTTP_CODE}"
        fi
    else
        log_error "✗ Login failed - response does not indicate success"
        log_info "  Response: ${RESPONSE_BODY}"
    fi
else
    log_error "✗ Login failed - HTTP ${HTTP_CODE}"
    log_info "  Response: ${RESPONSE_BODY}"
fi

log_info ""
log_info "========================================="
log_info "Deployment complete!"
log_info "========================================="
log_info "WebUI URL: ${WEBUI_URL}"
log_info "You can now test in your browser:"
log_info "  1. Open ${WEBUI_URL}"
log_info "  2. Try to upload a script or access a protected feature"
log_info "  3. Login with password: admin"
log_info "  4. Verify you stay logged in when accessing other protected features"
log_info "========================================="
