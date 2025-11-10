#!/bin/bash
# Setup script for Arista ZTP Bootstrap Service
# This script configures the bootstrap script and sets up SSL certificates

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="/opt/containerdata/ztpbootstrap"
ENV_FILE="${SCRIPT_DIR}/ztpbootstrap.env"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap.py"
NGINX_CONF="${SCRIPT_DIR}/nginx.conf"
CERT_DIR="/opt/containerdata/certs/wild"
DOMAIN="ztpboot.example.com"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
    exit 1
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --http-only    Configure service to use HTTP only (NOT RECOMMENDED)
                   WARNING: This is insecure and should only be used in isolated lab environments.
                   Let's Encrypt certificates can be fully automated with certbot.

Examples:
    $0                    # Standard HTTPS setup
    $0 --http-only        # HTTP-only setup (insecure, not recommended)

EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --http-only)
                HTTP_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Check if environment file exists
check_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error "Environment file not found: $ENV_FILE"
    fi
    log "Found environment file: $ENV_FILE"
}

# Source environment variables
load_env() {
    log "Loading environment variables..."
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    
    # Validate required variables
    if [[ -z "${CV_ADDR:-}" ]]; then
        error "CV_ADDR is not set in environment file"
    fi
    
    if [[ -z "${ENROLLMENT_TOKEN:-}" ]]; then
        error "ENROLLMENT_TOKEN is not set in environment file"
    fi
    
    log "Environment variables loaded successfully"
    log "CVaaS Address: $CV_ADDR"
    log "Enrollment Token: ${ENROLLMENT_TOKEN:0:20}..."
}


# Check SSL certificates
check_ssl_certificates() {
    log "Checking SSL certificates for $DOMAIN..."
    
    if [[ ! -d "$CERT_DIR" ]]; then
        warn "Certificate directory not found: $CERT_DIR"
        warn "You may need to obtain SSL certificates for $DOMAIN"
        return 1
    fi
    
    local cert_file="${CERT_DIR}/fullchain.pem"
    local key_file="${CERT_DIR}/privkey.pem"
    
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        warn "SSL certificate files not found:"
        warn "  Certificate: $cert_file"
        warn "  Private Key: $key_file"
        warn "You may need to obtain SSL certificates for $DOMAIN"
        return 1
    fi
    
    # Check certificate validity
    if openssl x509 -in "$cert_file" -text -noout | grep -q "$DOMAIN"; then
        log "SSL certificate found and appears valid for $DOMAIN"
        return 0
    else
        warn "SSL certificate may not be valid for $DOMAIN"
        return 1
    fi
}

# Setup SSL certificates using certbot (if available)
setup_ssl_certificates() {
    log "Setting up SSL certificates..."
    
    if command -v certbot >/dev/null 2>&1; then
        log "Certbot found, attempting to obtain SSL certificate..."
        
        # Check if we can obtain a certificate
        if certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email admin@example.com \
            --domains "$DOMAIN" \
            --cert-path "$CERT_DIR"; then
            log "SSL certificate obtained successfully"
        else
            warn "Failed to obtain SSL certificate with certbot"
            warn "You may need to manually obtain SSL certificates for $DOMAIN"
        fi
    else
        warn "Certbot not found. You may need to manually obtain SSL certificates for $DOMAIN"
        warn "Consider using Let's Encrypt or another certificate authority"
    fi
}

# Check if a path is on an NFS filesystem
# Returns 0 if NFS, 1 if not NFS
is_nfs_mount() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 1
    fi
    
    # Resolve the path to its actual location
    local resolved_path
    resolved_path=$(readlink -f "$path" 2>/dev/null || realpath "$path" 2>/dev/null || echo "$path")
    
    # Check if the path is on an NFS mount using findmnt or mount
    if command -v findmnt >/dev/null 2>&1; then
        if findmnt -n -o FSTYPE -T "$resolved_path" 2>/dev/null | grep -qi "^nfs"; then
            return 0
        fi
    elif command -v mount >/dev/null 2>&1; then
        if mount | grep -E "^[^ ]+ on $resolved_path" | grep -qi "type nfs"; then
            return 0
        fi
    fi
    
    # Check parent directories if the path itself doesn't exist yet
    local check_path="$resolved_path"
    while [[ "$check_path" != "/" ]] && [[ ! -e "$check_path" ]]; do
        check_path=$(dirname "$check_path")
    done
    
    if [[ -n "$check_path" ]] && [[ "$check_path" != "/" ]]; then
        if command -v findmnt >/dev/null 2>&1; then
            if findmnt -n -o FSTYPE -T "$check_path" 2>/dev/null | grep -qi "^nfs"; then
                return 0
            fi
        elif command -v mount >/dev/null 2>&1; then
            if mount | grep -E "^[^ ]+ on $check_path" | grep -qi "type nfs"; then
                return 0
            fi
        fi
    fi
    
    return 1
}

