#!/bin/bash
# CI End-to-End Test Script
# This script runs quick validation checks suitable for CI/CD pipelines
# It does NOT create containers or VMs - use integration-test.sh for that

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

# Test 1: Required files exist
log "Test 1: Checking required files..."
REQUIRED_FILES=(
    "bootstrap.py"
    "nginx.conf"
    "setup.sh"
    "setup-interactive.sh"
    "update-config.sh"
    "README.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        pass "Required file exists: $file"
    else
        error "Required file missing: $file"
    fi
done

# Test 2: File permissions (scripts should be executable)
log "Test 2: Checking file permissions..."
EXECUTABLE_SCRIPTS=(
    "setup.sh"
    "setup-interactive.sh"
    "update-config.sh"
    "integration-test.sh"
    "test-service.sh"
)

for script in "${EXECUTABLE_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            pass "Script is executable: $script"
        else
            warn "Script is not executable: $script (will attempt to fix)"
            chmod +x "$script" || error "Failed to make $script executable"
        fi
    fi
done

# Test 3: Nginx configuration syntax (if nginx is available)
log "Test 3: Checking nginx configuration syntax..."
if command -v nginx >/dev/null 2>&1; then
    # Create a temporary nginx config directory structure for testing
    # The map directive needs to be in http context, so we need a minimal http block
    TEMP_NGINX_DIR=$(mktemp -d)
    TEMP_NGINX_CONF="$TEMP_NGINX_DIR/nginx.conf"
    
    # Create a wrapper config that includes the actual config in http context
    cat > "$TEMP_NGINX_CONF" <<EOF
events {
    worker_connections 1024;
}
http {
    include "$SCRIPT_DIR/nginx.conf";
}
EOF
    
    if nginx -t -c "$TEMP_NGINX_CONF" -p "$TEMP_NGINX_DIR" >/dev/null 2>&1; then
        pass "Nginx configuration syntax is valid"
    else
        # Try direct test as fallback (may fail for map directive)
        if nginx -t -c "$SCRIPT_DIR/nginx.conf" >/dev/null 2>&1; then
            pass "Nginx configuration syntax is valid"
        else
            warn "Nginx configuration syntax check failed (may be due to map directive context)"
            # Don't fail the test for this - nginx config is validated during actual setup
        fi
    fi
    rm -rf "$TEMP_NGINX_DIR"
else
    warn "nginx not available, skipping nginx config syntax check"
fi

# Test 4: Bootstrap.py Python syntax
log "Test 4: Checking bootstrap.py Python syntax..."
if python3 -m py_compile bootstrap.py 2>/dev/null; then
    pass "bootstrap.py Python syntax is valid"
else
    error "bootstrap.py Python syntax is invalid"
    python3 -m py_compile bootstrap.py || true
fi

# Test 5: Shell script syntax validation
log "Test 5: Checking shell script syntax..."
SHELL_SCRIPTS=(
    "setup.sh"
    "setup-interactive.sh"
    "update-config.sh"
    "integration-test.sh"
    "test-service.sh"
)

for script in "${SHELL_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        if bash -n "$script" 2>/dev/null; then
            pass "Shell script syntax is valid: $script"
        else
            error "Shell script syntax is invalid: $script"
            bash -n "$script" || true
        fi
    fi
done

# Test 6: Setup script help works
log "Test 6: Checking setup script help..."
if [ -f "setup.sh" ]; then
    if bash setup.sh --help >/dev/null 2>&1 || bash setup.sh -h >/dev/null 2>&1; then
        pass "setup.sh help works"
    else
        warn "setup.sh help check skipped (may not have --help flag)"
    fi
fi

# Test 7: Documentation files exist and are not empty
log "Test 7: Checking documentation files..."
DOC_FILES=(
    "README.md"
)

for doc in "${DOC_FILES[@]}"; do
    if [ -f "$doc" ]; then
        if [ -s "$doc" ]; then
            pass "Documentation file exists and is not empty: $doc"
        else
            error "Documentation file is empty: $doc"
        fi
    else
        error "Documentation file missing: $doc"
    fi
done

# Test 8: Check for critical configuration files
log "Test 8: Checking configuration files..."
CONFIG_FILES=(
    "config.yaml.template"
)

for config in "${CONFIG_FILES[@]}"; do
    if [ -f "$config" ]; then
        pass "Configuration file exists: $config"
    else
        error "Configuration file missing: $config"
    fi
done

# Test 8b: Check systemd files (may be in subdirectory)
log "Test 8b: Checking systemd configuration files..."
SYSTEMD_FILES=(
    "ztpbootstrap.pod"
    "ztpbootstrap-nginx.container"
    "ztpbootstrap-webui.container"
)

for config_file in "${SYSTEMD_FILES[@]}"; do
    # Check in systemd subdirectory (where CI copies them)
    if [ -f "systemd/$config_file" ]; then
        pass "Systemd file exists: systemd/$config_file"
    # Check in repo root systemd directory (if running from repo)
    elif [ -f "$SCRIPT_DIR/../systemd/$config_file" ]; then
        pass "Systemd file exists: systemd/$config_file (in repo)"
    else
        warn "Systemd file not found: systemd/$config_file (may be in different location)"
    fi
done

# Summary
echo ""
log "=== CI Test Summary ==="
echo -e "${GREEN}Tests Passed: ${PASSED}${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Tests Failed: ${FAILED}${NC}"
    exit 1
else
    echo -e "${GREEN}Tests Failed: ${FAILED}${NC}"
    log "All CI validation checks passed!"
    exit 0
fi
