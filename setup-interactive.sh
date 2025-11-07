#!/bin/bash
# Interactive setup script for Arista ZTP Bootstrap Service
# This script provides an interactive mode to configure all paths and variables
# and stores them in a YAML configuration file

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default config file
CONFIG_FILE="config.yaml"
CONFIG_TEMPLATE="config.yaml.template"

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${CYAN}[?]${NC} $1"
}

# Prompt for input with default value
prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local var_name="$3"
    local is_secret="${4:-false}"
    local allow_empty="${5:-false}"
    
    if [[ "$is_secret" == "true" ]]; then
        info "$prompt_text"
        if [[ -n "$default_value" ]]; then
            echo -n "  [Press Enter to keep current value or type new value]: "
        else
            echo -n "  [Required]: "
        fi
        read -rs value
        echo ""
    else
        if [[ -n "$default_value" ]]; then
            if [[ "$allow_empty" == "true" ]]; then
                echo -n -e "${CYAN}[?]${NC} $prompt_text ${BLUE}[$default_value, or Enter for empty]${NC}: "
            else
                echo -n -e "${CYAN}[?]${NC} $prompt_text ${BLUE}[$default_value]${NC}: "
            fi
        else
            echo -n -e "${CYAN}[?]${NC} $prompt_text: "
        fi
        read -r value
    fi
    
    # If value is empty and allow_empty is true, keep it empty
    # Otherwise, use default if value is empty
    if [[ -z "$value" ]]; then
        if [[ "$allow_empty" != "true" ]]; then
            value="$default_value"
        fi
    fi
    
    eval "$var_name='$value'"
}

# Prompt for yes/no with default
prompt_yes_no() {
    local prompt_text="$1"
    local default_value="${2:-n}"
    local var_name="$3"
    
    local default_display
    if [[ "$default_value" == "y" ]] || [[ "$default_value" == "Y" ]]; then
        default_display="Y/n"
    else
        default_display="y/N"
    fi
    
    while true; do
        echo -n -e "${CYAN}[?]${NC} $prompt_text ${BLUE}[$default_display]${NC}: "
        read -r response
        response="${response:-$default_value}"
        case "$response" in
            [Yy]* ) eval "$var_name='true'"; break;;
            [Nn]* ) eval "$var_name='false'"; break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Load existing config if it exists
load_existing_config() {
    if [[ -f "$CONFIG_FILE" ]] && command -v yq >/dev/null 2>&1; then
        log "Found existing configuration file: $CONFIG_FILE"
        echo ""
        prompt_yes_no "Do you want to use existing values as defaults?" "y" USE_EXISTING
        if [[ "$USE_EXISTING" == "true" ]]; then
            # Use yq to extract values (if available)
            log "Loading existing configuration..."
            return 0
        fi
    elif [[ -f "$CONFIG_FILE" ]]; then
        log "Found existing configuration file: $CONFIG_FILE"
        warn "yq not found - cannot parse existing config. Starting fresh."
    fi
    return 1
}