# Create logs directory with proper permissions and SELinux context
setup_logs_directory() {
    log "Setting up logs directory..."
    
    # Create logs directory for nginx logs
    mkdir -p "${SCRIPT_DIR}/logs" || {
        warn "Failed to create logs directory: ${SCRIPT_DIR}/logs"
        return 1
    }
    
    # Set permissions for nginx to write logs (nginx runs as UID 101 in alpine image)
    chmod 777 "${SCRIPT_DIR}/logs" 2>/dev/null || true
    
    # Try to set ownership to nginx user (UID 101) if possible
    if command -v chown >/dev/null 2>&1; then
        chown 101:101 "${SCRIPT_DIR}/logs" 2>/dev/null || chmod 777 "${SCRIPT_DIR}/logs" 2>/dev/null || true
    fi
    
    # Set SELinux context for logs directory (if SELinux is enabled and not on NFS)
    # NFS doesn't support SELinux contexts, so we skip chcon for NFS mounts
    if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        if ! is_nfs_mount "${SCRIPT_DIR}/logs"; then
            chcon -R -t container_file_t "${SCRIPT_DIR}/logs" 2>/dev/null || true
            log "Set SELinux context for logs directory (not NFS)"
        else
            log "Logs directory is on NFS, skipping SELinux context (NFS doesn't support SELinux contexts)"
        fi
    fi
    
    log "Created logs directory: ${SCRIPT_DIR}/logs"
    return 0
}

# Create a simple self-signed certificate for testing
create_self_signed_cert() {
    log "Creating self-signed certificate for testing..."
    
    local cert_file="${CERT_DIR}/fullchain.pem"
    local key_file="${CERT_DIR}/privkey.pem"
    
    # Create certificate directory if it doesn't exist
    mkdir -p "$CERT_DIR"
    
    # Generate self-signed certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN"
    
    # Set proper permissions and SELinux context (if SELinux is enabled and not on NFS)
    chmod 644 "$cert_file" 2>/dev/null || true
    chmod 644 "$key_file" 2>/dev/null || true
    if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        # Set container_file_t context for container access (only if not on NFS)
        if ! is_nfs_mount "$CERT_DIR"; then
            chcon -R -t container_file_t "$CERT_DIR" 2>/dev/null || true
            log "Set SELinux context for certificate directory (not NFS)"
        else
            log "Certificate directory is on NFS, skipping SELinux context (NFS doesn't support SELinux contexts)"
        fi
    fi
    
    # Also set SELinux context for script directory to allow webui uploads (only if not on NFS)
    if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        if ! is_nfs_mount "$SCRIPT_DIR"; then
            chcon -R -t container_file_t "$SCRIPT_DIR" 2>/dev/null || true
            log "Set SELinux context for script directory (allows webui uploads, not NFS)"
        else
            log "Script directory is on NFS, skipping SELinux context (NFS doesn't support SELinux contexts)"
        fi
    fi
    
    log "Self-signed certificate created for testing"
    warn "This is a self-signed certificate and should not be used in production"
}

