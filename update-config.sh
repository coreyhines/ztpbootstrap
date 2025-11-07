#!/bin/bash
# Update configuration files based on config.yaml
# This script reads the YAML configuration and updates all relevant files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONFIG_FILE="${1:-config.yaml}"

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

# Check if yq is available
check_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        error "yq is required to parse YAML configuration. Install it with:"
        error "  brew install yq  # macOS"
        error "  apt-get install yq  # Debian/Ubuntu"
        error "  or download from: https://github.com/mikefarah/yq"
    fi
}

# Read YAML values using yq
get_yaml_value() {
    local path="$1"
    yq eval "$path" "$CONFIG_FILE" 2>/dev/null || echo ""
}

# Copy source files to target directory
copy_source_files() {
    log "Copying source files to target directory..."
    
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Get target paths from config
    local bootstrap_script
    local nginx_conf
    
    bootstrap_script=$(get_yaml_value '.paths.bootstrap_script')
    nginx_conf=$(get_yaml_value '.paths.nginx_conf')
    
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

# Create all necessary directories from config
create_directories() {
    log "Creating necessary directories..."
    
    local script_dir
    local cert_dir
    local env_file
    local quadlet_file
    local dirs_to_create=()
    
    script_dir=$(get_yaml_value '.paths.script_dir')
    cert_dir=$(get_yaml_value '.paths.cert_dir')
    env_file=$(get_yaml_value '.paths.env_file')
    quadlet_file=$(get_yaml_value '.paths.quadlet_file')
    
    # Collect all directories that need to be created
    if [[ -n "$script_dir" ]] && [[ "$script_dir" != "null" ]]; then
        dirs_to_create+=("$script_dir")
    fi
    
    if [[ -n "$cert_dir" ]] && [[ "$cert_dir" != "null" ]]; then
        dirs_to_create+=("$cert_dir")
    fi
    
    if [[ -n "$env_file" ]] && [[ "$env_file" != "null" ]]; then
        local env_dir
        env_dir=$(dirname "$env_file")
        dirs_to_create+=("$env_dir")
    fi
    
    if [[ -n "$quadlet_file" ]] && [[ "$quadlet_file" != "null" ]]; then
        local quadlet_dir
        quadlet_dir=$(dirname "$quadlet_file")
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

# Update bootstrap.py with CVaaS configuration
update_bootstrap_py() {
    local bootstrap_file
    bootstrap_file=$(get_yaml_value '.paths.bootstrap_script')
    
    if [[ ! -f "$bootstrap_file" ]]; then
        warn "Bootstrap script not found: $bootstrap_file"
        return
    fi
    
    log "Updating bootstrap.py..."
    
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
    
    # Update cvAddr
    if [[ -n "$cv_addr" ]]; then
        sed -i.tmp "s|^cvAddr = .*|cvAddr = \"$cv_addr\"|" "$bootstrap_file"
    fi
    
    # Update enrollmentToken
    if [[ -n "$enrollment_token" ]]; then
        # Escape special characters for sed
        enrollment_token_escaped=$(printf '%s\n' "$enrollment_token" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i.tmp "s|^enrollmentToken = .*|enrollmentToken = \"$enrollment_token_escaped\"|" "$bootstrap_file"
    fi
    
    # Update cvproxy
    if [[ -n "$cv_proxy" ]]; then
        sed -i.tmp "s|^cvproxy = .*|cvproxy = \"$cv_proxy\"|" "$bootstrap_file"
    else
        sed -i.tmp "s|^cvproxy = .*|cvproxy = \"\"|" "$bootstrap_file"
    fi
    
    # Update eosUrl
    if [[ -n "$eos_url" ]]; then
        sed -i.tmp "s|^eosUrl = .*|eosUrl = \"$eos_url\"|" "$bootstrap_file"
    else
        sed -i.tmp "s|^eosUrl = .*|eosUrl = \"\"|" "$bootstrap_file"
    fi
    
    # Update ntpServer
    if [[ -n "$ntp_server" ]]; then
        sed -i.tmp "s|^ntpServer = .*|ntpServer = \"$ntp_server\"|" "$bootstrap_file"
    fi
    
    rm -f "${bootstrap_file}.tmp"
    log "Updated bootstrap.py"
}

# Update nginx.conf with network configuration
update_nginx_conf() {
    local nginx_file
    nginx_file=$(get_yaml_value '.paths.nginx_conf')
    
    if [[ ! -f "$nginx_file" ]]; then
        warn "Nginx config not found: $nginx_file"
        return
    fi
    
    log "Updating nginx.conf..."
    
    local domain
    local ipv4
    local ipv6
    local https_port
    local http_only
    
    domain=$(get_yaml_value '.network.domain')
    ipv4=$(get_yaml_value '.network.ipv4')
    ipv6=$(get_yaml_value '.network.ipv6')
    https_port=$(get_yaml_value '.network.https_port')
    http_only=$(get_yaml_value '.network.http_only')
    
    # Build server_name line
    local server_name="$domain"
    if [[ -n "$ipv4" ]] && [[ "$ipv4" != "null" ]]; then
        server_name="$server_name $ipv4"
    fi
    if [[ -n "$ipv6" ]] && [[ "$ipv6" != "null" ]]; then
        server_name="$server_name $ipv6"
    fi
    
    # Update server_name in all server blocks
    sed -i.tmp "s|server_name .*;|server_name $server_name;|g" "$nginx_file"
    
    # Update ports if needed
    if [[ "$http_only" == "true" ]]; then
        # HTTP-only mode - remove SSL and update ports
        sed -i.tmp "s|listen 443 ssl http2;|listen 80;|g" "$nginx_file"
        sed -i.tmp "s|listen \[::\]:443 ssl http2;|listen [::]:80;|g" "$nginx_file"
    else
        # HTTPS mode - ensure correct ports
        sed -i.tmp "s|listen 443 ssl http2;|listen $https_port ssl http2;|g" "$nginx_file"
        sed -i.tmp "s|listen \[::\]:443 ssl http2;|listen [::]:$https_port ssl http2;|g" "$nginx_file"
    fi
    
    rm -f "${nginx_file}.tmp"
    log "Updated nginx.conf"
}

# Update environment file
update_env_file() {
    local env_file
    env_file=$(get_yaml_value '.paths.env_file')
    
    log "Updating environment file: $env_file"
    
    # Create directory if needed
    local env_dir
    env_dir=$(dirname "$env_file")
    mkdir -p "$env_dir"
    
    local cv_addr
    local enrollment_token
    local cv_proxy
    local eos_url
    local ntp_server
    local domain
    local timezone
    local https_port
    
    cv_addr=$(get_yaml_value '.cvaas.address')
    enrollment_token=$(get_yaml_value '.cvaas.enrollment_token')
    cv_proxy=$(get_yaml_value '.cvaas.proxy')
    eos_url=$(get_yaml_value '.cvaas.eos_url')
    ntp_server=$(get_yaml_value '.cvaas.ntp_server')
    domain=$(get_yaml_value '.network.domain')
    timezone=$(get_yaml_value '.container.timezone')
    https_port=$(get_yaml_value '.network.https_port')
    
    cat > "$env_file" << EOF
# Arista ZTP Bootstrap Configuration
# Generated from config.yaml on $(date)

# CVaaS Configuration
CV_ADDR=$cv_addr
ENROLLMENT_TOKEN=$enrollment_token
CV_PROXY=$cv_proxy
EOS_URL=$eos_url
NTP_SERVER=$ntp_server

# Container Configuration
TZ=$timezone
NGINX_HOST=$domain
NGINX_PORT=$https_port
EOF
    
    log "Updated environment file"
}

# Update systemd quadlet file
update_quadlet_file() {
    local quadlet_file
    quadlet_file=$(get_yaml_value '.paths.quadlet_file')
    
    log "Updating systemd quadlet file: $quadlet_file"
    
    # Create directory if needed
    local quadlet_dir
    quadlet_dir=$(dirname "$quadlet_file")
    mkdir -p "$quadlet_dir"
    
    local script_dir
    local cert_dir
    local nginx_conf
    local container_name
    local container_image
    local timezone
    local host_network
    local ipv4
    local ipv6
    local dns1
    local dns2
    local https_port
    local http_only
    local health_interval
    local health_timeout
    local health_retries
    local health_start_period
    local restart_policy
    
    script_dir=$(get_yaml_value '.paths.script_dir')
    cert_dir=$(get_yaml_value '.paths.cert_dir')
    nginx_conf=$(get_yaml_value '.paths.nginx_conf')
    container_name=$(get_yaml_value '.container.name')
    container_image=$(get_yaml_value '.container.image')
    timezone=$(get_yaml_value '.container.timezone')
    host_network=$(get_yaml_value '.container.host_network')
    ipv4=$(get_yaml_value '.network.ipv4')
    ipv6=$(get_yaml_value '.network.ipv6')
    dns1=$(get_yaml_value '.container.dns[0]')
    dns2=$(get_yaml_value '.container.dns[1]')
    https_port=$(get_yaml_value '.network.https_port')
    http_only=$(get_yaml_value '.network.http_only')
    health_interval=$(get_yaml_value '.service.health_interval')
    health_timeout=$(get_yaml_value '.service.health_timeout')
    health_retries=$(get_yaml_value '.service.health_retries')
    health_start_period=$(get_yaml_value '.service.health_start_period')
    restart_policy=$(get_yaml_value '.service.restart_policy')
    
    local port=$https_port
    if [[ "$http_only" == "true" ]]; then
        port=$(get_yaml_value '.network.http_port')
    fi
    
    cat > "$quadlet_file" << EOF
[Unit]
Description=ZTP Bootstrap Script Server for Arista CVaaS

[Container]
ContainerName=$container_name
Image=$container_image
EOF
    
    if [[ "$host_network" == "true" ]]; then
        echo "Network=host" >> "$quadlet_file"
    else
        if [[ -n "$ipv4" ]] && [[ "$ipv4" != "null" ]]; then
            echo "IP=$ipv4" >> "$quadlet_file"
        fi
        if [[ -n "$ipv6" ]] && [[ "$ipv6" != "null" ]]; then
            echo "IP6=$ipv6" >> "$quadlet_file"
        fi
        if [[ -n "$dns1" ]] && [[ "$dns1" != "null" ]]; then
            echo "DNS=$dns1" >> "$quadlet_file"
        fi
        if [[ -n "$dns2" ]] && [[ "$dns2" != "null" ]]; then
            echo "DNS=$dns2" >> "$quadlet_file"
        fi
    fi
    
    cat >> "$quadlet_file" << EOF
PublishPort=$port:$port
Volume=$script_dir:/usr/share/nginx/html:ro
Volume=$nginx_conf:/etc/nginx/conf.d/default.conf:ro
EOF
    
    # Only add cert volume if not HTTP-only
    if [[ "$http_only" != "true" ]]; then
        echo "Volume=$cert_dir:/etc/nginx/ssl:ro" >> "$quadlet_file"
    fi
    
    cat >> "$quadlet_file" << EOF
Environment="TZ=$timezone"

# Health check for ZTP bootstrap
HealthCmd=["sh", "-c", "pgrep nginx > /dev/null || exit 1"]
HealthInterval=$health_interval
HealthTimeout=$health_timeout
HealthRetries=$health_retries
HealthStartPeriod=$health_start_period

[Service]
Restart=$restart_policy

[Install]
WantedBy=default.target
EOF
    
    log "Updated systemd quadlet file"
}

# Update setup.sh with new paths
update_setup_sh() {
    local setup_file="setup.sh"
    
    if [[ ! -f "$setup_file" ]]; then
        warn "setup.sh not found"
        return
    fi
    
    log "Updating setup.sh with new paths..."
    
    local script_dir
    local cert_dir
    local domain
    
    script_dir=$(get_yaml_value '.paths.script_dir')
    cert_dir=$(get_yaml_value '.paths.cert_dir')
    domain=$(get_yaml_value '.network.domain')
    
    # Update SCRIPT_DIR
    sed -i.tmp "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$script_dir\"|" "$setup_file"
    
    # Update CERT_DIR
    sed -i.tmp "s|^CERT_DIR=.*|CERT_DIR=\"$cert_dir\"|" "$setup_file"
    
    # Update DOMAIN
    sed -i.tmp "s|^DOMAIN=.*|DOMAIN=\"$domain\"|" "$setup_file"
    
    rm -f "${setup_file}.tmp"
    log "Updated setup.sh"
}

# Show configuration diff
show_diff() {
    if [[ -f "config-diff.sh" ]]; then
        log "Showing configuration diff..."
        bash config-diff.sh "$CONFIG_FILE"
        echo ""
    fi
}

# Main function
main() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Configuration file not found: $CONFIG_FILE"
    fi
    
    log "Reading configuration from: $CONFIG_FILE"
    
    check_yq
    
    # Create directories before validation
    create_directories
    
    # Copy source files to target directory
    copy_source_files
    
    # Validate configuration first
    if [[ -f "validate-config.sh" ]]; then
        log "Validating configuration..."
        if ! bash validate-config.sh "$CONFIG_FILE"; then
            error "Configuration validation failed. Please fix errors before applying."
        fi
        echo ""
    fi
    
    # Show diff
    show_diff
    
    # Ask for confirmation
    echo -n -e "${YELLOW}Do you want to apply these changes? [y/N]: ${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Update cancelled by user"
        exit 0
    fi
    echo ""
    
    # Update all files
    update_bootstrap_py
    update_nginx_conf
    update_env_file
    update_quadlet_file
    update_setup_sh
    
    log ""
    log "Configuration update completed!"
    log ""
    log "Next steps:"
    log "  1. Review the updated files"
    log "  2. Run: sudo ./setup.sh"
    log "  3. Or run: sudo ./setup.sh --http-only (if HTTP-only mode is enabled)"
}

# Run main function
main "$@"
