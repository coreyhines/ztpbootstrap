#!/bin/bash
# Test script for ZTP Bootstrap Service
# This script tests the service without requiring enrollment token configuration

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="ztpboot.example.com"
IPV4="10.0.0.10"
IPV6="2001:db8::10"
NGINX_CONF="/opt/containerdata/ztpbootstrap/nginx.conf"
HTTP_ONLY=false

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

# Test network connectivity
test_network() {
    log "Testing network configuration..."
    
    # Check if IPs are assigned
    if ip addr show | grep -q "$IPV4"; then
        log "IPv4 address $IPV4 is assigned"
    else
        warn "IPv4 address $IPV4 is not assigned"
    fi
    
    if ip addr show | grep -q "$IPV6"; then
        log "IPv6 address $IPV6 is assigned"
    else
        warn "IPv6 address $IPV6 is not assigned"
    fi
}

# Detect HTTP-only mode
detect_http_only() {
    if [[ -f "$NGINX_CONF" ]]; then
        if grep -q "HTTP-ONLY MODE" "$NGINX_CONF" || ! grep -q "listen 443 ssl" "$NGINX_CONF"; then
            HTTP_ONLY=true
            log "HTTP-only mode detected in nginx configuration"
            warn "⚠️  WARNING: HTTP-only mode is insecure and should not be used in production!"
        fi
    fi
}

# Test SSL certificates
test_ssl_certificates() {
    if [[ "$HTTP_ONLY" == "true" ]]; then
        warn "Skipping SSL certificate tests (HTTP-only mode)"
        return 0
    fi
    
    log "Testing SSL certificates..."
    
    local cert_file="/opt/containerdata/certs/wild/fullchain.pem"
    local key_file="/opt/containerdata/certs/wild/privkey.pem"
    
    if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
        log "SSL certificate files found"
        
        # Check certificate validity
        if openssl x509 -in "$cert_file" -text -noout | grep -q "*.example.com"; then
            log "SSL certificate covers *.example.com"
        else
            warn "SSL certificate may not cover *.example.com"
        fi
        
        # Check certificate expiration
        local expiry=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
        log "Certificate expires: $expiry"
    else
        error "SSL certificate files not found"
    fi
}

# Test container configuration
test_container_config() {
    log "Testing container configuration..."
    
    local quadlet_file="/etc/containers/systemd/ztpbootstrap/ztpbootstrap.container"
    
    if [[ -f "$quadlet_file" ]]; then
        log "Quadlet configuration file found"
        
        # Check if systemd can parse the file
        if systemd-analyze verify "$quadlet_file" 2>/dev/null; then
            log "Quadlet configuration is valid"
        else
            warn "Quadlet configuration may have issues"
        fi
    else
        error "Quadlet configuration file not found"
    fi
}

# Test nginx configuration
test_nginx_config() {
    log "Testing nginx configuration..."
    
    local nginx_conf="/opt/containerdata/ztpbootstrap/nginx.conf"
    
    if [[ -f "$nginx_conf" ]]; then
        log "Nginx configuration file found"
        
        # Test nginx configuration syntax
        if nginx -t -c "$nginx_conf" 2>/dev/null; then
            log "Nginx configuration syntax is valid"
        else
            warn "Nginx configuration syntax may have issues"
        fi
    else
        error "Nginx configuration file not found"
    fi
}

# Test service status
test_service_status() {
    log "Testing service status..."
    
    if systemctl is-enabled ztpbootstrap.container >/dev/null 2>&1; then
        log "Service is enabled"
    else
        warn "Service is not enabled"
    fi
    
    if systemctl is-active ztpbootstrap.container >/dev/null 2>&1; then
        log "Service is active"
        
        # Determine protocol and URL based on HTTP-only mode
        local protocol="https"
        local curl_opts="-k"
        if [[ "$HTTP_ONLY" == "true" ]]; then
            protocol="http"
            curl_opts=""
            warn "Testing HTTP endpoints (insecure mode)"
        fi
        
        # Test health endpoint
        if curl $curl_opts -s -f "$protocol://$DOMAIN/health" >/dev/null 2>&1; then
            log "Health endpoint is responding at $protocol://$DOMAIN/health"
        else
            warn "Health endpoint is not responding at $protocol://$DOMAIN/health"
        fi
        
        # Test bootstrap script endpoint
        if curl $curl_opts -s -f "$protocol://$DOMAIN/bootstrap.py" >/dev/null 2>&1; then
            log "Bootstrap script endpoint is responding at $protocol://$DOMAIN/bootstrap.py"
        else
            warn "Bootstrap script endpoint is not responding at $protocol://$DOMAIN/bootstrap.py"
        fi
    else
        warn "Service is not active"
    fi
}

# Test DNS resolution
test_dns() {
    log "Testing DNS resolution..."
    
    if nslookup "$DOMAIN" >/dev/null 2>&1; then
        log "DNS resolution for $DOMAIN is working"
    else
        warn "DNS resolution for $DOMAIN may not be working"
    fi
}

# Main test function
main() {
    log "Starting ZTP Bootstrap Service tests..."
    
    detect_http_only
    test_network
    test_ssl_certificates
    test_container_config
    test_nginx_config
    test_dns
    test_service_status
    
    log "Tests completed!"
    log ""
    if [[ "$HTTP_ONLY" == "true" ]]; then
        warn "⚠️  REMINDER: Service is running in HTTP-only mode (insecure)"
        warn "This should only be used in isolated lab environments"
        warn "Consider using Let's Encrypt with automated renewal for production"
    fi
    log ""
    log "To start the service with a valid enrollment token:"
    log "1. Edit /opt/containerdata/ztpbootstrap/ztpbootstrap.env"
    log "2. Set ENROLLMENT_TOKEN to your CVaaS enrollment token"
    if [[ "$HTTP_ONLY" == "true" ]]; then
        log "3. Run: sudo /opt/containerdata/ztpbootstrap/setup.sh --http-only"
    else
        log "3. Run: sudo /opt/containerdata/ztpbootstrap/setup.sh"
    fi
}

# Run main function
main "$@"