# Configure nginx for HTTP-only mode
configure_http_only() {
    log "Configuring nginx for HTTP-only mode..."
    
    if [[ ! -f "$NGINX_CONF" ]]; then
        error "Nginx configuration file not found: $NGINX_CONF"
    fi
    
    # Backup original nginx.conf
    if [[ ! -f "${NGINX_CONF}.backup" ]]; then
        cp "$NGINX_CONF" "${NGINX_CONF}.backup"
        log "Backed up original nginx.conf to ${NGINX_CONF}.backup"
    fi
    
    # Create HTTP-only nginx configuration
    cat > "$NGINX_CONF" << 'NGINX_EOF'
# Nginx configuration for Arista ZTP Bootstrap Service
# HTTP-ONLY MODE (NOT RECOMMENDED FOR PRODUCTION)
# WARNING: This configuration is insecure and should only be used in isolated lab environments

# Main server block for HTTP
server {
    listen 80;
    listen [::]:80;
    server_name ztpboot.example.com 10.0.0.10 2001:db8::10;
    
    # Root directory for serving files
    root /usr/share/nginx/html;
    index bootstrap.py;
    
    # Logging
    access_log /var/log/nginx/ztpbootstrap_access.log;
    error_log /var/log/nginx/ztpbootstrap_error.log;
    
    # Main location block
    location / {
        try_files $uri $uri/ =404;
        
        # Set proper MIME type for Python scripts
        location ~* \.py$ {
            add_header Content-Type "text/plain; charset=utf-8";
            add_header Content-Disposition "attachment; filename=bootstrap.py";
        }
        
        # Cache control for bootstrap script
        location = /bootstrap.py {
            add_header Cache-Control "no-cache, no-store, must-revalidate";
            add_header Pragma "no-cache";
            add_header Expires "0";
            add_header Content-Type "text/plain; charset=utf-8";
            add_header Content-Disposition "attachment; filename=bootstrap.py";
        }
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Deny access to backup files
    location ~ ~$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}

# Default server block to catch any other requests
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Return 444 to close connection for invalid requests
    return 444;
}
NGINX_EOF
    
    log "Nginx configured for HTTP-only mode"
    warn "HTTP-only mode is insecure and should not be used in production"
    warn "Consider using Let's Encrypt with automated renewal instead"
}

# Check prerequisites before setup
check_setup_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Podman
    if ! command -v podman >/dev/null 2>&1; then
        error "Podman is not installed. Please install Podman first."
        echo ""
        info "Install Podman:"
        echo "  Fedora/RHEL: sudo dnf install podman"
        echo "  Ubuntu/Debian: sudo apt-get install podman"
        echo "  See: https://podman.io/getting-started/installation"
        return 1
    fi
    log "✓ Podman found: $(podman --version)"
    
    # Check macvlan network
    if ! podman network exists ztpbootstrap-net 2>/dev/null; then
        error "Macvlan network 'ztpbootstrap-net' not found"
        echo ""
        warn "The macvlan network must exist before starting the pod."
        warn "Run './check-macvlan.sh' to check network status and get instructions."
        echo ""
        info "The network must be created manually. See check-macvlan.sh for instructions."
        echo ""
        return 1
    else
        log "✓ Macvlan network 'ztpbootstrap-net' found"
    fi
    
    return 0
}

