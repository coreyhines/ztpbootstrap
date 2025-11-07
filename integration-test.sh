#!/bin/bash
# Integration test script for ZTP Bootstrap Service
# This script creates a test container and validates it serves bootstrap.py correctly
# Can be run in CI/CD or manually to verify the setup works

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="/opt/containerdata/ztpbootstrap"
TEST_DIR="${SCRIPT_DIR}/tmp_test"
CONTAINER_NAME="ztpbootstrap-test"
NGINX_IMAGE="nginx:alpine"
DOMAIN="ztpboot.example.com"
TEST_PORT_HTTP=18080
TEST_PORT_HTTPS=18443
HTTP_ONLY=false
SKIP_CLEANUP=false
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ((TESTS_FAILED++)) || true
}

success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++)) || true
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Cleanup function
cleanup() {
    if [[ "$SKIP_CLEANUP" == "true" ]]; then
        info "Skipping cleanup (--no-cleanup flag set)"
        return
    fi
    
    log "Cleaning up test resources..."
    
    # Stop and remove test container
    if podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        podman stop "$CONTAINER_NAME" 2>/dev/null || true
        podman rm "$CONTAINER_NAME" 2>/dev/null || true
        log "Test container removed"
    fi
    
    # Remove test directory if it exists
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
        log "Test directory removed"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --http-only)
                HTTP_ONLY=true
                shift
                ;;
            --no-cleanup)
                SKIP_CLEANUP=true
                shift
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Integration test for ZTP Bootstrap Service

Options:
    --http-only    Test HTTP-only mode (default: HTTPS)
    --no-cleanup   Don't clean up test container and files after test
    -h, --help     Show this help message

Examples:
    $0                    # Test HTTPS mode
    $0 --http-only        # Test HTTP-only mode
    $0 --no-cleanup       # Keep container running after test

EOF
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage."
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing=0
    
    # Check podman
    if ! command -v podman >/dev/null 2>&1; then
        error "podman is not installed"
        missing=1
    else
        success "podman is installed: $(podman --version)"
    fi
    
    # Check curl
    if ! command -v curl >/dev/null 2>&1; then
        error "curl is not installed"
        missing=1
    else
        success "curl is installed"
    fi
    
    # Check python3 (for validating bootstrap.py)
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 is not installed (bootstrap.py syntax validation will be skipped)"
    else
        success "python3 is installed"
    fi
    
    # Check required files
    if [[ ! -f "${SCRIPT_DIR}/bootstrap.py" ]]; then
        error "bootstrap.py not found at ${SCRIPT_DIR}/bootstrap.py"
        missing=1
    else
        success "bootstrap.py found"
    fi
    
    if [[ ! -f "${SCRIPT_DIR}/nginx.conf" ]]; then
        error "nginx.conf not found at ${SCRIPT_DIR}/nginx.conf"
        missing=1
    else
        success "nginx.conf found"
    fi
    
    # Check for HTTP-only mode in nginx.conf
    if [[ "$HTTP_ONLY" == "false" ]]; then
        if grep -q "HTTP-ONLY MODE" "${SCRIPT_DIR}/nginx.conf"; then
            warn "nginx.conf appears to be in HTTP-only mode, but --http-only flag not set"
            HTTP_ONLY=true
        fi
    fi
    
    if [[ $missing -eq 1 ]]; then
        error "Prerequisites check failed"
        exit 1
    fi
    
    # Check SSL certificates for HTTPS mode
    if [[ "$HTTP_ONLY" == "false" ]]; then
        local cert_file="/opt/containerdata/certs/wild/fullchain.pem"
        local key_file="/opt/containerdata/certs/wild/privkey.pem"
        
        if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
            error "SSL certificates not found (required for HTTPS mode)"
            error "  Certificate: $cert_file"
            error "  Private Key: $key_file"
            error "Use --http-only flag to test without certificates"
            exit 1
        else
            success "SSL certificates found"
        fi
    fi
}