# Main interactive configuration
interactive_config() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Arista ZTP Bootstrap Service - Interactive Setup${NC}        ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    log "This interactive setup will guide you through configuring all paths and variables."
    log "You can press Enter to accept default values (shown in brackets)."
    echo ""
    
    # Section 1: Directory Paths
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Directory Paths${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Main service directory" "/opt/containerdata/ztpbootstrap" SCRIPT_DIR
    prompt_with_default "SSL certificate directory" "/opt/containerdata/certs/wild" CERT_DIR
    prompt_with_default "Environment file path" "${SCRIPT_DIR}/ztpbootstrap.env" ENV_FILE
    prompt_with_default "Bootstrap script path" "${SCRIPT_DIR}/bootstrap.py" BOOTSTRAP_SCRIPT
    prompt_with_default "Configured script path" "${SCRIPT_DIR}/bootstrap_configured.py" CONFIGURED_SCRIPT
    prompt_with_default "Nginx config file" "${SCRIPT_DIR}/nginx.conf" NGINX_CONF
    prompt_with_default "Systemd quadlet file" "/etc/containers/systemd/ztpbootstrap/ztpbootstrap.container" QUADLET_FILE
    
    echo ""
    
    # Section 2: Network Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Network Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Domain name" "ztpboot.example.com" DOMAIN
    prompt_with_default "IPv4 address (leave empty for host network)" "10.0.0.10" IPV4 "false" "true"
    prompt_with_default "IPv6 address (leave empty to disable)" "2001:db8::10" IPV6 "false" "true"
    prompt_with_default "HTTPS port" "443" HTTPS_PORT
    prompt_with_default "HTTP port" "80" HTTP_PORT
    prompt_yes_no "Use HTTP-only mode (insecure, not recommended)" "n" HTTP_ONLY
    
    echo ""
    
    # Section 3: CVaaS Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  CVaaS Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    log "CVaaS Address options:"
    log "  - www.arista.io (recommended - works for all clusters)"
    log "  - www.cv-prod-us-central1-b.arista.io (US 1b)"
    log "  - www.cv-prod-euwest-2.arista.io (Europe West 2)"
    log "  - See config.yaml.template for all regional options"
    echo ""
    
    prompt_with_default "CVaaS address" "www.arista.io" CV_ADDR
    prompt_with_default "Enrollment token (from CVaaS Device Registration)" "" ENROLLMENT_TOKEN "true"
    prompt_with_default "Proxy URL (leave empty if not needed)" "" CV_PROXY
    prompt_with_default "EOS image URL (optional, for upgrades)" "" EOS_URL
    prompt_with_default "NTP server" "time.nist.gov" NTP_SERVER
    
    echo ""
    
    # Section 4: SSL Certificate Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  SSL Certificate Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Certificate filename" "fullchain.pem" CERT_FILE
    prompt_with_default "Private key filename" "privkey.pem" KEY_FILE
    prompt_yes_no "Use Let's Encrypt with certbot?" "n" USE_LETSENCRYPT
    
    if [[ "$USE_LETSENCRYPT" == "true" ]]; then
        prompt_with_default "Email for Let's Encrypt registration" "admin@example.com" LETSENCRYPT_EMAIL
    else
        LETSENCRYPT_EMAIL="admin@example.com"
    fi
    
    prompt_yes_no "Create self-signed certificate for testing (if no cert exists)?" "n" CREATE_SELF_SIGNED
    
    echo ""
    
    # Section 5: Container Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Container Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Container name" "ztpbootstrap" CONTAINER_NAME
    prompt_with_default "Container image" "docker.io/nginx:alpine" CONTAINER_IMAGE
    prompt_with_default "Timezone" "UTC" TIMEZONE
    prompt_yes_no "Use host network mode?" "y" HOST_NETWORK
    prompt_with_default "DNS server 1" "8.8.8.8" DNS1
    prompt_with_default "DNS server 2" "8.8.4.4" DNS2
    
    echo ""
    
    # Section 6: Service Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Service Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Health check interval" "30s" HEALTH_INTERVAL
    prompt_with_default "Health check timeout" "10s" HEALTH_TIMEOUT
    prompt_with_default "Health check retries" "3" HEALTH_RETRIES
    prompt_with_default "Health check start period" "60s" HEALTH_START_PERIOD
    prompt_with_default "Restart policy" "on-failure" RESTART_POLICY
    
    echo ""
}

