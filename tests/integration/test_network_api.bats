#!/usr/bin/env bats
# Integration tests for ZTP Network API endpoints

assert_success() {
    if [[ $status -ne 0 ]]; then
        echo "Expected success but got exit code $status"
        return 1
    fi
}

assert_output() {
    local flags=""
    local pattern=""

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
        fi
        echo "Output does not contain pattern: $pattern"
        echo "Actual output: $output"
        return 1
    fi

    if [[ "$output" =~ $pattern ]]; then
        return 0
    fi
    echo "Output does not match pattern: $pattern"
    echo "Actual output: $output"
    return 1
}

setup() {
    if ! systemctl is-active --quiet ztpbootstrap-webui.service 2>/dev/null; then
        skip "WebUI service not running"
    fi

    WEBUI_PORT="${WEBUI_PORT:-8080}"
    BASE_URL="http://localhost:${WEBUI_PORT}"
    if ! curl -s --connect-timeout 2 --max-time 5 "http://localhost:8080" >/dev/null 2>&1; then
        BASE_URL="http://localhost:5000"
    fi

    if ! curl -s --connect-timeout 2 --max-time 5 "${BASE_URL}" >/dev/null 2>&1; then
        skip "WebUI not accessible"
    fi

    TEST_PASS="${TEST_PASS:-admin}"
    AUTH_READY="false"
    AUTH_CSRF_TOKEN=""
}

authenticate() {
    if [[ "$AUTH_READY" == "true" ]]; then
        return 0
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" -c /tmp/test_cookies.txt -X POST \
        "${BASE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"${TEST_PASS}\"}" 2>/dev/null || true)

    local http_code
    http_code=$(printf "%s" "$response" | awk 'END{print}')
    if [[ "$http_code" =~ ^[23] ]]; then
        AUTH_READY="true"
        return 0
    fi

    AUTH_READY="false"
    return 1
}

require_auth_or_skip() {
    if ! authenticate; then
        skip "Authenticated test requires configured login credentials"
    fi
}

get_csrf_token() {
    local auth_status
    auth_status=$(curl -s -b /tmp/test_cookies.txt "${BASE_URL}/api/auth/status" 2>/dev/null || true)
    AUTH_CSRF_TOKEN=$(printf "%s" "$auth_status" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('csrf_token', ''))" 2>/dev/null || echo "")
}

@test "network status endpoint requires auth" {
    run curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api/network/status"
    assert_success
    [[ "$output" == "401" ]]
}

@test "network status endpoint returns ztp payload when authenticated" {
    require_auth_or_skip

    run curl -s -b /tmp/test_cookies.txt "${BASE_URL}/api/network/status"
    assert_success
    assert_output --partial "ztp"
}

@test "network parents endpoint returns parent list when authenticated" {
    require_auth_or_skip

    run curl -s -b /tmp/test_cookies.txt "${BASE_URL}/api/network/parents"
    assert_success
    assert_output --partial "parents"
}

@test "network podman endpoint returns network list when authenticated" {
    require_auth_or_skip

    run curl -s -b /tmp/test_cookies.txt "${BASE_URL}/api/network/podman"
    assert_success
    assert_output --partial "networks"
}

@test "network validate returns validation results when authenticated" {
    require_auth_or_skip
    get_csrf_token

    run curl -s -b /tmp/test_cookies.txt \
        -X POST \
        -H "Content-Type: application/json" \
        ${AUTH_CSRF_TOKEN:+-H "X-CSRF-Token: ${AUTH_CSRF_TOKEN}"} \
        "${BASE_URL}/api/network/validate" \
        -d '{"ztp":{"enabled":true,"vlan_id":5,"parent_interface":"","podman_network":"ztp-net-5","ipv4":{"address":"10.0.5.10","subnet":"10.0.5.0/24","gateway":"10.0.5.1"}}}'

    assert_success
    assert_output --partial "valid"
    assert_output --partial "plan"
}

@test "network auto-detect requires parent_interface" {
    require_auth_or_skip
    get_csrf_token

    run curl -s -b /tmp/test_cookies.txt \
        -X POST \
        -H "Content-Type: application/json" \
        ${AUTH_CSRF_TOKEN:+-H "X-CSRF-Token: ${AUTH_CSRF_TOKEN}"} \
        "${BASE_URL}/api/network/auto-detect" \
        -d '{}'

    assert_success
    assert_output --partial "parent_interface is required"
}

@test "network apply endpoint requires auth" {
    run curl -s -X POST \
        "${BASE_URL}/api/network/apply" \
        -H "Content-Type: application/json" \
        -d '{"ztp":{"enabled":false}}'

    assert_success
    assert_output --partial "AUTH_REQUIRED"
}
