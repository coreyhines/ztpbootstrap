#!/bin/bash
# Show configuration diff - what will change when applying config.yaml
# Compares current file values with config.yaml values

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_FILE="${1:-config.yaml}"

# Logging functions
info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# Read YAML values using yq
get_yaml_value() {
    local path="$1"
    yq eval "$path" "$CONFIG_FILE" 2>/dev/null || echo ""
}

# Get current value from bootstrap.py
get_bootstrap_value() {
    local var_name="$1"
    local bootstrap_file
    bootstrap_file=$(get_yaml_value '.paths.bootstrap_script')
    
    if [[ ! -f "$bootstrap_file" ]]; then
        echo "<file not found>"
        return
    fi
    
    case "$var_name" in
        cvAddr)
            grep -oP '^cvAddr = "\K[^"]+' "$bootstrap_file" 2>/dev/null || echo "<not found>"
            ;;
        enrollmentToken)
            grep -oP '^enrollmentToken = "\K[^"]+' "$bootstrap_file" 2>/dev/null | head -c 20 || echo "<not found>"
            echo "..."
            ;;
        cvproxy)
            grep -oP '^cvproxy = "\K[^"]+' "$bootstrap_file" 2>/dev/null || echo "<not found>"
            ;;
        eosUrl)
            grep -oP '^eosUrl = "\K[^"]+' "$bootstrap_file" 2>/dev/null || echo "<not found>"
            ;;
        ntpServer)
            grep -oP '^ntpServer = "\K[^"]+' "$bootstrap_file" 2>/dev/null || echo "<not found>"
            ;;
    esac
}

# Show diff for bootstrap.py
show_bootstrap_diff() {
    local bootstrap_file
    bootstrap_file=$(get_yaml_value '.paths.bootstrap_script')
    
    if [[ ! -f "$bootstrap_file" ]]; then
        info "bootstrap.py: File not found, will be created"
        return
    fi
    
    echo -e "${CYAN}bootstrap.py:${NC}"
    
    local cv_addr_yaml
    local cv_addr_current
    cv_addr_yaml=$(get_yaml_value '.cvaas.address')
    cv_addr_current=$(get_bootstrap_value "cvAddr")
    if [[ "$cv_addr_yaml" != "$cv_addr_current" ]]; then
        echo -e "  ${YELLOW}cvAddr:${NC}"
        echo -e "    ${RED}- $cv_addr_current${NC}"
        echo -e "    ${GREEN}+ $cv_addr_yaml${NC}"
    fi
    
    local token_yaml
    local token_current
    token_yaml=$(get_yaml_value '.cvaas.enrollment_token')
    token_current=$(get_bootstrap_value "enrollmentToken")
    if [[ "$token_yaml" != "$token_current" ]]; then
        echo -e "  ${YELLOW}enrollmentToken:${NC}"
        echo -e "    ${RED}- ${token_current:0:20}...${NC}"
        echo -e "    ${GREEN}+ ${token_yaml:0:20}...${NC}"
    fi
    
    local proxy_yaml
    local proxy_current
    proxy_yaml=$(get_yaml_value '.cvaas.proxy')
    proxy_current=$(get_bootstrap_value "cvproxy")
    if [[ "$proxy_yaml" != "$proxy_current" ]]; then
        echo -e "  ${YELLOW}cvproxy:${NC}"
        echo -e "    ${RED}- ${proxy_current:-<empty>}${NC}"
        echo -e "    ${GREEN}+ ${proxy_yaml:-<empty>}${NC}"
    fi
}

# Show diff for nginx.conf
show_nginx_diff() {
    local nginx_file
    nginx_file=$(get_yaml_value '.paths.nginx_conf')
    
    if [[ ! -f "$nginx_file" ]]; then
        info "nginx.conf: File not found, will be created"
        return
    fi
    
    echo -e "${CYAN}nginx.conf:${NC}"
    
    local domain_yaml
    local domain_current
    domain_yaml=$(get_yaml_value '.network.domain')
    domain_current=$(grep -oP 'server_name \K[^ ]+' "$nginx_file" 2>/dev/null | head -1 || echo "<not found>")
    
    if [[ "$domain_yaml" != "$domain_current" ]]; then
        echo -e "  ${YELLOW}server_name:${NC}"
        echo -e "    ${RED}- $domain_current${NC}"
        echo -e "    ${GREEN}+ $domain_yaml${NC}"
    fi
}

# Show diff for environment file
show_env_diff() {
    local env_file
    env_file=$(get_yaml_value '.paths.env_file')
    
    echo -e "${CYAN}ztpbootstrap.env:${NC}"
    
    if [[ -f "$env_file" ]]; then
        local cv_addr_yaml
        local cv_addr_current
        cv_addr_yaml=$(get_yaml_value '.cvaas.address')
        cv_addr_current=$(grep -oP '^CV_ADDR=\K.+' "$env_file" 2>/dev/null || echo "<not found>")
        
        if [[ "$cv_addr_yaml" != "$cv_addr_current" ]]; then
            echo -e "  ${YELLOW}CV_ADDR:${NC}"
            echo -e "    ${RED}- $cv_addr_current${NC}"
            echo -e "    ${GREEN}+ $cv_addr_yaml${NC}"
        fi
    else
        info "  Environment file will be created"
    fi
}

# Main function
main() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi
    
    if ! command -v yq >/dev/null 2>&1; then
        echo -e "${RED}Error: yq is required${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}  ${GREEN}Configuration Diff${NC}                                        ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    info "Showing changes that will be applied from: $CONFIG_FILE"
    echo ""
    
    show_bootstrap_diff
    echo ""
    show_nginx_diff
    echo ""
    show_env_diff
    echo ""
}

main "$@"