# Copy source files to target directory
copy_source_files() {
    log "Copying source files to target directory..."
    
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Get target paths from config variables
    local script_dir="${SCRIPT_DIR:-}"
    local bootstrap_script="${BOOTSTRAP_SCRIPT:-}"
    local nginx_conf="${NGINX_CONF:-}"
    
    # Copy bootstrap.py
    if [[ -n "$bootstrap_script" ]] && [[ "$bootstrap_script" != "null" ]]; then
        local source_bootstrap="${repo_dir}/bootstrap.py"
        if [[ -f "$source_bootstrap" ]]; then
            if [[ ("$bootstrap_script" =~ ^/etc/ || "$bootstrap_script" =~ ^/opt/) && $EUID -ne 0 ]]; then
                if sudo cp "$source_bootstrap" "$bootstrap_script" 2>/dev/null; then
                    sudo chown "$USER:$(id -gn)" "$bootstrap_script" 2>/dev/null || true
                    sudo chmod 644 "$bootstrap_script" 2>/dev/null || true
                    log "Copied bootstrap.py to: $bootstrap_script"
                else
                    warn "Failed to copy bootstrap.py to: $bootstrap_script"
                fi
            else
                if cp "$source_bootstrap" "$bootstrap_script" 2>/dev/null; then
                    chmod 644 "$bootstrap_script" 2>/dev/null || true
                    log "Copied bootstrap.py to: $bootstrap_script"
                else
                    # Try with sudo if regular copy failed
                    if sudo cp "$source_bootstrap" "$bootstrap_script" 2>/dev/null; then
                        sudo chown "$USER:$(id -gn)" "$bootstrap_script" 2>/dev/null || true
                        sudo chmod 644 "$bootstrap_script" 2>/dev/null || true
                        log "Copied bootstrap.py with sudo to: $bootstrap_script"
                    else
                        warn "Failed to copy bootstrap.py to: $bootstrap_script"
                    fi
                fi
            fi
        else
            warn "Source file not found: $source_bootstrap"
        fi
    fi
    
    # Copy nginx.conf
    if [[ -n "$nginx_conf" ]] && [[ "$nginx_conf" != "null" ]]; then
        local source_nginx="${repo_dir}/nginx.conf"
        if [[ -f "$source_nginx" ]]; then
            if [[ ("$nginx_conf" =~ ^/etc/ || "$nginx_conf" =~ ^/opt/) && $EUID -ne 0 ]]; then
                if sudo cp "$source_nginx" "$nginx_conf" 2>/dev/null; then
                    sudo chown "$USER:$(id -gn)" "$nginx_conf" 2>/dev/null || true
                    sudo chmod 644 "$nginx_conf" 2>/dev/null || true
                    log "Copied nginx.conf to: $nginx_conf"
                else
                    warn "Failed to copy nginx.conf to: $nginx_conf"
                fi
            else
                if cp "$source_nginx" "$nginx_conf" 2>/dev/null; then
                    chmod 644 "$nginx_conf" 2>/dev/null || true
                    log "Copied nginx.conf to: $nginx_conf"
                else
                    # Try with sudo if regular copy failed
                    if sudo cp "$source_nginx" "$nginx_conf" 2>/dev/null; then
                        sudo chown "$USER:$(id -gn)" "$nginx_conf" 2>/dev/null || true
                        sudo chmod 644 "$nginx_conf" 2>/dev/null || true
                        log "Copied nginx.conf with sudo to: $nginx_conf"
                    else
                        warn "Failed to copy nginx.conf to: $nginx_conf"
                    fi
                fi
            fi
        else
            warn "Source file not found: $source_nginx"
        fi
    fi
    
    echo ""
}

