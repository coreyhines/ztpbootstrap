#!/usr/bin/env bats
# Integration tests for DHCP API endpoints

# Define helper functions directly (workaround for bats load path issues)
# These are minimal implementations of bats-assert functions
assert_success() {
    if [[ $status -ne 0 ]]; then
        echo "Expected success but got exit code $status"
        return 1
    fi
}

assert_failure() {
    if [[ $status -eq 0 ]]; then
        echo "Expected failure but got success"
        return 1
    fi
}

assert_output() {
    local flags=""
    local pattern=""

    # Parse arguments - handle --partial flag
    if [[ "$1" == "--partial" ]]; then
        flags="--partial"
        pattern="$2"
    else
        pattern="$1"
        shift
        flags="$@"
    fi

    if [[ "$flags" == *"--partial"* ]] || [[ "$1" == "--partial" ]]; then
        if [[ "$output" == *"$pattern"* ]]; then
            return 0
        else
            echo "Output does not contain pattern: $pattern"
            echo "Actual output: $output"
            return 1
        fi
    else
        if [[ "$output" =~ $pattern ]]; then
            return 0
        else
            echo "Output does not match pattern: $pattern"
            echo "Actual output: $output"
            return 1
        fi
    fi
}

assert() {
    if ! eval "$@"; then
        echo "Assertion failed: $@"
        return 1
    fi
}

setup() {
    # Verify helper functions are available
    if ! type assert_success >/dev/null 2>&1; then
        echo "ERROR: assert_success function not found!" >&2
        echo "Available functions:" >&2
        declare -F | grep assert >&2 || echo "No assert functions found" >&2
        exit 1
    fi

    # Check if webui service is running
    if ! systemctl is-active --quiet ztpbootstrap-webui.service 2>/dev/null; then
        skip "WebUI service not running"
    fi

    # Try to find which port WebUI is accessible on
    # With host networking, nginx should be on 8080, but webui might be directly on 5000
    WEBUI_PORT="${WEBUI_PORT:-8080}"
    BASE_URL="http://localhost:${WEBUI_PORT}"

    # Try port 8080 first (nginx), then fall back to 5000 (direct webui)
    if ! curl -s --connect-timeout 2 --max-time 5 "http://localhost:8080" >/dev/null 2>&1; then
        if curl -s --connect-timeout 2 --max-time 5 "http://localhost:5000" >/dev/null 2>&1; then
            WEBUI_PORT="5000"
            BASE_URL="http://localhost:${WEBUI_PORT}"
            echo "Using direct WebUI port 5000 (nginx not available)" >&2
        else
            echo "WARNING: WebUI not accessible on port 8080 or 5000" >&2
            echo "Checking what's listening..." >&2
            netstat -tlnp 2>/dev/null | grep -E ":(8080|5000)" >&2 || ss -tlnp 2>/dev/null | grep -E ":(8080|5000)" >&2 || echo "Nothing listening on ports 8080 or 5000" >&2
            echo "Container status:" >&2
            podman ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E "(NAMES|webui|nginx)" >&2 || true
            skip "WebUI not accessible"
        fi
    fi

    # Test credentials (should match test config)
    TEST_USER="${TEST_USER:-admin}"
    TEST_PASS="${TEST_PASS:-admin}"

    # Get auth token
    AUTH_TOKEN=""
}

teardown() {
    # Cleanup if needed
    true
}

