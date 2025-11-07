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
CONFIGURED_SCRIPT="${SCRIPT_DIR}/bootstrap_configured.py"
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

# Generate configured bootstrap script
generate_bootstrap_script() {
    log "Generating configured bootstrap script..."
    
    # Create a copy of the original script
    cp "$BOOTSTRAP_SCRIPT" "$CONFIGURED_SCRIPT"
    
    # Replace the environment variable calls with actual values
    sed -i "s|os.environ.get('CV_ADDR', \"\")|\"$CV_ADDR\"|g" "$CONFIGURED_SCRIPT"
    sed -i "s|os.environ.get('ENROLLMENT_TOKEN', \"\")|\"$ENROLLMENT_TOKEN\"|g" "$CONFIGURED_SCRIPT"
    sed -i "s|os.environ.get('CV_PROXY', \"\")|\"${CV_PROXY:-}\"|g" "$CONFIGURED_SCRIPT"
    sed -i "s|os.environ.get('EOS_URL', \"\")|\"${EOS_URL:-}\"|g" "$CONFIGURED_SCRIPT"
    sed -i "s|os.environ.get('NTP_SERVER', \"\")|\"${NTP_SERVER:-}\"|g" "$CONFIGURED_SCRIPT"
    
    # Make the script executable
    chmod +x "$CONFIGURED_SCRIPT"
    
    log "Configured bootstrap script generated: $CONFIGURED_SCRIPT"
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

# Update systemd quadlet for HTTP-only mode
update_quadlet_http_only() {
    local quadlet_file="/etc/containers/systemd/ztpbootstrap/ztpbootstrap.container"
    
    if [[ ! -f "$quadlet_file" ]]; then
        warn "Quadlet file not found: $quadlet_file"
        warn "You may need to manually update the container configuration"
        return
    fi
    
    log "Updating systemd quadlet for HTTP-only mode..."
    
    # Backup original quadlet file
    if [[ ! -f "${quadlet_file}.backup" ]]; then
        cp "$quadlet_file" "${quadlet_file}.backup"
        log "Backed up original quadlet file to ${quadlet_file}.backup"
    fi
    
    # Update quadlet file to remove certificate volume and change port
    sed -i 's|PublishPort=443:443|PublishPort=80:80|g' "$quadlet_file"
    sed -i '/Volume=.*certs.*wild/d' "$quadlet_file"
    
    log "Quadlet file updated for HTTP-only mode"
}

# Reload systemd and start service
start_service() {
    log "Reloading systemd daemon..."
    systemctl daemon-reload
    
    log "Enabling ztpbootstrap service..."
    # Service is transient/generated, skip enable step
    log "Service is transient, skipping enable step"
    
    log "Starting ztpbootstrap service..."
    if systemctl start ztpbootstrap; then
        log "Service started successfully"
    else
        error "Failed to start service"
    fi
}

# Check service status
check_service_status() {
    log "Checking service status..."
    systemctl status ztpbootstrap --no-pager -l
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
        read -p "Are you sure you want to continue with HTTP-only setup? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Setup cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    check_env_file
    load_env
    generate_bootstrap_script
    
    if [[ "$HTTP_ONLY" == "true" ]]; then
        configure_http_only
        update_quadlet_http_only
        log "HTTP-only mode configured"
        log "Remember to update your DHCP configuration to use HTTP instead of HTTPS:"
        log "  option bootfile-name \"http://$DOMAIN/bootstrap.py\";"
    else
        # Check SSL certificates
        if ! check_ssl_certificates; then
            warn "SSL certificates not found or invalid"
            warn "Skipping SSL certificate setup"
            warn "You will need to obtain valid SSL certificates before starting the service"
            warn "Consider using Let's Encrypt with certbot (can be automated)"
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