# Create test environment
setup_test_environment() {
    log "Setting up test environment..."
    
    # Create test directory
    mkdir -p "$TEST_DIR"
    
    # Copy bootstrap.py to test directory
    cp "${SCRIPT_DIR}/bootstrap.py" "${TEST_DIR}/bootstrap.py"
    success "Copied bootstrap.py to test directory"
    
    # Copy nginx.conf to test directory (we'll modify it if needed)
    cp "${SCRIPT_DIR}/nginx.conf" "${TEST_DIR}/nginx.conf"
    
    # If HTTP-only mode, create HTTP-only nginx config
    if [[ "$HTTP_ONLY" == "true" ]]; then
        log "Creating HTTP-only nginx configuration for testing..."
        cat > "${TEST_DIR}/nginx.conf" << 'NGINX_EOF'
# Nginx configuration for testing (HTTP-only)
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    server {
        listen 80;
        listen [::]:80;
        server_name _;
        
        root /usr/share/nginx/html;
        index bootstrap.py;
        
        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log;
        
        location / {
            try_files $uri $uri/ =404;
            
            location ~* \.py$ {
                add_header Content-Type "text/plain; charset=utf-8";
                add_header Content-Disposition "attachment; filename=bootstrap.py";
            }
            
            location = /bootstrap.py {
                add_header Cache-Control "no-cache, no-store, must-revalidate";
                add_header Pragma "no-cache";
                add_header Expires "0";
                add_header Content-Type "text/plain; charset=utf-8";
                add_header Content-Disposition "attachment; filename=bootstrap.py";
            }
        }
        
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
        
        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }
        
        location ~ ~$ {
            deny all;
            access_log off;
            log_not_found off;
        }
    }
}
NGINX_EOF
        success "Created HTTP-only nginx configuration"
    fi
}

# Start test container
start_test_container() {
    log "Starting test container..."
    
    # Check if ports are available
    if ss -tlnp 2>/dev/null | grep -q ":${TEST_PORT_HTTP} "; then
        error "Port ${TEST_PORT_HTTP} is already in use. Please free the port or modify TEST_PORT_HTTP in the script."
        return 1
    fi
    
    if [[ "$HTTP_ONLY" == "false" ]] && ss -tlnp 2>/dev/null | grep -q ":${TEST_PORT_HTTPS} "; then
        error "Port ${TEST_PORT_HTTPS} is already in use. Please free the port or modify TEST_PORT_HTTPS in the script."
        return 1
    fi
    
    # Pull nginx image if not present
    if ! podman image exists "$NGINX_IMAGE" 2>/dev/null; then
        log "Pulling nginx image..."
        podman pull "$NGINX_IMAGE"
    fi
    
    # Build container command
    local podman_cmd=(
        podman run -d
        --name "$CONTAINER_NAME"
        -p "${TEST_PORT_HTTP}:80"
        -v "${TEST_DIR}:/usr/share/nginx/html:ro"
        -v "${TEST_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro"
    )
    
    # Add SSL volume and port for HTTPS mode
    if [[ "$HTTP_ONLY" == "false" ]]; then
        podman_cmd+=(
            -p "${TEST_PORT_HTTPS}:443"
            -v "/opt/containerdata/certs/wild:/etc/nginx/ssl:ro"
        )
    fi
    
    podman_cmd+=("$NGINX_IMAGE")
    
    # Start container
    local container_output
    if container_output=$("${podman_cmd[@]}" 2>&1); then
        success "Test container started: $CONTAINER_NAME"
        
        # Wait for nginx to start
        log "Waiting for nginx to start..."
        sleep 3
        
        # Check if container is running
        if podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
            success "Container is running"
        else
            error "Container failed to start"
            info "Container output: $container_output"
            if podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
                info "Container logs:"
                podman logs "$CONTAINER_NAME" 2>&1 | head -20
            fi
            return 1
        fi
    else
        error "Failed to start test container"
        info "Error output: $container_output"
        return 1
    fi
}

# Test health endpoint
test_health_endpoint() {
    log "Testing health endpoint..."
    
    local protocol="http"
    local port=$TEST_PORT_HTTP
    local url="${protocol}://localhost:${port}/health"
    
    if [[ "$HTTP_ONLY" == "false" ]]; then
        protocol="https"
        port=$TEST_PORT_HTTPS
        url="${protocol}://localhost:${port}/health"
    fi
    
    local response
    local status_code
    
    if [[ "$HTTP_ONLY" == "false" ]]; then
        response=$(curl -k -s -w "\n%{http_code}" "$url" 2>/dev/null || echo -e "\n000")
    else
        response=$(curl -s -w "\n%{http_code}" "$url" 2>/dev/null || echo -e "\n000")
    fi
    
    status_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)
    
    if [[ "$status_code" == "200" ]] && [[ "$body" == "healthy"* ]]; then
        success "Health endpoint returned 200 OK with 'healthy' response"
    else
        error "Health endpoint test failed (status: $status_code, body: $body)"
    fi
}