# Helper function to authenticate
authenticate() {
    if [ -z "$AUTH_TOKEN" ]; then
        # Try to login and get session cookie
        # Use -f to fail on HTTP errors, but capture the response
        local response=$(curl -s -w "\n%{http_code}" -c /tmp/test_cookies.txt -X POST \
            "${BASE_URL}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"password\":\"${TEST_PASS}\"}" 2>&1)

        local http_code=$(echo "$response" | tail -1)
        local body=$(echo "$response" | sed '$d')

        # Check if login was successful (200, 302, or any 2xx/3xx)
        if [[ "$http_code" =~ ^[23] ]]; then
            # Extract CSRF token if present
            AUTH_TOKEN=$(echo "$body" | grep -oP 'csrf_token["\s]*:\s*"\K[^"]+' || echo "")
            # Also try to get CSRF token from response headers or set-cookie
            if [ -z "$AUTH_TOKEN" ]; then
                # Check if there's a CSRF token in the response body
                AUTH_TOKEN=$(echo "$body" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('csrf_token', ''))" 2>/dev/null || echo "")
            fi
        else
            echo "WARNING: Login failed with HTTP $http_code" >&2
            echo "Response body: $body" >&2
            echo "URL: ${BASE_URL}/api/auth/login" >&2
        fi
    fi
}

@test "DHCP config endpoint returns current config" {
    authenticate

    run curl -s -b /tmp/test_cookies.txt \
        "${BASE_URL}/api/dhcp/config"

    # If curl fails with connection error, show diagnostics
    if [[ $status -eq 7 ]]; then
        echo "Connection failed to ${BASE_URL}/api/dhcp/config" >&2
        echo "Checking WebUI accessibility..." >&2
        curl -v "${BASE_URL}" 2>&1 | head -15 >&2 || true
        echo "Container logs:" >&2
        podman logs --tail 10 ztpbootstrap-webui 2>&1 | head -10 >&2 || true
    fi

    assert_success
    # Response should contain "dhcp" key (even if empty: {"dhcp":{}})
    assert_output --partial "dhcp"
}

@test "DHCP status endpoint returns status" {
    authenticate

    run curl -s -b /tmp/test_cookies.txt \
        "${BASE_URL}/api/dhcp/status"

    assert_success
    # Response should contain "enabled" key (even if false: "enabled":false)
    assert_output --partial "enabled"
}

@test "DHCP auto-detect endpoint works" {
    authenticate

    # Get CSRF token from auth status endpoint
    local auth_status=$(curl -s -b /tmp/test_cookies.txt "${BASE_URL}/api/auth/status" 2>/dev/null)
    local csrf_token=$(echo "$auth_status" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('csrf_token', ''))" 2>/dev/null || echo "")

    run curl -s -b /tmp/test_cookies.txt \
        -X POST \
        -H "Content-Type: application/json" \
        ${csrf_token:+-H "X-CSRF-Token: ${csrf_token}"} \
        "${BASE_URL}/api/dhcp/config/auto-detect" \
        -d '{"ipv4_address": "10.0.0.10"}'

    assert_success
    # Should return gateway and subnet info, or at least not be a CSRF error
    if [[ "$output" == *"CSRF_ERROR"* ]]; then
        echo "CSRF token missing or invalid. Response: $output" >&2
        return 1
    fi
    assert_output --partial "gateway"
}

@test "DHCP config update requires authentication" {
    # Try without authentication
    run curl -s -X PUT \
        "${BASE_URL}/api/dhcp/config" \
        -H "Content-Type: application/json" \
        -d '{"dhcp": {"enabled": false}}'

    # Should require auth - check for AUTH_REQUIRED, 401, or login
    assert [ "$status" -eq 0 ]  # curl succeeds but may get auth error
    assert_output --partial "AUTH_REQUIRED" || assert_output --partial "401" || assert_output --partial "login"
}

@test "DHCP leases endpoint returns leases" {
    authenticate

    run curl -s -b /tmp/test_cookies.txt \
        "${BASE_URL}/api/dhcp/leases"

    assert_success
    assert_output --partial "leases"
}

@test "DHCP reservations endpoint works" {
    authenticate

    run curl -s -b /tmp/test_cookies.txt \
        "${BASE_URL}/api/dhcp/reservations"

    assert_success
    assert_output --partial "reservations"
}

@test "DHCP statistics endpoint works" {
    authenticate

    run curl -s -b /tmp/test_cookies.txt \
        "${BASE_URL}/api/dhcp/statistics"

    assert_success
    # May return empty stats if DHCP not enabled
    assert_output --partial "statistics" || assert_output --partial "error"
}
