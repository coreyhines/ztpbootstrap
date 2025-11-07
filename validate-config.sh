#!/bin/bash
# Configuration validation script for Arista ZTP Bootstrap Service
# Validates all configuration values before applying them

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_FILE="${1:-config.yaml}"
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

# Logging functions
log() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    ((VALIDATION_WARNINGS++)) || true
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    ((VALIDATION_ERRORS++)) || true
}

info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# Check if yq is available
check_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        error "yq is required to parse YAML configuration"
        return 1
    fi
    return 0
}

# Read YAML values using yq
get_yaml_value() {
    local path="$1"
    yq eval "$path" "$CONFIG_FILE" 2>/dev/null || echo ""
}

# Validate IPv4 address
validate_ipv4() {
    local ip="$1"
    local name="$2"
    
    if [[ -z "$ip" ]] || [[ "$ip" == "null" ]]; then
        return 0  # Empty is valid (means use host network)
    fi
    
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                error "$name: Invalid IPv4 address '$ip' (octet > 255)"
                return 1
            fi
        done
        return 0
    else
        error "$name: Invalid IPv4 address format '$ip'"
        return 1
    fi
}

# Validate IPv6 address
validate_ipv6() {
    local ip="$1"
    local name="$2"
    
    if [[ -z "$ip" ]] || [[ "$ip" == "null" ]]; then
        return 0  # Empty is valid (means disabled)
    fi
    
    # Basic IPv6 validation (simplified)
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] || [[ $ip =~ ^::1$ ]] || [[ $ip =~ ^::$ ]]; then
        return 0
    else
        error "$name: Invalid IPv6 address format '$ip'"
        return 1
    fi
}