# Test bootstrap.py endpoint
test_bootstrap_endpoint() {
    log "Testing bootstrap.py endpoint..."
    
    local protocol="http"
    local port=$TEST_PORT_HTTP
    local url="${protocol}://localhost:${port}/bootstrap.py"
    
    if [[ "$HTTP_ONLY" == "false" ]]; then
        protocol="https"
        port=$TEST_PORT_HTTPS
        url="${protocol}://localhost:${port}/bootstrap.py"
    fi
    
    local response
    local status_code
    local headers
    
    # Get response - separate headers and body
    local headers_file=$(mktemp)
    local body_file=$(mktemp)
    
    if [[ "$HTTP_ONLY" == "false" ]]; then
        status_code=$(curl -k -s -w "\n%{http_code}" -o "$body_file" -D "$headers_file" "$url" 2>/dev/null | tail -n1 || echo "000")
    else
        status_code=$(curl -s -w "\n%{http_code}" -o "$body_file" -D "$headers_file" "$url" 2>/dev/null | tail -n1 || echo "000")
    fi
    
    # Clean up status code (remove newlines)
    status_code=$(echo "$status_code" | tr -d '[:space:]')
    
    if [[ "$status_code" != "200" ]]; then
        error "Bootstrap endpoint returned status $status_code (expected 200)"
        rm -f "$headers_file" "$body_file"
        return 1
    fi
    
    success "Bootstrap endpoint returned 200 OK"
    
    # Read headers and body
    headers=$(cat "$headers_file")
    local body=$(cat "$body_file")
    rm -f "$headers_file" "$body_file"
    
    # Check Content-Type header
    if echo "$headers" | grep -qi "Content-Type:.*text/plain"; then
        success "Content-Type header is correct (text/plain)"
    else
        warn "Content-Type header may be incorrect"
    fi
    
    # Check Content-Disposition header
    if echo "$headers" | grep -qi "Content-Disposition:.*bootstrap.py"; then
        success "Content-Disposition header is correct"
    else
        warn "Content-Disposition header may be incorrect"
    fi
    
    # Check Cache-Control header
    if echo "$headers" | grep -qi "Cache-Control:.*no-cache"; then
        success "Cache-Control header is correct (no-cache)"
    else
        warn "Cache-Control header may be incorrect"
    fi
    
        # Validate bootstrap.py content
        if [[ -n "$body" ]]; then
            success "Bootstrap script content received (${#body} bytes)"
            
            # Save body for comparison (save raw response)
            echo "$body" > "${TEST_DIR}/bootstrap_downloaded.py"
            
            # Check if it starts with Python shebang or is valid Python
            if echo "$body" | head -1 | grep -q "^#!.*python\|^#.*Python\|^import\|^from"; then
                success "Bootstrap script appears to be valid Python"
            else
                warn "Bootstrap script may not be valid Python (first line: $(echo "$body" | head -1 | cut -c1-50))"
            fi
            
            # Validate Python syntax if python3 is available
            if command -v python3 >/dev/null 2>&1; then
                local temp_py=$(mktemp)
                echo "$body" > "$temp_py"
                if python3 -m py_compile "$temp_py" 2>/dev/null; then
                    success "Bootstrap script Python syntax is valid"
                else
                    # Try to get syntax error
                    local syntax_error=$(python3 -m py_compile "$temp_py" 2>&1 || true)
                    warn "Bootstrap script Python syntax validation failed: $syntax_error"
                fi
                rm -f "$temp_py"
            fi
        else
            error "Bootstrap script content is empty"
        fi
}

