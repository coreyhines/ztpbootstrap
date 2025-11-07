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
    
    check_root
    check_env_file
    load_env
    generate_bootstrap_script
    
    # Check SSL certificates
    if ! check_ssl_certificates; then
        warn "SSL certificates not found or invalid"
        warn "Skipping SSL certificate setup"
        warn "You will need to obtain valid SSL certificates before starting the service"
    fi
    
    start_service
    check_service_status
    
    log "Setup completed successfully!"
    log "The ZTP Bootstrap service is now running at: https://$DOMAIN"
    log "Bootstrap script available at: https://$DOMAIN/bootstrap.py"
    log ""
    log "To configure the service, edit: $ENV_FILE"
    log "To view logs: journalctl -u ztpbootstrap -f"
    log "To restart service: systemctl restart ztpbootstrap"
}

# Run main function
main "$@"