# Validate port number
validate_port() {
    local port="$1"
    local name="$2"
    
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        error "$name: Port must be a number, got '$port'"
        return 1
    fi
    
    if [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        error "$name: Port must be between 1 and 65535, got '$port'"
        return 1
    fi
    
    return 0
}

# Validate URL
validate_url() {
    local url="$1"
    local name="$2"
    local allow_empty="${3:-false}"
    
    if [[ -z "$url" ]] || [[ "$url" == "null" ]]; then
        if [[ "$allow_empty" == "true" ]]; then
            return 0
        else
            error "$name: URL cannot be empty"
            return 1
        fi
    fi
    
    # Basic URL validation
    if [[ $url =~ ^https?:// ]] || [[ $url =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?)*$ ]]; then
        return 0
    else
        error "$name: Invalid URL format '$url'"
        return 1
    fi
}

# Validate domain name
validate_domain() {
    local domain="$1"
    local name="$2"
    
    if [[ -z "$domain" ]] || [[ "$domain" == "null" ]]; then
        error "$name: Domain cannot be empty"
        return 1
    fi
    
    # Basic domain validation
    if [[ $domain =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?)+$ ]]; then
        return 0
    else
        error "$name: Invalid domain format '$domain'"
        return 1
    fi
}

# Validate path (check if directory exists or can be created)
validate_path() {
    local path="$1"
    local name="$2"
    local must_exist="${3:-false}"
    
    if [[ -z "$path" ]] || [[ "$path" == "null" ]]; then
        error "$name: Path cannot be empty"
        return 1
    fi
    
    # Check if it's an absolute path
    if [[ ! "$path" =~ ^/ ]]; then
        error "$name: Path must be absolute, got '$path'"
        return 1
    fi
    
    # Check if directory exists
    if [[ -d "$path" ]]; then
        if [[ ! -w "$path" ]] && [[ "$must_exist" == "false" ]]; then
            warn "$name: Directory '$path' exists but is not writable"
        fi
        return 0
    fi
    
    # Check if parent directory exists and is writable
    local parent_dir
    parent_dir=$(dirname "$path")
    if [[ -d "$parent_dir" ]]; then
        if [[ -w "$parent_dir" ]]; then
            return 0
        else
            error "$name: Parent directory '$parent_dir' is not writable"
            return 1
        fi
    else
        error "$name: Parent directory '$parent_dir' does not exist"
        return 1
    fi
}

# Check if port is available
check_port_available() {
    local port="$1"
    local name="$2"
    
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":$port "; then
            warn "$name: Port $port is already in use"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            warn "$name: Port $port is already in use"
            return 1
        fi
    else
        info "$name: Cannot check if port $port is available (ss/netstat not found)"
    fi
    return 0
}

# Validate file path
validate_file_path() {
    local file_path="$1"
    local name="$2"
    local must_exist="${3:-false}"
    
    if [[ -z "$file_path" ]] || [[ "$file_path" == "null" ]]; then
        error "$name: File path cannot be empty"
        return 1
    fi
    
    # Check if it's an absolute path
    if [[ ! "$file_path" =~ ^/ ]]; then
        error "$name: File path must be absolute, got '$file_path'"
        return 1
    fi
    
    # Check if file exists
    if [[ -f "$file_path" ]]; then
        if [[ ! -r "$file_path" ]]; then
            error "$name: File '$file_path' exists but is not readable"
            return 1
        fi
        return 0
    fi
    
    # Check if parent directory exists and is writable
    local parent_dir
    parent_dir=$(dirname "$file_path")
    if [[ -d "$parent_dir" ]]; then
        if [[ -w "$parent_dir" ]] || [[ "$must_exist" == "false" ]]; then
            return 0
        else
            error "$name: Parent directory '$parent_dir' is not writable"
            return 1
        fi
    else
        if [[ "$must_exist" == "true" ]]; then
            error "$name: File '$file_path' does not exist"
            return 1
        else
            # Check if we can create parent directory
            local grandparent_dir
            grandparent_dir=$(dirname "$parent_dir")
            if [[ -d "$grandparent_dir" ]] && [[ -w "$grandparent_dir" ]]; then
                return 0
            else
                error "$name: Cannot create file '$file_path' (parent directories not writable)"
                return 1
            fi
        fi
    fi
}

# Main validation function
validate_config() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Configuration Validation${NC}                                  ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    info "Validating configuration file: $CONFIG_FILE"
    echo ""
    
    # Validate paths
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Validating Paths${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local script_dir
    local cert_dir
    local env_file
    local bootstrap_script
    local nginx_conf
    local quadlet_file
    
    script_dir=$(get_yaml_value '.paths.script_dir')
    cert_dir=$(get_yaml_value '.paths.cert_dir')
    env_file=$(get_yaml_value '.paths.env_file')
    bootstrap_script=$(get_yaml_value '.paths.bootstrap_script')
    nginx_conf=$(get_yaml_value '.paths.nginx_conf')
    quadlet_file=$(get_yaml_value '.paths.quadlet_file')
    
    validate_path "$script_dir" "script_dir"
    validate_path "$cert_dir" "cert_dir"
    validate_file_path "$env_file" "env_file"
    validate_file_path "$bootstrap_script" "bootstrap_script" "true"
    validate_file_path "$nginx_conf" "nginx_conf" "true"
    validate_file_path "$quadlet_file" "quadlet_file"
    
    echo ""
    
    # Validate network configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Validating Network Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local domain
    local ipv4
    local ipv6
    local https_port
    local http_port
    local http_only
    
    domain=$(get_yaml_value '.network.domain')
    ipv4=$(get_yaml_value '.network.ipv4')
    ipv6=$(get_yaml_value '.network.ipv6')
    https_port=$(get_yaml_value '.network.https_port')
    http_port=$(get_yaml_value '.network.http_port')
    http_only=$(get_yaml_value '.network.http_only')
    
    validate_domain "$domain" "domain"
    validate_ipv4 "$ipv4" "ipv4"
    validate_ipv6 "$ipv6" "ipv6"
    validate_port "$https_port" "https_port"
    validate_port "$http_port" "http_port"
    
    # Check port availability
    if [[ "$http_only" == "true" ]]; then
        check_port_available "$http_port" "http_port"
    else
        check_port_available "$https_port" "https_port"
    fi
    
    echo ""
    
    # Validate CVaaS configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Validating CVaaS Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local cv_addr
    local enrollment_token
    local cv_proxy
    local eos_url
    local ntp_server
    
    cv_addr=$(get_yaml_value '.cvaas.address')
    enrollment_token=$(get_yaml_value '.cvaas.enrollment_token')
    cv_proxy=$(get_yaml_value '.cvaas.proxy')
    eos_url=$(get_yaml_value '.cvaas.eos_url')
    ntp_server=$(get_yaml_value '.cvaas.ntp_server')
    
    validate_url "$cv_addr" "cvaas.address"
    if [[ -z "$enrollment_token" ]] || [[ "$enrollment_token" == "null" ]] || [[ "$enrollment_token" == "" ]]; then
        error "cvaas.enrollment_token: Enrollment token is required"
    else
        if [[ ${#enrollment_token} -lt 20 ]]; then
            warn "cvaas.enrollment_token: Token seems too short (should be a JWT token)"
        fi
    fi
    validate_url "$cv_proxy" "cvaas.proxy" "true"
    validate_url "$eos_url" "cvaas.eos_url" "true"
    validate_domain "$ntp_server" "cvaas.ntp_server"
    
    echo ""
    
    # Validate SSL configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Validating SSL Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local cert_file
    local key_file
    local use_letsencrypt
    local letsencrypt_email
    
    cert_file=$(get_yaml_value '.ssl.cert_file')
    key_file=$(get_yaml_value '.ssl.key_file')
    use_letsencrypt=$(get_yaml_value '.ssl.use_letsencrypt')
    letsencrypt_email=$(get_yaml_value '.ssl.letsencrypt_email')
    
    if [[ -n "$cert_file" ]] && [[ "$cert_file" != "null" ]]; then
        if [[ ! "$cert_file" =~ \.(pem|crt|cer)$ ]]; then
            warn "ssl.cert_file: Certificate file should have .pem, .crt, or .cer extension"
        fi
    fi
    
    if [[ -n "$key_file" ]] && [[ "$key_file" != "null" ]]; then
        if [[ ! "$key_file" =~ \.(pem|key)$ ]]; then
            warn "ssl.key_file: Key file should have .pem or .key extension"
        fi
    fi
    
    if [[ "$use_letsencrypt" == "true" ]]; then
        if [[ -z "$letsencrypt_email" ]] || [[ "$letsencrypt_email" == "null" ]]; then
            error "ssl.letsencrypt_email: Email is required when use_letsencrypt is true"
        elif [[ ! "$letsencrypt_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "ssl.letsencrypt_email: Invalid email format '$letsencrypt_email'"
        fi
    fi
    
    echo ""
    
    # Validate container configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Validating Container Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local container_name
    local container_image
    local timezone
    local dns1
    local dns2
    
    container_name=$(get_yaml_value '.container.name')
    container_image=$(get_yaml_value '.container.image')
    timezone=$(get_yaml_value '.container.timezone')
    dns1=$(get_yaml_value '.container.dns[0]')
    dns2=$(get_yaml_value '.container.dns[1]')
    
    if [[ -z "$container_name" ]] || [[ "$container_name" == "null" ]]; then
        error "container.name: Container name cannot be empty"
    fi
    
    if [[ -z "$container_image" ]] || [[ "$container_image" == "null" ]]; then
        error "container.image: Container image cannot be empty"
    elif [[ ! "$container_image" =~ ^[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+$ ]] && [[ ! "$container_image" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        warn "container.image: Image format may be invalid '$container_image' (expected: registry/image:tag)"
    fi
    
    validate_ipv4 "$dns1" "container.dns[0]"
    validate_ipv4 "$dns2" "container.dns[1]"
    
    echo ""
    
    # Summary
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Validation Summary${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [[ $VALIDATION_ERRORS -eq 0 ]] && [[ $VALIDATION_WARNINGS -eq 0 ]]; then
        log "All validations passed!"
        return 0
    elif [[ $VALIDATION_ERRORS -eq 0 ]]; then
        warn "Validation completed with $VALIDATION_WARNINGS warning(s)"
        return 0
    else
        error "Validation failed with $VALIDATION_ERRORS error(s) and $VALIDATION_WARNINGS warning(s)"
        return 1
    fi
}

# Main function
main() {
    if ! check_yq; then
        exit 1
    fi
    
    if validate_config; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