# Create necessary directories
create_directories() {
    log "Creating necessary directories..."
    
    local dirs_to_create=()
    local need_sudo=false
    
    # Extract directories from config variables
    # Main service directory
    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        dirs_to_create+=("$SCRIPT_DIR")
    fi
    
    # Certificate directory
    if [[ -n "${CERT_DIR:-}" ]]; then
        dirs_to_create+=("$CERT_DIR")
    fi
    
    # Systemd quadlet directory (may need sudo)
    if [[ -n "${QUADLET_FILE:-}" ]]; then
        local quadlet_dir
        quadlet_dir=$(dirname "$QUADLET_FILE")
        if [[ "$quadlet_dir" == /etc/* ]]; then
            need_sudo=true
        fi
        dirs_to_create+=("$quadlet_dir")
    fi
    
    # Create directories (mkdir -p creates parent directories automatically)
    for dir in "${dirs_to_create[@]}"; do
        if [[ -z "$dir" ]] || [[ "$dir" == "null" ]]; then
            continue
        fi
        
        if [[ ! -d "$dir" ]]; then
            if [[ ("$dir" =~ ^/etc/ || "$dir" =~ ^/opt/) && $EUID -ne 0 ]]; then
                log "Creating directory (requires sudo): $dir"
                if sudo mkdir -p "$dir" 2>/dev/null; then
                    # Make writable by current user
                    if sudo chown "$USER:$(id -gn)" "$dir" 2>/dev/null; then
                        sudo chmod 755 "$dir" 2>/dev/null || true
                        log "Created and set permissions: $dir"
                    else
                        sudo chmod 755 "$dir" 2>/dev/null || true
                        log "Created: $dir"
                    fi
                else
                    warn "Failed to create directory: $dir (may need manual creation with sudo)"
                fi
            else
                log "Creating directory: $dir"
                if mkdir -p "$dir" 2>/dev/null; then
                    # Make writable by current user
                    chmod 755 "$dir" 2>/dev/null || true
                    log "Created and set permissions: $dir"
                else
                    # Try with sudo if regular mkdir failed
                    if sudo mkdir -p "$dir" 2>/dev/null; then
                        sudo chown "$USER:$(id -gn)" "$dir" 2>/dev/null || true
                        sudo chmod 755 "$dir" 2>/dev/null || true
                        log "Created with sudo and set permissions: $dir"
                    else
                        warn "Failed to create directory: $dir"
                    fi
                fi
            fi
        else
            # Directory exists - ensure it's writable
            if [[ ("$dir" =~ ^/etc/ || "$dir" =~ ^/opt/) && $EUID -ne 0 ]]; then
                if sudo chown "$USER:$(id -gn)" "$dir" 2>/dev/null; then
                    sudo chmod 755 "$dir" 2>/dev/null || true
                    log "Updated permissions for existing directory: $dir"
                else
                    log "Directory already exists: $dir (may need sudo to modify)"
                fi
            else
                # Try to make writable, use sudo if needed
                if chmod 755 "$dir" 2>/dev/null; then
                    log "Directory already exists: $dir"
                elif sudo chown "$USER:$(id -gn)" "$dir" 2>/dev/null && sudo chmod 755 "$dir" 2>/dev/null; then
                    log "Updated permissions for existing directory: $dir"
                else
                    log "Directory already exists: $dir"
                fi
            fi
        fi
    done
    
    echo ""
}

# Generate YAML configuration file
generate_yaml_config() {
    log "Generating YAML configuration file: $CONFIG_FILE"
    
    cat > "$CONFIG_FILE" << EOF
# Arista ZTP Bootstrap Service Configuration
# Generated by interactive setup on $(date)
# This file contains all customizable paths and variables for the service

# ============================================================================
# Directory Paths
# ============================================================================
paths:
  script_dir: "$SCRIPT_DIR"
  cert_dir: "$CERT_DIR"
  env_file: "$ENV_FILE"
  bootstrap_script: "$BOOTSTRAP_SCRIPT"
  configured_script: "$CONFIGURED_SCRIPT"
  nginx_conf: "$NGINX_CONF"
  quadlet_file: "$QUADLET_FILE"

# ============================================================================
# Network Configuration
# ============================================================================
network:
  domain: "$DOMAIN"
  ipv4: "$IPV4"
  ipv6: "$IPV6"
  https_port: $HTTPS_PORT
  http_port: $HTTP_PORT
  http_only: $HTTP_ONLY

# ============================================================================
# CVaaS Configuration
# ============================================================================
cvaas:
  address: "$CV_ADDR"
  enrollment_token: "$ENROLLMENT_TOKEN"
  proxy: "$CV_PROXY"
  eos_url: "$EOS_URL"
  ntp_server: "$NTP_SERVER"

# ============================================================================
# SSL Certificate Configuration
# ============================================================================
ssl:
  cert_file: "$CERT_FILE"
  key_file: "$KEY_FILE"
  use_letsencrypt: $USE_LETSENCRYPT
  letsencrypt_email: "$LETSENCRYPT_EMAIL"
  create_self_signed: $CREATE_SELF_SIGNED

# ============================================================================
# Container Configuration
# ============================================================================
container:
  name: "$CONTAINER_NAME"
  image: "$CONTAINER_IMAGE"
  timezone: "$TIMEZONE"
  host_network: $HOST_NETWORK
  dns:
    - "$DNS1"
    - "$DNS2"

# ============================================================================
# Service Configuration
# ============================================================================
service:
  health_interval: "$HEALTH_INTERVAL"
  health_timeout: "$HEALTH_TIMEOUT"
  health_retries: $HEALTH_RETRIES
  health_start_period: "$HEALTH_START_PERIOD"
  restart_policy: "$RESTART_POLICY"
EOF
    
    log "Configuration saved to: $CONFIG_FILE"
    echo ""
    
    # Show summary
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${GREEN}Configuration Summary${NC}                                    ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log "Service Directory: $SCRIPT_DIR"
    log "Domain: $DOMAIN"
    log "IPv4: ${IPV4:-host network}"
    log "IPv6: ${IPV6:-disabled}"
    log "CVaaS Address: $CV_ADDR"
    log "Enrollment Token: ${ENROLLMENT_TOKEN:0:20}... (hidden)"
    echo ""
    
    prompt_yes_no "Apply this configuration to all files now?" "y" APPLY_NOW
    
    if [[ "$APPLY_NOW" == "true" ]]; then
        # Create directories before applying config
        create_directories
        
        # Copy source files to target directory
        copy_source_files
        
        if [[ -f "update-config.sh" ]]; then
            log "Running update-config.sh to apply configuration..."
            QUIET=true bash update-config.sh "$CONFIG_FILE"
        else
            warn "update-config.sh not found. Please run it manually:"
            warn "  bash update-config.sh $CONFIG_FILE"
        fi
    else
        log "Configuration saved. To apply later, run:"
        log "  bash update-config.sh $CONFIG_FILE"
        log ""
        log "Note: Directories will be created automatically when you apply the config."
    fi
}

# Check prerequisites
check_prerequisites() {
    local missing_deps=()
    
    # Check for yq (required for YAML parsing)
    if ! command -v yq >/dev/null 2>&1; then
        missing_deps+=("yq")
        error "yq is required but not installed."
        echo ""
        info "Install yq:"
        echo "  macOS:    brew install yq"
        echo "  Debian:   sudo apt-get install yq"
        echo "  RHEL:     sudo dnf install yq"
        echo "  Or visit: https://github.com/mikefarah/yq"
        echo ""
        return 1
    fi
    
    # Check if config template exists
    if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
        error "Configuration template not found: $CONFIG_TEMPLATE"
        return 1
    fi
    
    return 0
}

# Main function
main() {
    # Check prerequisites first
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Check if running as root (optional for interactive mode)
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root. Some operations may require sudo."
    fi
    
    # Try to load existing config
    load_existing_config || true
    
    # Run interactive configuration
    interactive_config
    
    # Generate YAML config
    generate_yaml_config
    
    log "Interactive setup completed!"
    echo ""
    if [[ "$APPLY_NOW" == "true" ]]; then
        log "Configuration has been applied to all files."
        log ""
        log "Next steps:"
        log "  1. Review the updated files if needed"
        log "  2. Run: sudo ./setup.sh"
        log "  3. Or run: sudo ./setup.sh --http-only (for testing)"
    else
        log "Next steps:"
        log "  1. Review config.yaml"
        log "  2. Run: ./update-config.sh config.yaml (to apply configuration)"
        log "  3. Then run: sudo ./setup.sh"
    fi
}

# Run main function
main "$@"
