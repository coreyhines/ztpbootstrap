#!/bin/bash
# Security Check: Container Log Access Configuration
# Validates that the webui container's access to podman socket and systemd journal
# follows security best practices

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

echo "=== Container Log Access Security Check ==="
echo ""

CONTAINER_FILE="systemd/ztpbootstrap-webui.container"

if [ ! -f "$CONTAINER_FILE" ]; then
    fail "Container file not found: $CONTAINER_FILE"
    exit 1
fi

# Check 1: Podman socket is mounted read-only
echo "Checking podman socket mount..."
if grep -q "podman.sock.*:ro" "$CONTAINER_FILE"; then
    pass "Podman socket is mounted read-only"
else
    fail "Podman socket should be mounted read-only (add :ro flag)"
fi

# Check 2: SELinux context flag is present for podman socket
if grep -q "podman.sock.*:ro,z" "$CONTAINER_FILE" || grep -q "podman.sock.*:ro:z" "$CONTAINER_FILE"; then
    pass "Podman socket has SELinux context flag (:z)"
else
    warn "Podman socket mount should include SELinux context flag (:z) for proper labeling"
fi

# Check 3: Systemd journal mounts are read-only
echo "Checking systemd journal mounts..."
JOURNAL_MOUNTS=$(grep -E "journal.*:ro" "$CONTAINER_FILE" | wc -l)
if [ "$JOURNAL_MOUNTS" -ge 2 ]; then
    pass "Systemd journal mounts are read-only ($JOURNAL_MOUNTS mounts found)"
else
    fail "Systemd journal mounts should be read-only (found $JOURNAL_MOUNTS read-only mounts, expected at least 2)"
fi

# Check 4: No write access to sensitive paths
echo "Checking for write access to sensitive paths..."
if grep -q "podman.sock.*:rw" "$CONTAINER_FILE"; then
    fail "Podman socket should not be mounted read-write"
else
    pass "Podman socket is not mounted read-write"
fi

if grep -q "journal.*:rw" "$CONTAINER_FILE"; then
    fail "Systemd journal should not be mounted read-write"
else
    pass "Systemd journal is not mounted read-write"
fi

# Check 5: Container runs in a pod (not privileged)
echo "Checking container isolation..."
if grep -q "^Pod=" "$CONTAINER_FILE"; then
    pass "Container runs in a pod (good isolation)"
else
    warn "Container should run in a pod for better isolation"
fi

# Check 6: No privileged mode
if grep -q "Privileged=true" "$CONTAINER_FILE"; then
    fail "Container should not run in privileged mode"
else
    pass "Container is not running in privileged mode"
fi

# Check 7: Check for security-related environment variables
echo "Checking environment variables..."
if grep -q "CONTAINER_HOST=" "$CONTAINER_FILE"; then
    pass "CONTAINER_HOST is explicitly set"
else
    warn "CONTAINER_HOST should be explicitly set for clarity"
fi

# Check 8: Application code is mounted read-only
echo "Checking application code mount..."
if grep -q "/app.*:ro" "$CONTAINER_FILE"; then
    pass "Application code is mounted read-only"
else
    warn "Application code should be mounted read-only for security"
fi

# Check 9: No host network access (unless necessary)
if grep -q "NetworkMode=host" "$CONTAINER_FILE"; then
    warn "Container uses host network mode (may be necessary for pod networking)"
else
    pass "Container does not use host network mode directly"
fi

# Check 10: Health check is configured
if grep -q "HealthCmd=" "$CONTAINER_FILE"; then
    pass "Health check is configured"
else
    warn "Health check should be configured for container monitoring"
fi

# Summary
echo ""
echo "=== Security Check Summary ==="
echo -e "${GREEN}Passed: ${PASSED}${NC}"
if [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Warnings: ${WARNINGS}${NC}"
fi
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: ${FAILED}${NC}"
    echo ""
    echo "Security issues found! Please review and fix the container configuration."
    exit 1
else
    echo -e "${GREEN}All critical security checks passed!${NC}"
    if [ $WARNINGS -gt 0 ]; then
        echo "Note: Some warnings were found. Review them for best practices."
    fi
    exit 0
fi