# Setup Podman pod with containers
setup_pod() {
    log "Setting up Podman pod with containers..."
    
    # Get the directory where this script is located (repository directory)
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    mkdir -p "$systemd_dir"
    
    # Copy pod and container files from repository
    if [[ -f "${repo_dir}/systemd/ztpbootstrap.pod" ]]; then
        cp "${repo_dir}/systemd/ztpbootstrap.pod" "$systemd_dir/"
        log "Pod configuration installed"
        
        # Update pod file with IP addresses from config.yaml if it exists
        local pod_file="${systemd_dir}/ztpbootstrap.pod"
        # Check for config.yaml in repo directory or current directory
        local config_file=""
        if [[ -f "${repo_dir}/config.yaml" ]]; then
            config_file="${repo_dir}/config.yaml"
        elif [[ -f "./config.yaml" ]]; then
            config_file="./config.yaml"
        elif [[ -f "config.yaml" ]]; then
            config_file="config.yaml"
        fi
        
        if [[ -n "$config_file" ]] && [[ -f "$config_file" ]] && command -v yq >/dev/null 2>&1; then
            log "Found config.yaml at: $config_file"
            local host_network
            local ipv4
            local ipv6
            host_network=$(yq eval '.container.host_network' "$config_file" 2>/dev/null || echo "")
            ipv4=$(yq eval '.network.ipv4' "$config_file" 2>/dev/null || echo "")
            ipv6=$(yq eval '.network.ipv6' "$config_file" 2>/dev/null || echo "")
            
            log "Reading network config: host_network=$host_network, IPv4=$ipv4, IPv6=$ipv6"
            
            # Check if host network mode is enabled
            if [[ "$host_network" == "true" ]]; then
                # Set Network=host and remove IP addresses
                if sed -i.tmp "s|^Network=.*|Network=host|" "$pod_file" 2>/dev/null; then
                    rm -f "${pod_file}.tmp" 2>/dev/null || true
                    log "Set Network=host in pod file"
                else
                    warn "Failed to set Network=host in pod file"
                fi
                
                # Remove IP and IP6 lines when using host network
                if sed -i.tmp "/^IP=/d" "$pod_file" 2>/dev/null; then
                    rm -f "${pod_file}.tmp" 2>/dev/null || true
                    log "Removed IP address from pod file (host network mode)"
                fi
                if sed -i.tmp "/^IP6=/d" "$pod_file" 2>/dev/null; then
                    rm -f "${pod_file}.tmp" 2>/dev/null || true
                    log "Removed IP6 address from pod file (host network mode)"
                fi
            else
                # Not using host network - set Network to macvlan network
                if sed -i.tmp "s|^Network=.*|Network=ztpbootstrap-net|" "$pod_file" 2>/dev/null; then
                    rm -f "${pod_file}.tmp" 2>/dev/null || true
                    log "Set Network=ztpbootstrap-net in pod file"
                else
                    warn "Failed to set Network in pod file"
                fi
                
                # For HTTP-only mode (testing), use DHCP instead of static IPs
                if [[ "$HTTP_ONLY" == "true" ]]; then
                    # Remove static IPs to use DHCP
                    if sed -i.tmp "/^IP=/d" "$pod_file" 2>/dev/null; then
                        rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Removed IPv4 address from pod file (using DHCP for testing)"
                    fi
                    if sed -i.tmp "/^IP6=/d" "$pod_file" 2>/dev/null; then
                        rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Removed IPv6 address from pod file (using DHCP for testing)"
                    fi
                # Update or remove IPv4 address
                elif [[ -n "$ipv4" ]] && [[ "$ipv4" != "null" ]] && [[ "$ipv4" != "" ]]; then
                    if grep -q "^IP=" "$pod_file" 2>/dev/null; then
                        if sed -i.tmp "s|^IP=.*|IP=$ipv4|" "$pod_file" 2>/dev/null; then
                            rm -f "${pod_file}.tmp" 2>/dev/null || true
                            log "Updated pod IPv4 address to: $ipv4"
                            # Verify the update
                            local current_ip
                            current_ip=$(grep "^IP=" "$pod_file" 2>/dev/null | cut -d= -f2 || echo "")
                            if [[ "$current_ip" == "$ipv4" ]]; then
                                log "Verified: Pod file now has IP=$current_ip"
                            else
                                warn "Warning: Pod file IP verification failed. Expected: $ipv4, Found: $current_ip"
                            fi
                        else
                            warn "Failed to update IPv4 address in pod file"
                        fi
                    else
                        # Add IP= line after Network= line
                        if sed -i.tmp "/^Network=/a IP=$ipv4" "$pod_file" 2>/dev/null; then
                            rm -f "${pod_file}.tmp" 2>/dev/null || true
                            log "Added IPv4 address: $ipv4"
                        else
                            warn "Failed to add IPv4 address to pod file"
                        fi
                    fi
                else
                    # Remove IP= line if IPv4 is empty
                    if sed -i.tmp "/^IP=/d" "$pod_file" 2>/dev/null; then
                        rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Removed IPv4 address from pod file"
                    fi
                fi
                
                # Update or remove IPv6 address (skip if HTTP_ONLY already handled above)
                if [[ "$HTTP_ONLY" != "true" ]] && [[ -n "$ipv6" ]] && [[ "$ipv6" != "null" ]] && [[ "$ipv6" != "" ]]; then
                    if grep -q "^IP6=" "$pod_file" 2>/dev/null; then
                        if sed -i.tmp "s|^IP6=.*|IP6=$ipv6|" "$pod_file" 2>/dev/null; then
                            rm -f "${pod_file}.tmp" 2>/dev/null || true
                            log "Updated pod IPv6 address to: $ipv6"
                        else
                            warn "Failed to update IPv6 address in pod file"
                        fi
                    else
                        # Add IP6= line after IP= line (or after Network= if no IP=)
                        if grep -q "^IP=" "$pod_file" 2>/dev/null; then
                            if sed -i.tmp "/^IP=/a IP6=$ipv6" "$pod_file" 2>/dev/null; then
                                rm -f "${pod_file}.tmp" 2>/dev/null || true
                                log "Added IPv6 address: $ipv6"
                            else
                                warn "Failed to add IPv6 address to pod file"
                            fi
                        else
                            if sed -i.tmp "/^Network=/a IP6=$ipv6" "$pod_file" 2>/dev/null; then
                                rm -f "${pod_file}.tmp" 2>/dev/null || true
                                log "Added IPv6 address: $ipv6"
                            else
                                warn "Failed to add IPv6 address to pod file"
                            fi
                        fi
                    fi
                elif [[ "$HTTP_ONLY" != "true" ]]; then
                    # Remove IP6= line if IPv6 is empty (disabled) - but not if HTTP_ONLY already handled it
                    if sed -i.tmp "/^IP6=/d" "$pod_file" 2>/dev/null; then
                        rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Removed IPv6 address from pod file (IPv6 disabled or will use DHCP)"
                    fi
                fi
            fi
        else
            if [[ -z "$config_file" ]]; then
                warn "config.yaml not found in repo directory or current directory"
            elif ! command -v yq >/dev/null 2>&1; then
                warn "yq not found - cannot read IP addresses from config.yaml"
            fi
        fi
    else
        error "Pod configuration file not found: ${repo_dir}/systemd/ztpbootstrap.pod"
        return 1
    fi
    
    if [[ -f "${repo_dir}/systemd/ztpbootstrap-nginx.container" ]]; then
        cp "${repo_dir}/systemd/ztpbootstrap-nginx.container" "$systemd_dir/"
        log "Nginx container configuration installed"
        
        local nginx_container_file="${systemd_dir}/ztpbootstrap-nginx.container"
        
        # Remove certs volume mount if using HTTP-only mode
        if [[ "$HTTP_ONLY" == "true" ]]; then
            if sed -i.tmp "/certs\/wild.*\/etc\/nginx\/ssl/d" "$nginx_container_file" 2>/dev/null; then
                rm -f "${nginx_container_file}.tmp" 2>/dev/null || true
                log "Removed SSL certificate volume mount from nginx container (HTTP-only mode)"
            fi
        fi
        
        # Remove PublishPort lines if using host networking
        if [[ -n "$config_file" ]] && [[ -f "$config_file" ]] && command -v yq >/dev/null 2>&1; then
            local host_network=$(yq eval '.container.host_network' "$config_file" 2>/dev/null || echo "")
            if [[ "$host_network" == "true" ]]; then
                if sed -i.tmp "/^PublishPort=/d" "$nginx_container_file" 2>/dev/null; then
                    rm -f "${nginx_container_file}.tmp" 2>/dev/null || true
                    log "Removed PublishPort directives from nginx container (host network mode)"
                fi
            fi
        fi
    else
        error "Nginx container configuration not found: ${repo_dir}/systemd/ztpbootstrap-nginx.container"
        return 1
    fi
    
    # Copy Web UI container and directory if webui exists
    if [[ -d "${repo_dir}/webui" ]] && [[ -f "${repo_dir}/systemd/ztpbootstrap-webui.container" ]]; then
        cp "${repo_dir}/systemd/ztpbootstrap-webui.container" "$systemd_dir/"
        log "Web UI container configuration installed"
        
        # Remove PublishPort lines if using host networking
        local webui_container_file="${systemd_dir}/ztpbootstrap-webui.container"
        if [[ -n "$config_file" ]] && [[ -f "$config_file" ]] && command -v yq >/dev/null 2>&1; then
            local host_network=$(yq eval '.container.host_network' "$config_file" 2>/dev/null || echo "")
            if [[ "$host_network" == "true" ]]; then
                if sed -i.tmp "/^PublishPort=/d" "$webui_container_file" 2>/dev/null; then
                    rm -f "${webui_container_file}.tmp" 2>/dev/null || true
                    log "Removed PublishPort directives from webui container (host network mode)"
                fi
                
                # Update nginx.conf to use localhost instead of container name for host networking
                if [[ -f "$NGINX_CONF" ]]; then
                    if sed -i.tmp "s|ztpbootstrap-webui:5000|127.0.0.1:5000|g" "$NGINX_CONF" 2>/dev/null; then
                        # Remove resolver lines (not needed with host networking)
                        sed -i.tmp "/resolver 127.0.0.11/d" "$NGINX_CONF" 2>/dev/null || true
                        rm -f "${NGINX_CONF}.tmp" 2>/dev/null || true
                        log "Updated nginx.conf for host networking (using localhost:5000 for webui)"
                    fi
                fi
            fi
        fi
        
        # Copy webui directory to script directory
        local webui_dest="${SCRIPT_DIR}/webui"
        if [[ ! -d "$webui_dest" ]]; then
            mkdir -p "$webui_dest" || {
                warn "Failed to create webui directory: $webui_dest"
                return 1
            }
        fi
        if cp -r "${repo_dir}/webui"/* "$webui_dest/" 2>/dev/null; then
            log "Web UI directory copied to: $webui_dest"
            # Ensure start-webui.sh is executable
            if [[ -f "${webui_dest}/start-webui.sh" ]]; then
                chmod +x "${webui_dest}/start-webui.sh" 2>/dev/null || true
                log "Made start-webui.sh executable"
            fi
        else
            warn "Failed to copy webui directory, Web UI may not work"
            warn "Source: ${repo_dir}/webui"
            warn "Destination: $webui_dest"
        fi
        
        # Ensure systemd recognizes the webui container file
        # This is important because systemd-quadlet needs to generate the service
        if [[ -f "${systemd_dir}/ztpbootstrap-webui.container" ]]; then
            log "Web UI container file installed: ${systemd_dir}/ztpbootstrap-webui.container"
        fi
    else
        warn "Web UI directory not found, Web UI container will not be included"
        warn "Service will run without Web UI"
    fi
    
    return 0
}

# Reload systemd and start service
start_service() {
    # Setup pod configuration first (copy files)
    if ! setup_pod; then
        error "Pod setup failed. Please create the macvlan network first."
        exit 1
    fi
    
    # Define systemd directory (same as in setup_pod)
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    
    # Reload systemd daemon after copying files so it recognizes the new services
    log "Reloading systemd daemon..."
    systemctl daemon-reload
    
    # Wait a moment for systemd to fully process the new services
    # Systemd quadlet generator needs time to process .container files
    sleep 2
    
    # Check if webui container file exists and try to ensure systemd recognizes it
    if [[ -f "${systemd_dir}/ztpbootstrap-webui.container" ]]; then
        log "WebUI container file found, ensuring systemd recognizes it..."
        # Manually run quadlet generator to ensure service is created
        # This is needed because systemd's automatic generator may not always process all files
        local webui_service_generated=false
        if command -v /usr/libexec/podman/quadlet >/dev/null 2>&1; then
            # Try to generate the service file
            local quadlet_output
            quadlet_output=$(/usr/libexec/podman/quadlet "${systemd_dir}/ztpbootstrap-webui.container" 2>&1)
            if [[ $? -eq 0 ]] && [[ -n "$quadlet_output" ]]; then
                # Check if service file was created in generator directory
                if [[ -f "/run/systemd/generator/ztpbootstrap-webui.service" ]]; then
                    log "WebUI service generated successfully by quadlet"
                    webui_service_generated=true
                else
                    # Try to write the output manually
                    echo "$quadlet_output" | grep -A 1000 "^---ztpbootstrap-webui.service---" | sed '1d' > /tmp/webui.service 2>/dev/null || true
                    if [[ -s /tmp/webui.service ]]; then
                        mv /tmp/webui.service /run/systemd/generator/ztpbootstrap-webui.service 2>/dev/null && {
                            log "WebUI service file created manually from quadlet output"
                            webui_service_generated=true
                        } || true
                    fi
                fi
            fi
        fi
        
        # Always ensure the service file includes the start-webui.sh command
        # Quadlet doesn't support Command= in Container section, so we need to add it manually
        if [[ -f "/run/systemd/generator/ztpbootstrap-webui.service" ]]; then
            # Update the ExecStart line to include the command if it's missing
            if ! grep -q "/app/start-webui.sh" /run/systemd/generator/ztpbootstrap-webui.service 2>/dev/null; then
                log "Adding /app/start-webui.sh command to webui service file..."
                # Use python for reliable multi-line replacement
                python3 -c "
import re
with open(\"/run/systemd/generator/ztpbootstrap-webui.service\", \"r\") as f:
    content = f.read()
# Replace docker.io/python:alpine at end of ExecStart line with docker.io/python:alpine /app/start-webui.sh
content = re.sub(r\"(docker\.io/python:alpine)(\s*$)\", r\"\1 /app/start-webui.sh\2\", content, flags=re.MULTILINE)
with open(\"/run/systemd/generator/ztpbootstrap-webui.service\", \"w\") as f:
    f.write(content)
" 2>/dev/null || {
                    # Fallback to sed if python not available
                    sed -i.tmp 's|docker\.io/python:alpine$|docker.io/python:alpine /app/start-webui.sh|g' /run/systemd/generator/ztpbootstrap-webui.service 2>/dev/null && rm -f /run/systemd/generator/ztpbootstrap-webui.service.tmp 2>/dev/null || true
                }
                log "Updated webui service file with start-webui.sh command"
            fi
        fi
        
        # If quadlet failed, create a basic service file manually
        if [[ "$webui_service_generated" == "false" ]]; then
            warn "Quadlet generator did not create webui service, creating manual service file..."
            cat > /run/systemd/generator/ztpbootstrap-webui.service << 'EOFWEBUI'
[Unit]
Description=ZTP Bootstrap Web UI Container
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap-webui.container
RequiresMountsFor=%t/containers
BindsTo=ztpbootstrap-pod.service
After=ztpbootstrap-pod.service

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman rm -v -f -i ztpbootstrap-webui
ExecStopPost=-/usr/bin/podman rm -v -f -i ztpbootstrap-webui
Delegate=yes
Type=notify
NotifyAccess=all
SyslogIdentifier=%N
ExecStart=/usr/bin/podman run --name ztpbootstrap-webui --replace --rm --cgroups=split --sdnotify=conmon -d --pod ztpbootstrap-pod -v /opt/containerdata/ztpbootstrap/webui:/app:ro -v /opt/containerdata/ztpbootstrap:/opt/containerdata/ztpbootstrap:rw -v /opt/containerdata/ztpbootstrap/logs:/var/log/nginx:rw -v /run/systemd/journal:/run/systemd/journal:ro -v /run/log/journal:/run/log/journal:ro -v /run/podman:/run/podman:ro -v /usr/bin/journalctl:/usr/bin/journalctl:ro -v /lib64/libsystemd.so.0:/lib64/libsystemd.so.0:ro -v /lib64/libsystemd.so.0.41.0:/lib64/libsystemd.so.0.41.0:ro -v /usr/lib64/systemd:/usr/lib64/systemd:ro --env TZ=UTC --env ZTP_CONFIG_DIR=/opt/containerdata/ztpbootstrap --env FLASK_APP=app.py --env FLASK_ENV=production docker.io/python:alpine /app/start-webui.sh

[Install]
WantedBy=multi-user.target default.target
EOFWEBUI
            log "Created manual WebUI service file"
        fi
        
        systemctl daemon-reload
        sleep 1
    fi
    
    log "Starting ztpbootstrap pod..."
    if systemctl start ztpbootstrap-pod; then
        log "Pod started successfully"
        # Wait a moment for pod to be ready
        sleep 2
    else
        error "Failed to start pod. Check logs with: journalctl -u ztpbootstrap-pod -f"
        return 1
    fi
    
    # Start nginx container
    log "Starting nginx container..."
    if systemctl start ztpbootstrap-nginx; then
        log "Nginx container started successfully"
        sleep 2
    else
        warn "Failed to start nginx container. Check logs with: journalctl -u ztpbootstrap-nginx -f"
    fi
    
    # Start webui container if it exists
    # Check both unit-files and if the service is available
    if systemctl list-unit-files | grep -q ztpbootstrap-webui.service || systemctl list-units --all | grep -q ztpbootstrap-webui.service; then
        log "Starting webui container..."
        if systemctl start ztpbootstrap-webui; then
            log "Webui container started successfully"
        else
            warn "Failed to start webui container. Check logs with: journalctl -u ztpbootstrap-webui -f"
        fi
    elif [[ -f "${systemd_dir}/ztpbootstrap-webui.container" ]]; then
        # Container file exists but service not generated - try manual start as fallback
        warn "WebUI container file exists but systemd service not found"
        warn "Attempting to start WebUI container manually..."
        if podman run -d --name ztpbootstrap-webui --pod ztpbootstrap-pod \
            -v /opt/containerdata/ztpbootstrap/webui:/app:ro \
            -v /opt/containerdata/ztpbootstrap:/opt/containerdata/ztpbootstrap:rw \
            -v /opt/containerdata/ztpbootstrap/logs:/var/log/nginx:rw \
            -e TZ=UTC \
            -e ZTP_CONFIG_DIR=/opt/containerdata/ztpbootstrap \
            -e FLASK_APP=app.py \
            docker.io/python:alpine \
            /bin/sh -c "pip install --no-cache-dir flask werkzeug && sleep 2 && python3 /app/app.py" 2>/dev/null; then
            log "WebUI container started manually"
        else
            warn "Failed to start WebUI container manually. It may already be running."
        fi
    else
        log "WebUI container file not found (this is OK if webui directory doesn't exist)"
    fi
}

# Check service status
check_service_status() {
    log "Checking pod status..."
    systemctl status ztpbootstrap-pod --no-pager -l
    
    log ""
    log "Container status:"
    podman pod ps --filter name=ztpbootstrap-pod
    podman ps --filter pod=ztpbootstrap-pod
}

# Main function
main() {
    log "Starting Arista ZTP Bootstrap Service setup..."
    
    parse_args "$@"
    check_root
    
    if [[ "$HTTP_ONLY" == "true" ]]; then
        warn "⚠️  WARNING: HTTP-only mode is enabled!"
        warn "This configuration is INSECURE and should only be used in isolated lab environments."
        warn "All traffic will be unencrypted and vulnerable to interception."
        warn "Let's Encrypt certificates can be fully automated with certbot and systemd timers."
        echo ""
        # No confirmation prompt - if user passed --http-only flag, they've already decided
        log "Proceeding with HTTP-only setup (flag provided, no confirmation required)"
        echo ""
    fi
    
    # Check prerequisites first
    if ! check_setup_prerequisites; then
        error "Prerequisites check failed. Please fix issues above and try again."
        exit 1
    fi
    
    check_env_file
    load_env
    
    # Always set up logs directory (required for nginx container)
    if ! setup_logs_directory; then
        warn "Failed to set up logs directory - nginx container may fail to start"
    fi
    
    if [[ "$HTTP_ONLY" == "true" ]]; then
        configure_http_only
        log "HTTP-only mode configured"
        log "Remember to update your DHCP configuration to use HTTP instead of HTTPS:"
        log "  option bootfile-name \"http://$DOMAIN/bootstrap.py\";"
    else
        # Check SSL certificates
        if ! check_ssl_certificates; then
            warn "SSL certificates not found or invalid"
            warn "Creating self-signed certificate for testing..."
            create_self_signed_cert
            warn "⚠️  Using self-signed certificate - not suitable for production"
            warn "Consider using Let's Encrypt with certbot for production (can be automated)"
        fi
    fi
    
    start_service
    check_service_status
    
    log "Setup completed successfully!"
    if [[ "$HTTP_ONLY" == "true" ]]; then
        log "The ZTP Bootstrap service is now running at: http://$DOMAIN"
        log "Bootstrap script available at: http://$DOMAIN/bootstrap.py"
        warn "⚠️  REMINDER: HTTP-only mode is insecure and should not be used in production!"
    else
        log "The ZTP Bootstrap service is now running at: https://$DOMAIN"
        log "Bootstrap script available at: https://$DOMAIN/bootstrap.py"
    fi
    log ""
    log "To configure the service, edit: $ENV_FILE"
    log "To view logs: journalctl -u ztpbootstrap -f"
    log "To restart service: systemctl restart ztpbootstrap"
}

# Run main function
main "$@"