# Test file content matches
test_file_content() {
    log "Testing file content matches..."
    
    if [[ ! -f "${TEST_DIR}/bootstrap.py" ]] || [[ ! -f "${TEST_DIR}/bootstrap_downloaded.py" ]]; then
        error "Cannot compare files (one or both missing)"
        return 1
    fi
    
    if diff -q "${TEST_DIR}/bootstrap.py" "${TEST_DIR}/bootstrap_downloaded.py" >/dev/null 2>&1; then
        success "Downloaded bootstrap.py matches original file"
    else
        error "Downloaded bootstrap.py does not match original file"
        info "Differences:"
        diff "${TEST_DIR}/bootstrap.py" "${TEST_DIR}/bootstrap_downloaded.py" | head -20 || true
    fi
}

# Test EOS device simulation
test_eos_simulation() {
    log "Simulating EOS device request..."
    
    local protocol="http"
    local port=$TEST_PORT_HTTP
    local url="${protocol}://localhost:${port}/bootstrap.py"
    
    if [[ "$HTTP_ONLY" == "false" ]]; then
        protocol="https"
        port=$TEST_PORT_HTTPS
        url="${protocol}://localhost:${port}/bootstrap.py"
    fi
    
    # Simulate EOS device request (simple GET with User-Agent)
    local user_agent="Arista-EOS/4.28.0F"
    local response
    local status_code
    
    if [[ "$HTTP_ONLY" == "false" ]]; then
        response=$(curl -k -s -w "\n%{http_code}" -A "$user_agent" "$url" 2>/dev/null || echo -e "\n000")
    else
        response=$(curl -s -w "\n%{http_code}" -A "$user_agent" "$url" 2>/dev/null || echo -e "\n000")
    fi
    
    status_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n-1)
    
    if [[ "$status_code" == "200" ]] && [[ -n "$body" ]]; then
        success "EOS device simulation successful (received ${#body} bytes)"
    else
        error "EOS device simulation failed (status: $status_code)"
    fi
}

# Test nginx configuration syntax
test_nginx_syntax() {
    log "Testing nginx configuration syntax..."
    
    # Test nginx config in container
    if podman exec "$CONTAINER_NAME" nginx -t >/dev/null 2>&1; then
        success "Nginx configuration syntax is valid"
    else
        error "Nginx configuration syntax is invalid"
        podman exec "$CONTAINER_NAME" nginx -t 2>&1 || true
    fi
}

# Test container logs
test_container_logs() {
    log "Checking container logs for errors..."
    
    local error_lines
    error_lines=$(podman logs "$CONTAINER_NAME" 2>&1 | grep -i "error\|fatal\|emerg" || true)
    
    # Count lines (handle empty case)
    local error_count=0
    if [[ -n "$error_lines" ]]; then
        error_count=$(echo "$error_lines" | wc -l)
        # Remove any whitespace from wc output
        error_count=$(echo "$error_count" | tr -d '[:space:]')
    fi
    
    # Ensure it's a number
    if ! [[ "$error_count" =~ ^[0-9]+$ ]]; then
        error_count=0
    fi
    
    if [[ "$error_count" -eq 0 ]]; then
        success "No errors found in container logs"
    else
        warn "Found $error_count potential errors in container logs"
        echo "$error_lines" | head -5
    fi
}

# Print test summary
print_summary() {
    echo ""
    log "========================================="
    log "Test Summary"
    log "========================================="
    log "Tests Passed: $TESTS_PASSED"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        error "Tests Failed: $TESTS_FAILED"
    else
        success "Tests Failed: $TESTS_FAILED"
    fi
    log "========================================="
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        success "All tests passed! ✓"
        return 0
    else
        error "Some tests failed. Please review the output above."
        return 1
    fi
}

# Main test function
main() {
    parse_args "$@"
    
    echo ""
    log "========================================="
    log "ZTP Bootstrap Service Integration Test"
    log "========================================="
    echo ""
    
    if [[ "$HTTP_ONLY" == "true" ]]; then
        warn "Testing in HTTP-only mode (insecure)"
    else
        info "Testing in HTTPS mode"
    fi
    echo ""
    
    check_prerequisites
    setup_test_environment
    start_test_container
    test_nginx_syntax
    test_health_endpoint
    test_bootstrap_endpoint
    test_file_content
    test_eos_simulation
    test_container_logs
    
    print_summary
}

# Run main function
main "$@"
