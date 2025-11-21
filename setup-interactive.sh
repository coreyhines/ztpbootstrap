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

# Backup directory (relative to repo root)
BACKUP_BASE_DIR=".ztpbootstrap-backups"

# Initialize existing installation value variables (will be populated if previous install detected)
EXISTING_SCRIPT_DIR=""
EXISTING_DOMAIN=""
EXISTING_IPV4=""
EXISTING_IPV6=""
EXISTING_CV_ADDR=""
EXISTING_ENROLLMENT_TOKEN=""
EXISTING_CV_PROXY=""
EXISTING_EOS_URL=""
EXISTING_NTP_SERVER=""
EXISTING_TIMEZONE=""
EXISTING_DNS1=""
EXISTING_DNS2=""
EXISTING_NETWORK=""
EXISTING_HTTP_ONLY=""
EXISTING_HTTPS_PORT=""

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
    
    # In non-interactive mode, use default value without prompting
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        value="$default_value"
        log "Non-interactive: $prompt_text = $default_value"
        eval "$var_name=\"$value\""
        return 0
    fi
    
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
                # When there's a default and empty is allowed, make it clear Enter uses default
                echo -n -e "${CYAN}[?]${NC} $prompt_text ${BLUE}[$default_value]${NC} (press Enter to use default, or type 'empty' to leave blank): "
            else
                echo -n -e "${CYAN}[?]${NC} $prompt_text ${BLUE}[$default_value]${NC}: "
            fi
        else
            if [[ "$allow_empty" == "true" ]]; then
                echo -n -e "${CYAN}[?]${NC} $prompt_text (leave empty if not needed): "
            else
                echo -n -e "${CYAN}[?]${NC} $prompt_text: "
            fi
        fi
        read -r value
    fi
    
    # Handle empty input
    if [[ -z "$value" ]]; then
        if [[ -n "$default_value" ]]; then
            # There's a default, use it when Enter is pressed
            value="$default_value"
        elif [[ "$allow_empty" == "true" ]]; then
            # No default and empty is allowed, keep it empty
            value=""
        fi
    else
        # User typed something - check if they want empty
        # Allow "empty", "none", or single space to mean empty
        if [[ "$allow_empty" == "true" ]] && [[ "$value" =~ ^[[:space:]]*(empty|none)[[:space:]]*$ ]]; then
            value=""
        fi
    fi
    
    eval "$var_name='$value'"
}

# Prompt for yes/no with default
prompt_yes_no() {
    local prompt_text="$1"
    local default_value="${2:-n}"
    local var_name="$3"
    
    # In non-interactive mode, use default value without prompting
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        if [[ "$default_value" == "y" ]] || [[ "$default_value" == "Y" ]]; then
            eval "$var_name='true'"
        else
            eval "$var_name='false'"
        fi
        log "Non-interactive: $prompt_text = $default_value"
        return 0
    fi
    
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

# Detect previous installation
detect_previous_install() {
    local script_dir="${1:-/opt/containerdata/ztpbootstrap}"
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    local found=false
    
    # Check if service directory exists and has files
    if [[ -d "$script_dir" ]]; then
        local file_count
        if [[ $EUID -eq 0 ]]; then
            file_count=$(find "$script_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        else
            file_count=$(sudo find "$script_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        fi
        if [[ "$file_count" -gt 0 ]]; then
            found=true
        fi
    fi
    
    # Check if systemd directory exists and has files
    if [[ -d "$systemd_dir" ]]; then
        local file_count
        if [[ $EUID -eq 0 ]]; then
            file_count=$(find "$systemd_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        else
            file_count=$(sudo find "$systemd_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        fi
        if [[ "$file_count" -gt 0 ]]; then
            found=true
        fi
    fi
    
    if [[ "$found" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Create backup of existing installation
create_backup() {
    local script_dir="${1:-/opt/containerdata/ztpbootstrap}"
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    
    # Get repository directory
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Create backup directory
    local backup_dir="${repo_dir}/${BACKUP_BASE_DIR}"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_path="${backup_dir}/backup_${timestamp}"
    
    log "Creating backup of existing installation..."
    log "Backup location: $backup_path"
    
    # Create backup directory structure
    if ! mkdir -p "$backup_path" 2>/dev/null; then
        error "Failed to create backup directory: $backup_path"
        return 1
    fi
    
    # Backup service directory
    if [[ -d "$script_dir" ]]; then
        log "Backing up: $script_dir"
        if [[ $EUID -eq 0 ]]; then
            if ! cp -r "$script_dir" "${backup_path}/containerdata_ztpbootstrap" 2>/dev/null; then
                warn "Failed to backup $script_dir"
            else
                log "✓ Backed up service directory"
            fi
        else
            if ! sudo cp -r "$script_dir" "${backup_path}/containerdata_ztpbootstrap" 2>/dev/null; then
                warn "Failed to backup $script_dir (may need sudo)"
            else
                # Fix ownership of backup
                sudo chown -R "$USER:$(id -gn)" "${backup_path}/containerdata_ztpbootstrap" 2>/dev/null || true
                log "✓ Backed up service directory"
            fi
        fi
    fi
    
    # Backup systemd directory
    if [[ -d "$systemd_dir" ]]; then
        log "Backing up: $systemd_dir"
        if [[ $EUID -eq 0 ]]; then
            if ! cp -r "$systemd_dir" "${backup_path}/etc_containers_systemd_ztpbootstrap" 2>/dev/null; then
                warn "Failed to backup $systemd_dir"
            else
                log "✓ Backed up systemd directory"
            fi
        else
            if ! sudo cp -r "$systemd_dir" "${backup_path}/etc_containers_systemd_ztpbootstrap" 2>/dev/null; then
                warn "Failed to backup $systemd_dir (may need sudo)"
            else
                # Fix ownership of backup
                sudo chown -R "$USER:$(id -gn)" "${backup_path}/etc_containers_systemd_ztpbootstrap" 2>/dev/null || true
                log "✓ Backed up systemd directory"
            fi
        fi
    fi
    
    # Create backup info file
    cat > "${backup_path}/backup_info.txt" << EOF
ZTP Bootstrap Backup Information
================================
Backup created: $(date)
Backup location: $backup_path

Original paths:
- Service directory: $script_dir
- Systemd directory: $systemd_dir

To restore this backup, run:
  ./setup-interactive.sh --restore $timestamp

Or use the restore function:
  restore_backup "$timestamp"
EOF
    
    log "Backup completed successfully!"
    log "Backup saved to: $backup_path"
    echo ""
    
    # Store backup path for later reference
    echo "$backup_path" > "${backup_dir}/.last_backup"
    
    return 0
}

# Restore from backup
restore_backup() {
    local backup_timestamp="$1"
    
    # Get repository directory
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local backup_dir="${repo_dir}/${BACKUP_BASE_DIR}"
    
    # If no timestamp provided, list available backups
    if [[ -z "$backup_timestamp" ]]; then
        if [[ ! -d "$backup_dir" ]]; then
            error "No backups found. Backup directory does not exist: $backup_dir"
            return 1
        fi
        
        local backups
        # Use portable find command (works on both Linux and macOS)
        if command -v gfind >/dev/null 2>&1; then
            # Use GNU find if available (has -printf)
            backups=($(gfind "$backup_dir" -maxdepth 1 -type d -name "backup_*" -printf "%f\n" 2>/dev/null | sort -r))
        else
            # Use standard find (portable)
            backups=($(find "$backup_dir" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | sed 's|.*/||' | sort -r))
        fi
        
        if [[ ${#backups[@]} -eq 0 ]]; then
            error "No backups found in: $backup_dir"
            return 1
        fi
        
        echo ""
        echo -e "${CYAN}Available backups:${NC}"
        echo ""
        local i=1
        for backup in "${backups[@]}"; do
            local backup_path="${backup_dir}/${backup}"
            local backup_date
            backup_date=$(echo "$backup" | sed 's/backup_//' | sed 's/_/ /' | awk '{print $1}' | sed 's/\(....\)\(..\)\(..\)/\1-\2-\3/')
            local backup_time
            backup_time=$(echo "$backup" | sed 's/backup_//' | sed 's/_/ /' | awk '{print $2}' | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')
            echo "  $i) $backup_date $backup_time"
            ((i++))
        done
        echo ""
        
        echo -n -e "${CYAN}[?]${NC} Select backup to restore (1-${#backups[@]}) or 'q' to quit: "
        read -r selection
        
        if [[ "$selection" == "q" ]] || [[ "$selection" == "Q" ]]; then
            log "Restore cancelled."
            return 1
        fi
        
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#backups[@]} ]]; then
            error "Invalid selection: $selection"
            return 1
        fi
        
        backup_timestamp=$(echo "${backups[$((selection-1))]}" | sed 's/backup_//')
    fi
    
    local backup_path="${backup_dir}/backup_${backup_timestamp}"
    
    if [[ ! -d "$backup_path" ]]; then
        error "Backup not found: $backup_path"
        return 1
    fi
    
    echo ""
    warn "⚠️  WARNING: This will overwrite existing files!"
    warn "The following directories will be restored:"
    warn "  - /opt/containerdata/ztpbootstrap"
    warn "  - /etc/containers/systemd/ztpbootstrap"
    echo ""
    
    prompt_yes_no "Are you sure you want to restore from backup?" "n" CONFIRM_RESTORE
    
    if [[ "$CONFIRM_RESTORE" != "true" ]]; then
        log "Restore cancelled."
        return 1
    fi
    
    log "Restoring from backup: $backup_path"
    
    # Restore service directory
    if [[ -d "${backup_path}/containerdata_ztpbootstrap" ]]; then
        log "Restoring service directory..."
        if [[ $EUID -eq 0 ]]; then
            # Remove existing directory if it exists
            if [[ -d "/opt/containerdata/ztpbootstrap" ]]; then
                rm -rf "/opt/containerdata/ztpbootstrap" 2>/dev/null || true
            fi
            # Restore from backup
            if cp -r "${backup_path}/containerdata_ztpbootstrap" "/opt/containerdata/ztpbootstrap" 2>/dev/null; then
                log "✓ Restored service directory"
            else
                error "Failed to restore service directory"
                return 1
            fi
        else
            # Remove existing directory if it exists
            if [[ -d "/opt/containerdata/ztpbootstrap" ]]; then
                sudo rm -rf "/opt/containerdata/ztpbootstrap" 2>/dev/null || true
            fi
            # Restore from backup
            if sudo cp -r "${backup_path}/containerdata_ztpbootstrap" "/opt/containerdata/ztpbootstrap" 2>/dev/null; then
                log "✓ Restored service directory"
            else
                error "Failed to restore service directory (may need sudo)"
                return 1
            fi
        fi
    else
        warn "Service directory backup not found in: ${backup_path}/containerdata_ztpbootstrap"
    fi
    
    # Restore systemd directory
    if [[ -d "${backup_path}/etc_containers_systemd_ztpbootstrap" ]]; then
        log "Restoring systemd directory..."
        if [[ $EUID -eq 0 ]]; then
            # Remove existing directory if it exists
            if [[ -d "/etc/containers/systemd/ztpbootstrap" ]]; then
                rm -rf "/etc/containers/systemd/ztpbootstrap" 2>/dev/null || true
            fi
            # Create parent directory
            mkdir -p "/etc/containers/systemd" 2>/dev/null || true
            # Restore from backup
            if cp -r "${backup_path}/etc_containers_systemd_ztpbootstrap" "/etc/containers/systemd/ztpbootstrap" 2>/dev/null; then
                log "✓ Restored systemd directory"
            else
                error "Failed to restore systemd directory"
                return 1
            fi
        else
            # Remove existing directory if it exists
            if [[ -d "/etc/containers/systemd/ztpbootstrap" ]]; then
                sudo rm -rf "/etc/containers/systemd/ztpbootstrap" 2>/dev/null || true
            fi
            # Create parent directory
            sudo mkdir -p "/etc/containers/systemd" 2>/dev/null || true
            # Restore from backup
            if sudo cp -r "${backup_path}/etc_containers_systemd_ztpbootstrap" "/etc/containers/systemd/ztpbootstrap" 2>/dev/null; then
                log "✓ Restored systemd directory"
            else
                error "Failed to restore systemd directory (may need sudo)"
                return 1
            fi
        fi
    else
        warn "Systemd directory backup not found in: ${backup_path}/etc_containers_systemd_ztpbootstrap"
    fi
    
    log "Restore completed successfully!"
    log ""
    log "Next steps:"
    log "  1. Reload systemd: sudo systemctl daemon-reload"
    log "  2. Restart services if needed: sudo systemctl restart ztpbootstrap-pod"
    echo ""
    
    return 0
}

# Check for running services
check_running_services() {
    local running_services=()
    local service_type="none"
    
    # Check for pod-based services (quadlet generates ztpbootstrap-pod.service from ztpbootstrap.pod)
    if systemctl is-active --quiet ztpbootstrap-pod.service 2>/dev/null; then
        running_services+=("ztpbootstrap-pod.service")
        service_type="pod-based"
    fi
    if systemctl is-active --quiet ztpbootstrap-nginx.service 2>/dev/null; then
        running_services+=("ztpbootstrap-nginx.service")
        if [[ "$service_type" == "none" ]]; then
            service_type="pod-based"
        fi
    fi
    if systemctl is-active --quiet ztpbootstrap-webui.service 2>/dev/null; then
        running_services+=("ztpbootstrap-webui.service")
        if [[ "$service_type" == "none" ]]; then
            service_type="pod-based"
        fi
    fi
    
    # Return service type and list
    if [[ ${#running_services[@]} -gt 0 ]]; then
        echo "${service_type}:${running_services[*]}"
        return 0
    else
        echo "none:"
        return 1
    fi
}

# Stop services gracefully
stop_services_gracefully() {
    local service_info="$1"
    local service_type="${service_info%%:*}"
    local services="${service_info#*:}"
    
    if [[ "$service_type" == "none" ]] || [[ -z "$services" ]]; then
        return 0
    fi
    
    log "Stopping services gracefully..."
    if [[ "$service_type" == "pod-based" ]]; then
        # New version: stop containers first, then pod
        log "Stopping pod-based services..."
        local pod_service_name="ztpbootstrap-pod.service"
        if [[ $EUID -eq 0 ]]; then
            systemctl stop ztpbootstrap-nginx.service ztpbootstrap-webui.service 2>/dev/null || true
            sleep 1
            systemctl stop "$pod_service_name" 2>/dev/null || warn "Failed to stop $pod_service_name"
        else
            sudo systemctl stop ztpbootstrap-nginx.service ztpbootstrap-webui.service 2>/dev/null || true
            sleep 1
            sudo systemctl stop "$pod_service_name" 2>/dev/null || warn "Failed to stop $pod_service_name"
        fi
        sleep 2
    fi
    
    # Verify services are stopped
    local still_running=false
    IFS=' ' read -ra SERVICE_ARRAY <<< "$services"
    for service in "${SERVICE_ARRAY[@]}"; do
        if [[ -n "$service" ]]; then
            if [[ $EUID -eq 0 ]]; then
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    warn "Service $service is still running"
                    still_running=true
                fi
            else
                if sudo systemctl is-active --quiet "$service" 2>/dev/null; then
                    warn "Service $service is still running"
                    still_running=true
                fi
            fi
        fi
    done
    
    if [[ "$still_running" == "true" ]]; then
        warn "Some services may still be running. Proceeding anyway..."
    else
        log "All services stopped successfully"
    fi
    
    return 0
}

# Read ztpbootstrap.env file
read_ztpbootstrap_env() {
    local env_file="${1:-/opt/containerdata/ztpbootstrap/ztpbootstrap.env}"
    local values=()
    
    if [[ ! -f "$env_file" ]]; then
        return 1
    fi
    
    # Read file (handle sudo if needed)
    local content
    if [[ $EUID -eq 0 ]]; then
        content=$(cat "$env_file" 2>/dev/null)
    else
        content=$(sudo cat "$env_file" 2>/dev/null)
    fi
    
    if [[ -z "$content" ]]; then
        return 1
    fi
    
    # Extract values (handle comments and empty lines)
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Extract key=value pairs
        if [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]// /}"
            local value="${BASH_REMATCH[2]}"
            # Remove quotes if present
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            values+=("${key}=${value}")
        fi
    done <<< "$content"
    
    # Output as key=value pairs (one per line)
    printf '%s\n' "${values[@]}"
    return 0
}

# Find which podman network contains a given IP address
find_network_for_ip() {
    local target_ip="$1"
    local networks
    
    # Check if podman is available
    if ! command -v podman >/dev/null 2>&1; then
        return 1
    fi
    
    # Get list of all podman networks (skip header line)
    networks=$(podman network ls --format "{{.Name}}" 2>/dev/null || echo "")
    
    if [[ -z "$networks" ]]; then
        return 1
    fi
    
    # Check each network to see if the IP falls within its subnet
    while IFS= read -r network_name; do
        [[ -z "$network_name" ]] && continue
        
        # Skip default networks that don't support static IPs
        if [[ "$network_name" == "podman" ]] || [[ "$network_name" == "default" ]]; then
            continue
        fi
        
        # Get network subnet from inspect
        local subnet_info
        subnet_info=$(podman network inspect "$network_name" 2>/dev/null | grep -i "subnet" | head -1 || echo "")
        
        if [[ -z "$subnet_info" ]]; then
            continue
        fi
        
        # Extract subnet (format: "Subnet": "10.0.0.0/24" or similar)
        local subnet=""
        if [[ "$subnet_info" =~ \"Subnet\":[[:space:]]*\"([^\"]+)\" ]]; then
            subnet="${BASH_REMATCH[1]}"
        elif [[ "$subnet_info" =~ subnet[[:space:]]*[:=][[:space:]]*([0-9.]+/[0-9]+) ]]; then
            subnet="${BASH_REMATCH[1]}"
        fi
        
        if [[ -z "$subnet" ]]; then
            continue
        fi
        
        # Check if IP is in subnet
        # Try using ipcalc if available (most accurate)
        if command -v ipcalc >/dev/null 2>&1; then
            # ipcalc -c checks if IP is in subnet (returns 0 if true)
            if ipcalc -c "$target_ip" "$subnet" >/dev/null 2>&1; then
                echo "$network_name"
                return 0
            fi
        # Fallback: use ip command to check if IP is in subnet
        elif command -v ip >/dev/null 2>&1; then
            # Use ip route get to see if IP would route through this network
            # This is a heuristic but should work for most cases
            if ip route get "$target_ip" >/dev/null 2>&1; then
                # Check if the subnet matches by comparing network portion
                local network_addr="${subnet%%/*}"
                local prefix="${subnet##*/}"
                local ip_octets=($(echo "$target_ip" | tr '.' ' '))
                local net_octets=($(echo "$network_addr" | tr '.' ' '))
                
                if [[ ${#ip_octets[@]} -eq 4 ]] && [[ ${#net_octets[@]} -eq 4 ]]; then
                    # Calculate how many octets to check based on prefix
                    local octets_to_check=$((prefix / 8))
                    local bits_in_partial=$((prefix % 8))
                    local match=true
                    
                    # Check full octets
                    for ((i=0; i<octets_to_check && i<4; i++)); do
                        if [[ "${ip_octets[$i]}" != "${net_octets[$i]}" ]]; then
                            match=false
                            break
                        fi
                    done
                    
                    # If all full octets match and we have a partial octet, check it
                    if [[ "$match" == "true" ]] && [[ $bits_in_partial -gt 0 ]] && [[ $octets_to_check -lt 4 ]]; then
                        local ip_octet="${ip_octets[$octets_to_check]}"
                        local net_octet="${net_octets[$octets_to_check]}"
                        local mask=$((0xFF << (8 - bits_in_partial) & 0xFF))
                        if [[ $((ip_octet & mask)) != $((net_octet & mask)) ]]; then
                            match=false
                        fi
                    fi
                    
                    if [[ "$match" == "true" ]]; then
                        echo "$network_name"
                        return 0
                    fi
                fi
            fi
        else
            # Last resort: simple prefix matching for common cases
            local network_addr="${subnet%%/*}"
            local prefix="${subnet##*/}"
            local ip_octets=($(echo "$target_ip" | tr '.' ' '))
            local net_octets=($(echo "$network_addr" | tr '.' ' '))
            
            if [[ ${#ip_octets[@]} -eq 4 ]] && [[ ${#net_octets[@]} -eq 4 ]]; then
                # Check common prefix lengths
                if [[ "$prefix" == "24" ]] && [[ "${ip_octets[0]}" == "${net_octets[0]}" ]] && \
                   [[ "${ip_octets[1]}" == "${net_octets[1]}" ]] && [[ "${ip_octets[2]}" == "${net_octets[2]}" ]]; then
                    echo "$network_name"
                    return 0
                elif [[ "$prefix" == "16" ]] && [[ "${ip_octets[0]}" == "${net_octets[0]}" ]] && \
                     [[ "${ip_octets[1]}" == "${net_octets[1]}" ]]; then
                    echo "$network_name"
                    return 0
                elif [[ "$prefix" == "8" ]] && [[ "${ip_octets[0]}" == "${net_octets[0]}" ]]; then
                    echo "$network_name"
                    return 0
                fi
            fi
        fi
    done <<< "$networks"
    
    return 1
}

# Read container/pod file
read_container_file() {
    local base_path="${1:-/etc/containers/systemd/ztpbootstrap}"
    local container_file="${base_path}/ztpbootstrap.container"
    local pod_file="${base_path}/ztpbootstrap.pod"
    local target_file=""
    
    # Check for pod file first (newer), then container file (older)
    # But if pod file is missing IP addresses, also check container file
    local pod_content=""
    local container_content=""
    
    if [[ -f "$pod_file" ]]; then
        if [[ $EUID -eq 0 ]]; then
            pod_content=$(cat "$pod_file" 2>/dev/null)
        else
            pod_content=$(sudo cat "$pod_file" 2>/dev/null)
        fi
    fi
    
    if [[ -f "$container_file" ]]; then
        if [[ $EUID -eq 0 ]]; then
            container_content=$(cat "$container_file" 2>/dev/null)
        else
            container_content=$(sudo cat "$container_file" 2>/dev/null)
        fi
    fi
    
    # Prefer pod file, but if it's missing IP6 or DNS entries and container file has them, use container file
    if [[ -n "$pod_content" ]]; then
        # Check if pod has Network=host and no IP addresses
        if grep -q "^Network=host" <<< "$pod_content" 2>/dev/null; then
            if ! grep -q "^IP=" <<< "$pod_content" 2>/dev/null && ! grep -q "^IP6=" <<< "$pod_content" 2>/dev/null; then
                # Pod has host networking and no IPs, use container file if available
                if [[ -n "$container_content" ]]; then
                    target_file="$container_file"
                else
                    target_file="$pod_file"
                fi
            else
                target_file="$pod_file"
            fi
        # Check if pod is missing IP6 but container file has it
        elif [[ -n "$container_content" ]] && ! grep -q "^IP6=" <<< "$pod_content" 2>/dev/null && grep -q "^IP6=" <<< "$container_content" 2>/dev/null; then
            # Pod doesn't have IP6 but container does, use container file
            target_file="$container_file"
        # Check if pod is missing DNS entries but container file has them
        elif [[ -n "$container_content" ]] && ! grep -q "^DNS=" <<< "$pod_content" 2>/dev/null && grep -q "^DNS=" <<< "$container_content" 2>/dev/null; then
            # Pod doesn't have DNS but container does, use container file
            target_file="$container_file"
        else
            target_file="$pod_file"
        fi
    elif [[ -n "$container_content" ]]; then
        target_file="$container_file"
    else
        return 1
    fi
    
    # Read file (handle sudo if needed)
    local content
    if [[ $EUID -eq 0 ]]; then
        content=$(cat "$target_file" 2>/dev/null)
    else
        content=$(sudo cat "$target_file" 2>/dev/null)
    fi
    
    if [[ -z "$content" ]]; then
        return 1
    fi
    
    # Extract key=value pairs from [Container] or [Pod] section
    local in_section=false
    local values=()
    
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Check for [Container] or [Pod] section
        if [[ "$line" =~ ^[[:space:]]*\[(Container|Pod)\] ]]; then
            in_section=true
            continue
        fi
        
        # Stop at next section (but continue reading if we're in the section we want)
        if [[ "$line" =~ ^[[:space:]]*\[ ]] && [[ ! "$line" =~ ^[[:space:]]*\[(Container|Pod)\] ]]; then
            in_section=false
            continue
        fi
        
        # Extract key=value pairs from Container/Pod section
        if [[ "$in_section" == "true" ]] && [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]// /}"
            local value="${BASH_REMATCH[2]}"
            # Remove quotes if present
            value="${value#\"}"
            value="${value%\"}"
            values+=("${key}=${value}")
        fi
    done <<< "$content"
    
    # Output as key=value pairs (one per line)
    printf '%s\n' "${values[@]}"
    return 0
}

# Read nginx.conf file
read_nginx_conf() {
    local nginx_file="${1:-/opt/containerdata/ztpbootstrap/nginx.conf}"
    local values=()
    
    if [[ ! -f "$nginx_file" ]]; then
        return 1
    fi
    
    # Read file (handle sudo if needed)
    local content
    if [[ $EUID -eq 0 ]]; then
        content=$(cat "$nginx_file" 2>/dev/null)
    else
        content=$(sudo cat "$nginx_file" 2>/dev/null)
    fi
    
    if [[ -z "$content" ]]; then
        return 1
    fi
    
    # Extract server_name (domain)
    # Try multiple patterns to handle different nginx.conf formats
    # Prefer domains that are not example.com or localhost
    local domain=""
    local all_domains=()
    
    # First, collect all server_name values
    while IFS= read -r line; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip lines that don't have server_name
        [[ ! "$line" =~ server_name ]] && continue
        
        # Extract server_name value
        if [[ "$line" =~ server_name[[:space:]]+([^;]+) ]]; then
            local server_names="${BASH_REMATCH[1]}"
            # Get first server name (usually the domain)
            local candidate=$(echo "$server_names" | awk '{print $1}')
            # Remove any trailing semicolons or whitespace
            candidate="${candidate%;}"
            candidate="${candidate// /}"
            # Skip invalid domains
            if [[ -n "$candidate" ]] && [[ "$candidate" != "_" ]] && [[ "$candidate" != "localhost" ]] && [[ ! "$candidate" =~ ^[0-9] ]]; then
                all_domains+=("$candidate")
            fi
        fi
    done <<< "$content"
    
    # Debug: log all found domains
    if [[ ${#all_domains[@]} -gt 0 ]]; then
        log "  Found ${#all_domains[@]} domain(s) in nginx.conf: ${all_domains[*]}"
    fi
    
    # Prefer domains that are not example.com
    for candidate in "${all_domains[@]}"; do
        if [[ "$candidate" != *"example.com"* ]] && [[ "$candidate" != "localhost" ]] && [[ "$candidate" != "_" ]]; then
            domain="$candidate"
            log "  Selected non-example domain: $domain"
            break
        fi
    done
    
    # If no non-example domain found, use first valid domain
    if [[ -z "$domain" ]] && [[ ${#all_domains[@]} -gt 0 ]]; then
        domain="${all_domains[0]}"
        log "  No non-example domain found, using first domain: $domain"
    fi
    
    # If not found with first pattern, try a more flexible pattern
    if [[ -z "$domain" ]]; then
        # Look for server_name followed by domain (handles various whitespace)
        # Try to find the first server_name that's not in a comment and has a valid domain
        if grep -q "server_name" <<< "$content"; then
            # Get all server_name lines, skip comments, get first non-comment line
            local server_name_line
            server_name_line=$(grep "server_name" <<< "$content" | grep -v "^[[:space:]]*#" | head -1)
            if [[ -n "$server_name_line" ]]; then
                domain=$(echo "$server_name_line" | sed -n 's/.*server_name[[:space:]]*\([^;[:space:]]*\).*/\1/p' | awk '{print $1}')
                domain="${domain%;}"
                domain="${domain// /}"
            fi
        fi
    fi
    
    # Additional check: if domain looks like an IP address or is invalid, try next server_name
    if [[ -n "$domain" ]] && [[ "$domain" =~ ^[0-9] ]] || [[ "$domain" == "_" ]] || [[ "$domain" == "localhost" ]]; then
        # Domain is an IP or invalid, try to find a better one
        if grep -q "server_name" <<< "$content"; then
            # Get all server_name lines, skip the first one we already tried
            local server_name_lines
            server_name_lines=$(grep "server_name" <<< "$content" | grep -v "^[[:space:]]*#" | tail -n +2)
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local candidate
                candidate=$(echo "$line" | sed -n 's/.*server_name[[:space:]]*\([^;[:space:]]*\).*/\1/p' | awk '{print $1}')
                candidate="${candidate%;}"
                candidate="${candidate// /}"
                # If candidate is a valid domain (not IP, not _, not localhost), use it
                if [[ -n "$candidate" ]] && [[ ! "$candidate" =~ ^[0-9] ]] && [[ "$candidate" != "_" ]] && [[ "$candidate" != "localhost" ]]; then
                    domain="$candidate"
                    break
                fi
            done <<< "$server_name_lines"
        fi
    fi
    
    if [[ -n "$domain" ]] && [[ "$domain" != "_" ]] && [[ "$domain" != "localhost" ]]; then
        values+=("DOMAIN=${domain}")
    fi
    
    # Detect HTTP-only mode
    # HTTP-only mode is indicated by:
    # 1. Presence of "HTTP-ONLY MODE" comment, OR
    # 2. Absence of "listen.*ssl" pattern (no SSL listeners)
    local http_only="false"
    if grep -q "HTTP-ONLY MODE" <<< "$content" || ! grep -q "listen.*ssl" <<< "$content"; then
        http_only="true"
    fi
    values+=("HTTP_ONLY=${http_only}")
    
    # Extract HTTPS port from listen directives
    # Look for "listen 443 ssl" or "listen [::]:443 ssl" patterns
    local https_port="443"
    if [[ "$http_only" == "false" ]]; then
        # Try to extract port from listen directives
        if [[ "$content" =~ listen[[:space:]]+([0-9]+)[[:space:]]+ssl ]]; then
            https_port="${BASH_REMATCH[1]}"
        elif [[ "$content" =~ listen[[:space:]]+\[::\]:([0-9]+)[[:space:]]+ssl ]]; then
            https_port="${BASH_REMATCH[1]}"
        fi
    fi
    values+=("HTTPS_PORT=${https_port}")
    
    # Extract SSL certificate paths
    if [[ "$content" =~ ssl_certificate[[:space:]]+([^;]+) ]]; then
        local cert_path="${BASH_REMATCH[1]}"
        cert_path="${cert_path// /}"
        values+=("SSL_CERT_PATH=${cert_path}")
    fi
    
    if [[ "$content" =~ ssl_certificate_key[[:space:]]+([^;]+) ]]; then
        local key_path="${BASH_REMATCH[1]}"
        key_path="${key_path// /}"
        values+=("SSL_KEY_PATH=${key_path}")
    fi
    
    # Output as key=value pairs (one per line)
    printf '%s\n' "${values[@]}"
    return 0
}

# Read config.yaml file
read_config_yaml() {
    local config_file="${1:-config.yaml}"
    local base_dir="${2:-}"
    
    # If base_dir is provided, use it; otherwise use repo directory
    if [[ -n "$base_dir" ]]; then
        local full_path="${base_dir}/${config_file}"
    else
        local repo_dir
        repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local full_path="${repo_dir}/${config_file}"
    fi
    
    if [[ ! -f "$full_path" ]]; then
        return 1
    fi
    
    if ! command -v yq >/dev/null 2>&1; then
        log "yq not found, cannot read config.yaml"
        return 1
    fi
    
    local values=()
    
    # Read network settings
    local domain
    domain=$(yq eval '.network.domain // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$domain" ]] && [[ "$domain" != "null" ]]; then
        values+=("DOMAIN=$domain")
    fi
    
    local ipv4
    ipv4=$(yq eval '.network.ipv4 // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$ipv4" ]] && [[ "$ipv4" != "null" ]]; then
        values+=("IPV4=$ipv4")
    fi
    
    local ipv6
    ipv6=$(yq eval '.network.ipv6 // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$ipv6" ]] && [[ "$ipv6" != "null" ]]; then
        values+=("IPV6=$ipv6")
    fi
    
    local network
    network=$(yq eval '.network.network // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$network" ]] && [[ "$network" != "null" ]]; then
        values+=("NETWORK=$network")
    fi
    
    local http_only
    http_only=$(yq eval '.network.http_only // false' "$full_path" 2>/dev/null || echo "false")
    if [[ "$http_only" == "true" ]]; then
        values+=("HTTP_ONLY=true")
    else
        values+=("HTTP_ONLY=false")
    fi
    
    local https_port
    https_port=$(yq eval '.network.https_port // 443' "$full_path" 2>/dev/null || echo "443")
    values+=("HTTPS_PORT=$https_port")
    
    # Read CVaaS settings
    local cv_addr
    cv_addr=$(yq eval '.cvaas.address // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$cv_addr" ]] && [[ "$cv_addr" != "null" ]]; then
        values+=("CV_ADDR=$cv_addr")
    fi
    
    local enrollment_token
    enrollment_token=$(yq eval '.cvaas.enrollment_token // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$enrollment_token" ]] && [[ "$enrollment_token" != "null" ]]; then
        values+=("ENROLLMENT_TOKEN=$enrollment_token")
    fi
    
    local cv_proxy
    cv_proxy=$(yq eval '.cvaas.proxy // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$cv_proxy" ]] && [[ "$cv_proxy" != "null" ]]; then
        values+=("CV_PROXY=$cv_proxy")
    fi
    
    local eos_url
    eos_url=$(yq eval '.cvaas.eos_url // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$eos_url" ]] && [[ "$eos_url" != "null" ]]; then
        values+=("EOS_URL=$eos_url")
    fi
    
    local ntp_server
    ntp_server=$(yq eval '.cvaas.ntp_server // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$ntp_server" ]] && [[ "$ntp_server" != "null" ]]; then
        values+=("NTP_SERVER=$ntp_server")
    fi
    
    # Read container settings
    local timezone
    timezone=$(yq eval '.container.timezone // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$timezone" ]] && [[ "$timezone" != "null" ]]; then
        values+=("TIMEZONE=$timezone")
    fi
    
    local host_network
    host_network=$(yq eval '.container.host_network // false' "$full_path" 2>/dev/null || echo "false")
    if [[ "$host_network" == "true" ]]; then
        values+=("HOST_NETWORK=true")
    fi
    
    # Read DNS servers (array)
    local dns1
    dns1=$(yq eval '.container.dns[0] // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$dns1" ]] && [[ "$dns1" != "null" ]]; then
        values+=("DNS1=$dns1")
    fi
    
    local dns2
    dns2=$(yq eval '.container.dns[1] // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$dns2" ]] && [[ "$dns2" != "null" ]]; then
        values+=("DNS2=$dns2")
    fi
    
    # Read auth settings
    local admin_password_hash
    admin_password_hash=$(yq eval '.auth.admin_password_hash // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$admin_password_hash" ]] && [[ "$admin_password_hash" != "null" ]] && [[ "$admin_password_hash" != "" ]]; then
        values+=("ADMIN_PASSWORD_HASH=$admin_password_hash")
    fi
    
    local session_timeout
    session_timeout=$(yq eval '.auth.session_timeout // ""' "$full_path" 2>/dev/null || echo "")
    if [[ -n "$session_timeout" ]] && [[ "$session_timeout" != "null" ]]; then
        values+=("SESSION_TIMEOUT=$session_timeout")
    fi
    
    # Output as key=value pairs (one per line)
    printf '%s\n' "${values[@]}"
    return 0
}

# Load existing installation values
load_existing_installation_values() {
    local script_dir="${1:-/opt/containerdata/ztpbootstrap}"
    
    # Initialize variables (global scope for use in interactive_config)
    EXISTING_SCRIPT_DIR="$script_dir"
    EXISTING_DOMAIN=""
    EXISTING_IPV4=""
    EXISTING_IPV6=""
    EXISTING_CV_ADDR=""
    EXISTING_ENROLLMENT_TOKEN=""
    EXISTING_CV_PROXY=""
    EXISTING_EOS_URL=""
    EXISTING_NTP_SERVER=""
    EXISTING_TIMEZONE=""
    EXISTING_DNS1=""
    EXISTING_DNS2=""
    EXISTING_NETWORK=""
    EXISTING_HTTP_ONLY=""
    EXISTING_HTTPS_PORT=""
    EXISTING_ADMIN_PASSWORD_HASH=""
    EXISTING_SESSION_TIMEOUT=""
    
    log "Reading existing installation values..."
    
    # Only read from config.yaml in installation directory (not from repo)
    # The repo's config.yaml has template values that would override real values
    local install_config_file="${script_dir}/config.yaml"
    local config_file=""
    
    # Only use config.yaml from installation directory, never from repo
    if [[ -f "$install_config_file" ]] && command -v yq >/dev/null 2>&1; then
        config_file="$install_config_file"
        log "Reading from config.yaml in installation directory (highest priority)..."
    fi
    
    if [[ -n "$config_file" ]] && [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                DOMAIN) EXISTING_DOMAIN="$value" ;;
                IPV4) EXISTING_IPV4="$value" ;;
                IPV6) EXISTING_IPV6="$value" ;;
                NETWORK) EXISTING_NETWORK="$value" ;;
                HTTP_ONLY) EXISTING_HTTP_ONLY="$value" ;;
                HTTPS_PORT) EXISTING_HTTPS_PORT="$value" ;;
                CV_ADDR) EXISTING_CV_ADDR="$value" ;;
                ENROLLMENT_TOKEN) EXISTING_ENROLLMENT_TOKEN="$value" ;;
                CV_PROXY) EXISTING_CV_PROXY="$value" ;;
                EOS_URL) EXISTING_EOS_URL="$value" ;;
                NTP_SERVER) EXISTING_NTP_SERVER="$value" ;;
                TIMEZONE) EXISTING_TIMEZONE="$value" ;;
                DNS1) EXISTING_DNS1="$value" ;;
                DNS2) EXISTING_DNS2="$value" ;;
                ADMIN_PASSWORD_HASH) EXISTING_ADMIN_PASSWORD_HASH="$value" ;;
                SESSION_TIMEOUT) EXISTING_SESSION_TIMEOUT="$value" ;;
            esac
        done < <(read_config_yaml "config.yaml" "$(dirname "$config_file")")
        log "  Loaded values from config.yaml"
    elif [[ -f "$install_config_file" ]]; then
        log "config.yaml found in installation directory but yq is not installed, skipping config.yaml read"
    fi
    
    # Read ztpbootstrap.env (only fill in values not already set from config.yaml)
    local env_file="${script_dir}/ztpbootstrap.env"
    if [[ -f "$env_file" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                CV_ADDR) [[ -z "$EXISTING_CV_ADDR" ]] && EXISTING_CV_ADDR="$value" ;;
                ENROLLMENT_TOKEN) [[ -z "$EXISTING_ENROLLMENT_TOKEN" ]] && EXISTING_ENROLLMENT_TOKEN="$value" ;;
                CV_PROXY) [[ -z "$EXISTING_CV_PROXY" ]] && EXISTING_CV_PROXY="$value" ;;
                EOS_URL) [[ -z "$EXISTING_EOS_URL" ]] && EXISTING_EOS_URL="$value" ;;
                NTP_SERVER) [[ -z "$EXISTING_NTP_SERVER" ]] && EXISTING_NTP_SERVER="$value" ;;
                TZ) [[ -z "$EXISTING_TIMEZONE" ]] && EXISTING_TIMEZONE="$value" ;;
            esac
        done < <(read_ztpbootstrap_env "$env_file")
    fi
    
    # Read container file
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    local container_values=""
    if [[ -d "$systemd_dir" ]]; then
        log "Reading container file from: $systemd_dir"
        container_values=$(read_container_file "$systemd_dir" 2>/dev/null || echo "")
        if [[ -z "$container_values" ]]; then
            log "No container values found (file may not exist or parsing failed)"
        else
            log "Container values found: $(echo "$container_values" | wc -l) lines"
        fi
    else
        log "Container directory does not exist: $systemd_dir"
    fi
    
    if [[ -n "$container_values" ]]; then
        log "Parsing container values..."
        # Use process substitution to ensure proper line-by-line reading
        local parsed_count=0
        # Disable exit on error for the entire read loop (read can fail on EOF)
        set +e
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            # Skip empty lines
            [[ -z "$key" ]] && continue
            # Trim whitespace from key
            key="${key// /}"
            # Trim whitespace and quotes from value
            value="${value# }"
            value="${value% }"
            value="${value#\"}"
            value="${value%\"}"
            
            case "$key" in
                Network) 
                    # If Network is "null" or empty, treat it as not set (will be detected from IP)
                    # Only set if not already set from config.yaml
                    if [[ "$value" != "null" ]] && [[ -n "$value" ]] && [[ -z "$EXISTING_NETWORK" ]]; then
                        EXISTING_NETWORK="$value"
                        log "  Found Network: $value"
                        parsed_count=$((parsed_count + 1)) || true
                    else
                        log "  Found Network: null or empty (will try to detect from IP)"
                    fi
                    ;;
                IP) 
                    # Only set if not already set from config.yaml
                    if [[ -z "$EXISTING_IPV4" ]]; then
                        EXISTING_IPV4="$value"
                        log "  Found IP: $value"
                        parsed_count=$((parsed_count + 1)) || true
                    fi
                    ;;
                IP6) 
                    # Only set if not already set from config.yaml
                    if [[ -z "$EXISTING_IPV6" ]]; then
                        EXISTING_IPV6="$value"
                        log "  Found IP6: $value"
                        parsed_count=$((parsed_count + 1)) || true
                    fi
                    ;;
                Environment)
                    # Handle Environment="TZ=America/Central" format
                    # Only set if not already set from config.yaml
                    if [[ "$value" =~ TZ=([^\"\']+) ]] && [[ -z "$EXISTING_TIMEZONE" ]]; then
                        EXISTING_TIMEZONE="${BASH_REMATCH[1]}"
                        log "  Found Timezone: ${BASH_REMATCH[1]}"
                    fi
                    ;;
            esac
            # DNS entries (may be multiple)
            # Only set if not already set from config.yaml
            if [[ "$key" == "DNS" ]]; then
                if [[ -z "$EXISTING_DNS1" ]]; then
                    EXISTING_DNS1="$value"
                    log "  Found DNS1: $value"
                    parsed_count=$((parsed_count + 1)) || true
                elif [[ -z "$EXISTING_DNS2" ]]; then
                    EXISTING_DNS2="$value"
                    log "  Found DNS2: $value"
                    parsed_count=$((parsed_count + 1)) || true
                else
                    log "  Found additional DNS entry: $value (already have DNS1 and DNS2)"
                fi
            fi
        done < <(printf '%s\n' "$container_values")
        # Re-enable exit on error
        set -e
        log "Parsed $parsed_count network-related values from container file"
    else
        log "No container values to parse"
    fi
    
    # If we have an IPv4 address but no network (or network is not "host"), try to find which network it belongs to
    if [[ -n "$EXISTING_IPV4" ]] && [[ -z "$EXISTING_NETWORK" ]]; then
        log "IPv4 address found ($EXISTING_IPV4) but no network specified, attempting to detect network..."
        local detected_network
        detected_network=$(find_network_for_ip "$EXISTING_IPV4" 2>/dev/null || echo "")
        if [[ -n "$detected_network" ]]; then
            EXISTING_NETWORK="$detected_network"
            log "  Detected network for $EXISTING_IPV4: $detected_network"
        else
            log "  Could not automatically detect network for $EXISTING_IPV4"
        fi
    fi
    
    # If we have an IPv6 address but no network, try to find which network it belongs to
    if [[ -n "$EXISTING_IPV6" ]] && [[ -z "$EXISTING_NETWORK" ]]; then
        log "IPv6 address found ($EXISTING_IPV6) but no network specified, attempting to detect network..."
        local detected_network
        detected_network=$(find_network_for_ip "$EXISTING_IPV6" 2>/dev/null || echo "")
        if [[ -n "$detected_network" ]]; then
            EXISTING_NETWORK="$detected_network"
            log "  Detected network for $EXISTING_IPV6: $detected_network"
        else
            log "  Could not automatically detect network for $EXISTING_IPV6"
        fi
    fi
    
    # Read nginx.conf (only fill in values not already set from config.yaml)
    local nginx_file="${script_dir}/nginx.conf"
    if [[ -f "$nginx_file" ]]; then
        log "Reading nginx.conf from: $nginx_file"
        while IFS='=' read -r key value; do
            case "$key" in
                DOMAIN) 
                    # Only set if not already set from config.yaml
                    if [[ -z "$EXISTING_DOMAIN" ]]; then
                        EXISTING_DOMAIN="$value"
                        log "  Found domain in nginx.conf: $value"
                    fi
                    ;;
                HTTP_ONLY) [[ -z "$EXISTING_HTTP_ONLY" ]] && EXISTING_HTTP_ONLY="$value" ;;
                HTTPS_PORT) [[ -z "$EXISTING_HTTPS_PORT" ]] && EXISTING_HTTPS_PORT="$value" ;;
            esac
        done < <(read_nginx_conf "$nginx_file")
    else
        log "nginx.conf not found at: $nginx_file"
    fi
    
    # If no domain found, try to detect system hostname/FQDN
    if [[ -z "$EXISTING_DOMAIN" ]]; then
        # Try hostname -f first (FQDN), fallback to hostname if -f doesn't work
        if command -v hostname >/dev/null 2>&1; then
            local system_fqdn
            # Try -f first (FQDN)
            system_fqdn=$(hostname -f 2>/dev/null || echo "")
            # If that didn't work or returned just hostname, try to get FQDN another way
            if [[ -z "$system_fqdn" ]] || [[ "$system_fqdn" == "$(hostname 2>/dev/null || echo "")" ]]; then
                # Try using domainname or dnsdomainname
                local hostname_short
                hostname_short=$(hostname 2>/dev/null || echo "")
                local domainname
                domainname=$(domainname 2>/dev/null || dnsdomainname 2>/dev/null || echo "")
                if [[ -n "$hostname_short" ]] && [[ -n "$domainname" ]] && [[ "$domainname" != "(none)" ]]; then
                    system_fqdn="${hostname_short}.${domainname}"
                elif [[ -n "$hostname_short" ]]; then
                    # Fallback to just hostname if no domain available
                    system_fqdn="$hostname_short"
                fi
            fi
            if [[ -n "$system_fqdn" ]] && [[ "$system_fqdn" != "localhost" ]] && [[ "$system_fqdn" != "localhost.localdomain" ]]; then
                EXISTING_DOMAIN="$system_fqdn"
                log "  Detected system FQDN: $system_fqdn"
            fi
        fi
    fi
    
    # Debug: Log loaded values
    log "Summary of loaded existing values:"
    if [[ -n "$EXISTING_DOMAIN" ]]; then
        log "  Domain: $EXISTING_DOMAIN"
    else
        log "  Domain: (not found)"
    fi
    if [[ -n "$EXISTING_IPV4" ]]; then
        log "  IPv4: $EXISTING_IPV4"
    else
        log "  IPv4: (not found)"
    fi
    if [[ -n "$EXISTING_IPV6" ]]; then
        log "  IPv6: $EXISTING_IPV6"
    else
        log "  IPv6: (not found)"
    fi
    if [[ -n "$EXISTING_NETWORK" ]]; then
        log "  Network: $EXISTING_NETWORK"
    else
        log "  Network: (not found)"
    fi
    if [[ -n "$EXISTING_HTTP_ONLY" ]]; then
        log "  HTTP-only mode: $EXISTING_HTTP_ONLY"
    else
        log "  HTTP-only mode: (not found)"
    fi
    if [[ -n "$EXISTING_HTTPS_PORT" ]]; then
        log "  HTTPS port: $EXISTING_HTTPS_PORT"
    else
        log "  HTTPS port: (not found)"
    fi
    if [[ -n "$EXISTING_CV_ADDR" ]]; then
        log "  CVaaS address: $EXISTING_CV_ADDR"
    else
        log "  CVaaS address: (not found)"
    fi
    if [[ -n "$EXISTING_ENROLLMENT_TOKEN" ]]; then
        log "  Enrollment token: (found, hidden)"
    else
        log "  Enrollment token: (not found)"
    fi
    if [[ -n "$EXISTING_TIMEZONE" ]]; then
        log "  Timezone: $EXISTING_TIMEZONE"
    fi
    if [[ -n "$EXISTING_DNS1" ]]; then
        log "  DNS server 1: $EXISTING_DNS1"
    else
        log "  DNS server 1: (not found)"
    fi
    if [[ -n "$EXISTING_DNS2" ]]; then
        log "  DNS server 2: $EXISTING_DNS2"
    else
        log "  DNS server 2: (not found)"
    fi
    
    log "Finished loading existing values from installation"
    return 0
}

# Clean installation directories
clean_installation_directories() {
    local script_dir="${1:-/opt/containerdata/ztpbootstrap}"
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    
    log "Cleaning installation directories..."
    
    # Clean service directory
    if [[ -d "$script_dir" ]]; then
        log "Cleaning: $script_dir"
        if [[ $EUID -eq 0 ]]; then
            find "$script_dir" -mindepth 1 -delete 2>/dev/null || warn "Failed to clean $script_dir"
        else
            sudo find "$script_dir" -mindepth 1 -delete 2>/dev/null || warn "Failed to clean $script_dir"
        fi
    fi
    
    # Clean systemd directory
    if [[ -d "$systemd_dir" ]]; then
        log "Cleaning: $systemd_dir"
        if [[ $EUID -eq 0 ]]; then
            find "$systemd_dir" -mindepth 1 -delete 2>/dev/null || warn "Failed to clean $systemd_dir"
        else
            sudo find "$systemd_dir" -mindepth 1 -delete 2>/dev/null || warn "Failed to clean $systemd_dir"
        fi
    fi
    
    log "Directories cleaned successfully"
    return 0
}

# Start services after installation
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

# Create a simple self-signed certificate for testing
create_self_signed_cert() {
    local cert_dir="${1:-${CERT_DIR:-/opt/containerdata/certs/wild}}"
    local domain="${2:-${DOMAIN:-ztpboot.example.com}}"
    local cert_file="${cert_dir}/${CERT_FILE:-fullchain.pem}"
    local key_file="${cert_dir}/${KEY_FILE:-privkey.pem}"
    
    # Check if certificates already exist
    if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
        log "SSL certificates already exist, skipping creation"
        return 0
    fi
    
    log "Creating self-signed certificate for testing..."
    log "Domain: $domain"
    log "Certificate directory: $cert_dir"
    
    # Create certificate directory if it doesn't exist
    if [[ ! -d "$cert_dir" ]]; then
        if [[ ("$cert_dir" =~ ^/etc/ || "$cert_dir" =~ ^/opt/) && $EUID -ne 0 ]]; then
            sudo mkdir -p "$cert_dir" 2>/dev/null || error "Failed to create certificate directory: $cert_dir"
        else
            mkdir -p "$cert_dir" 2>/dev/null || error "Failed to create certificate directory: $cert_dir"
        fi
    fi
    
    # Check if openssl is available
    if ! command -v openssl >/dev/null 2>&1; then
        error "openssl is required to create self-signed certificates but is not installed"
        return 1
    fi
    
    # Generate self-signed certificate
    log "Generating self-signed certificate..."
    if [[ ("$cert_dir" =~ ^/etc/ || "$cert_dir" =~ ^/opt/) && $EUID -ne 0 ]]; then
        sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$domain" \
            -addext "subjectAltName=DNS:$domain" 2>/dev/null || error "Failed to generate certificate"
        sudo chmod 644 "$cert_file" 2>/dev/null || true
        sudo chmod 644 "$key_file" 2>/dev/null || true
    else
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$domain" \
            -addext "subjectAltName=DNS:$domain" 2>/dev/null || error "Failed to generate certificate"
        chmod 644 "$cert_file" 2>/dev/null || true
        chmod 644 "$key_file" 2>/dev/null || true
    fi
    
    # Set SELinux context if SELinux is enabled and not on NFS
    if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        if ! is_nfs_mount "$cert_dir"; then
            if [[ ("$cert_dir" =~ ^/etc/ || "$cert_dir" =~ ^/opt/) && $EUID -ne 0 ]]; then
                sudo chcon -R -t container_file_t "$cert_dir" 2>/dev/null || true
            else
                chcon -R -t container_file_t "$cert_dir" 2>/dev/null || true
            fi
            log "Set SELinux context for certificate directory (not NFS)"
        else
            log "Certificate directory is on NFS, skipping SELinux context"
        fi
    fi
    
    log "Self-signed certificate created successfully"
    log "  Certificate: $cert_file"
    log "  Private Key: $key_file"
    warn "⚠️  This is a self-signed certificate and should not be used in production"
}

# Build webui container image from Containerfile if it exists
build_webui_image() {
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local containerfile="${repo_dir}/webui/Containerfile"
    local image_tag="ztpbootstrap-webui:local"
    
    # Check if Containerfile exists
    if [[ ! -f "$containerfile" ]]; then
        log "Containerfile not found at $containerfile, skipping image build"
        return 0
    fi
    
    # Check if podman is available
    if ! command -v podman >/dev/null 2>&1; then
        warn "podman not found, cannot build image. Will use base Fedora image."
        return 1
    fi
    
    # Check available disk space (need at least 1.5GB free for build)
    local available_space
    if command -v df >/dev/null 2>&1; then
        # Get available space in MB (works on both Linux and macOS)
        if df --version 2>/dev/null | grep -q GNU; then
            # GNU df (Linux)
            available_space=$(df -BM / 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/M//' || echo "0")
        else
            # BSD df (macOS) - output is in 512-byte blocks
            available_space=$(df / 2>/dev/null | tail -1 | awk '{print int($4 * 512 / 1024 / 1024)}' || echo "0")
        fi
        
        if [[ -n "$available_space" ]] && [[ "$available_space" -lt 1500 ]]; then
            warn "Insufficient disk space for image build: ${available_space}MB available (need at least 1500MB)"
            warn "The build process requires temporary space for layers and package installation."
            warn "Skipping image build. Container will use base Fedora image and install packages at runtime."
            warn "To free up space, you can run: podman system prune -a"
            return 1
        fi
    fi
    
    # Check if image already exists
    if podman image exists "$image_tag" 2>/dev/null; then
        log "Image $image_tag already exists"
        if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
            # Non-interactive: skip rebuild unless forced
            log "Non-interactive mode: Using existing image (use --force-rebuild to rebuild)"
            return 0
        else
            prompt_yes_no "Image $image_tag already exists. Rebuild it?" "n" REBUILD_IMAGE
            if [[ "$REBUILD_IMAGE" != "true" ]]; then
                log "Using existing image: $image_tag"
                return 0
            fi
        fi
    fi
    
    log "Building webui container image from Containerfile..."
    log "This will install Python, podman, and systemd in the image for faster container startup."
    log "Image tag: $image_tag"
    
    # Build the image
    local build_cmd="podman build -t $image_tag -f $containerfile $repo_dir"
    if [[ $EUID -ne 0 ]]; then
        # Non-root: podman should work in rootless mode
        if $build_cmd 2>&1; then
            log "✓ Successfully built image: $image_tag"
            return 0
        else
            warn "Failed to build image. Will use base Fedora image (packages will install at runtime)."
            return 1
        fi
    else
        # Root: use podman directly
        if $build_cmd 2>&1; then
            log "✓ Successfully built image: $image_tag"
            return 0
        else
            warn "Failed to build image. Will use base Fedora image (packages will install at runtime)."
            return 1
        fi
    fi
}

# Create pod and container systemd files from config.yaml
# This replicates the setup_pod() function from setup.sh
create_pod_files_from_config() {
    log "Creating pod and container systemd files..."
    
    # Get the directory where this script is located (repository directory)
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    local systemd_dir="/etc/containers/systemd/ztpbootstrap"
    
    # Create systemd directory (with sudo if needed)
    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$systemd_dir"
    else
        sudo mkdir -p "$systemd_dir"
    fi
    
    # Copy pod file
    if [[ -f "${repo_dir}/systemd/ztpbootstrap.pod" ]]; then
        if [[ $EUID -eq 0 ]]; then
            cp "${repo_dir}/systemd/ztpbootstrap.pod" "$systemd_dir/"
        else
            sudo cp "${repo_dir}/systemd/ztpbootstrap.pod" "$systemd_dir/"
        fi
        log "Pod configuration installed"
        
        # Update pod file with IP addresses from config.yaml
        local pod_file="${systemd_dir}/ztpbootstrap.pod"
        local config_file="${repo_dir}/config.yaml"
        
        if [[ -f "$config_file" ]] && command -v yq >/dev/null 2>&1; then
            local host_network
            local ipv4
            local ipv6
            local network
            host_network=$(yq eval '.container.host_network' "$config_file" 2>/dev/null || echo "")
            ipv4=$(yq eval '.network.ipv4' "$config_file" 2>/dev/null || echo "")
            ipv6=$(yq eval '.network.ipv6' "$config_file" 2>/dev/null || echo "")
            network=$(yq eval '.network.network' "$config_file" 2>/dev/null || echo "")
            
            # If network is null or empty, use detected network or default
            if [[ -z "$network" ]] || [[ "$network" == "null" ]]; then
                if [[ -n "${EXISTING_NETWORK:-}" ]] && [[ "${EXISTING_NETWORK}" != "host" ]]; then
                    network="$EXISTING_NETWORK"
                    log "Using detected network from existing installation: $network"
                else
                    network="ztpbootstrap-net"
                    log "Using default network: $network"
                fi
            fi
            
            log "Reading network config: host_network=$host_network, IPv4=$ipv4, IPv6=$ipv6, network=$network"
            
            # Use sudo for sed if not root
            local sed_cmd="sed"
            if [[ $EUID -ne 0 ]]; then
                sed_cmd="sudo sed"
            fi
            
            # Check if host network mode is enabled
            if [[ "$host_network" == "true" ]]; then
                $sed_cmd -i.tmp "s|^Network=.*|Network=host|" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                $sed_cmd -i.tmp "/^IP=/d" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                $sed_cmd -i.tmp "/^IP6=/d" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                log "Set Network=host in pod file"
            else
                # Set Network to specified network (or default ztpbootstrap-net)
                $sed_cmd -i.tmp "s|^Network=.*|Network=$network|" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                log "Set Network=$network in pod file"
                
                # Update IPv4
                if [[ -n "$ipv4" ]] && [[ "$ipv4" != "null" ]] && [[ "$ipv4" != "" ]]; then
                    if grep -q "^IP=" "$pod_file" 2>/dev/null; then
                        $sed_cmd -i.tmp "s|^IP=.*|IP=$ipv4|" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Updated pod IPv4 address to: $ipv4"
                    else
                        $sed_cmd -i.tmp "/^Network=/a IP=$ipv4" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Added IPv4 address: $ipv4"
                    fi
                else
                    $sed_cmd -i.tmp "/^IP=/d" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                    log "Removed IPv4 address from pod file"
                fi
                
                # Update IPv6
                if [[ -n "$ipv6" ]] && [[ "$ipv6" != "null" ]] && [[ "$ipv6" != "" ]]; then
                    if grep -q "^IP6=" "$pod_file" 2>/dev/null; then
                        $sed_cmd -i.tmp "s|^IP6=.*|IP6=$ipv6|" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                        log "Updated pod IPv6 address to: $ipv6"
                    else
                        if grep -q "^IP=" "$pod_file" 2>/dev/null; then
                            $sed_cmd -i.tmp "/^IP=/a IP6=$ipv6" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                        else
                            $sed_cmd -i.tmp "/^Network=/a IP6=$ipv6" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                        fi
                        log "Added IPv6 address: $ipv6"
                    fi
                else
                    $sed_cmd -i.tmp "/^IP6=/d" "$pod_file" 2>/dev/null && rm -f "${pod_file}.tmp" 2>/dev/null || true
                    log "Removed IPv6 address from pod file"
                fi
            fi
        fi
    else
        error "Pod configuration file not found: ${repo_dir}/systemd/ztpbootstrap.pod"
        return 1
    fi
    
    # Copy nginx container file
    if [[ -f "${repo_dir}/systemd/ztpbootstrap-nginx.container" ]]; then
        if [[ $EUID -eq 0 ]]; then
            cp "${repo_dir}/systemd/ztpbootstrap-nginx.container" "$systemd_dir/"
        else
            sudo cp "${repo_dir}/systemd/ztpbootstrap-nginx.container" "$systemd_dir/"
        fi
        log "Nginx container configuration installed"
        
        # Check if paths are on NFS and conditionally add :z flags for SELinux
        local nginx_container_file="${systemd_dir}/ztpbootstrap-nginx.container"
        local script_dir
        script_dir=$(yq eval '.paths.script_dir // "/opt/containerdata/ztpbootstrap"' "${repo_dir}/config.yaml" 2>/dev/null || echo "/opt/containerdata/ztpbootstrap")
        local cert_dir
        cert_dir=$(yq eval '.paths.cert_dir // "/opt/containerdata/certs/wild"' "${repo_dir}/config.yaml" 2>/dev/null || echo "/opt/containerdata/certs/wild")
        
        # Use sudo for sed if not root
        local sed_cmd="sed"
        if [[ $EUID -ne 0 ]]; then
            sed_cmd="sudo sed"
        fi
        
        # Check if certs directory is on NFS
        if ! is_nfs_mount "$cert_dir"; then
            # Not on NFS, add :z flag to certs volume mount if SELinux is enforcing
            if getenforce 2>/dev/null | grep -qi "enforcing"; then
                $sed_cmd -i.tmp "s|Volume=\(${cert_dir}.*\):ro|Volume=\1:ro,z|g" "$nginx_container_file" 2>/dev/null && rm -f "${nginx_container_file}.tmp" 2>/dev/null || true
                log "Added :z flag to certs volume mount (SELinux enforcing, not NFS)"
            fi
        else
            log "Certs directory is on NFS, skipping :z flag"
        fi
        
        # Check if logs directory is on NFS
        local logs_dir="${script_dir}/logs"
        if ! is_nfs_mount "$logs_dir"; then
            # Not on NFS, add :z flag to logs volume mount if SELinux is enforcing
            if getenforce 2>/dev/null | grep -qi "enforcing"; then
                $sed_cmd -i.tmp "s|Volume=\(${logs_dir}.*\):rw|Volume=\1:rw,z|g" "$nginx_container_file" 2>/dev/null && rm -f "${nginx_container_file}.tmp" 2>/dev/null || true
                log "Added :z flag to logs volume mount (SELinux enforcing, not NFS)"
            fi
        else
            log "Logs directory is on NFS, skipping :z flag"
        fi
    else
        error "Nginx container configuration not found: ${repo_dir}/systemd/ztpbootstrap-nginx.container"
        return 1
    fi
    
    # Copy webui container file if it exists
    if [[ -f "${repo_dir}/systemd/ztpbootstrap-webui.container" ]]; then
        if [[ $EUID -eq 0 ]]; then
            cp "${repo_dir}/systemd/ztpbootstrap-webui.container" "$systemd_dir/"
        else
            sudo cp "${repo_dir}/systemd/ztpbootstrap-webui.container" "$systemd_dir/"
        fi
        log "Web UI container configuration installed"
        
        # Determine which image to use for webui container
        local webui_container_file="${systemd_dir}/ztpbootstrap-webui.container"
        local script_dir
        script_dir=$(yq eval '.paths.script_dir // "/opt/containerdata/ztpbootstrap"' "${repo_dir}/config.yaml" 2>/dev/null || echo "/opt/containerdata/ztpbootstrap")
        local config_file="${script_dir}/config.yaml"
        local image_tag=""
        
        # First, check if a registry image was configured (from previous setup)
        if [[ -f "$config_file" ]]; then
            local registry_image
            registry_image=$(yq eval '.webui.registry_image // ""' "$config_file" 2>/dev/null || echo "")
            if [[ -n "$registry_image" ]] && [[ "$registry_image" != "null" ]] && [[ "$registry_image" != "" ]]; then
                image_tag="$registry_image"
                log "Found configured webui image in config.yaml: $image_tag"
            fi
        fi
        
        # If no registry image, check for local image
        if [[ -z "$image_tag" ]]; then
            local local_tag="ztpbootstrap-webui:local"
            if podman image exists "$local_tag" 2>/dev/null; then
                image_tag="$local_tag"
                log "Found local webui image: $image_tag"
            fi
        fi
        
        # If we have an image tag, update the container file
        if [[ -n "$image_tag" ]]; then
            local sed_cmd="sed"
            if [[ $EUID -ne 0 ]]; then
                sed_cmd="sudo sed"
            fi
            if $sed_cmd -i.tmp "s|^Image=.*|Image=$image_tag|" "$webui_container_file" 2>/dev/null; then
                rm -f "${webui_container_file}.tmp" 2>/dev/null || true
                log "✓ Updated webui container to use image: $image_tag"
            else
                warn "Failed to update container file with image tag. Using default from container file."
            fi
        else
            log "No custom webui image found. Container will use base Fedora image and install packages at runtime."
        fi
        
        # Copy webui directory to script directory (required for webui container)
        # Get script_dir from config.yaml or use default
        local script_dir_for_webui
        script_dir_for_webui=$(yq eval '.paths.script_dir // "/opt/containerdata/ztpbootstrap"' "${repo_dir}/config.yaml" 2>/dev/null || echo "/opt/containerdata/ztpbootstrap")
        local webui_dest="${script_dir_for_webui}/webui"
        if [[ ! -d "$webui_dest" ]]; then
            if [[ $EUID -eq 0 ]]; then
                mkdir -p "$webui_dest" || {
                    warn "Failed to create webui directory: $webui_dest"
                }
            else
                sudo mkdir -p "$webui_dest" || {
                    warn "Failed to create webui directory: $webui_dest"
                }
            fi
        fi
        if [[ -d "${repo_dir}/webui" ]]; then
            if [[ $EUID -eq 0 ]]; then
                if cp -r "${repo_dir}/webui"/* "$webui_dest/" 2>/dev/null; then
                    log "Web UI directory copied to: $webui_dest"
                    # Ensure start-webui.sh is executable
                    if [[ -f "${webui_dest}/start-webui.sh" ]]; then
                        chmod +x "${webui_dest}/start-webui.sh" 2>/dev/null || true
                        log "Made start-webui.sh executable"
                    fi
                else
                    warn "Failed to copy webui directory, Web UI may not work"
                fi
            else
                if sudo cp -r "${repo_dir}/webui"/* "$webui_dest/" 2>/dev/null; then
                    log "Web UI directory copied to: $webui_dest"
                    # Ensure start-webui.sh is executable
                    if [[ -f "${webui_dest}/start-webui.sh" ]]; then
                        sudo chmod +x "${webui_dest}/start-webui.sh" 2>/dev/null || true
                        log "Made start-webui.sh executable"
                    fi
                else
                    warn "Failed to copy webui directory, Web UI may not work"
                fi
            fi
        else
            warn "Web UI source directory not found: ${repo_dir}/webui"
        fi
    fi
    
    return 0
}

start_services_after_install() {
    log "Starting new services..."
    
    # Enable and start podman.socket if not already running
    # This is required for the webui container to access podman commands
    if systemctl is-enabled podman.socket >/dev/null 2>&1; then
        if ! systemctl is-active podman.socket >/dev/null 2>&1; then
            log "Starting podman.socket..."
            if systemctl start podman.socket 2>&1; then
                log "✓ podman.socket started"
            else
                warn "Failed to start podman.socket (webui container may not be able to access podman commands)"
            fi
        else
            log "✓ podman.socket is already running"
        fi
    else
        log "Enabling and starting podman.socket..."
        if systemctl enable --now podman.socket 2>&1; then
            log "✓ podman.socket enabled and started"
        else
            warn "Failed to enable/start podman.socket (webui container may not be able to access podman commands)"
        fi
    fi
    
    # Reload systemd first
    if [[ $EUID -eq 0 ]]; then
        systemctl daemon-reload
    else
        sudo systemctl daemon-reload
    fi
    
    sleep 2
    
    
    # Verify services exist before trying to start them
    # Check both generator directory (temporary) and systemd system directory (permanent)
    local generator_dir="/run/systemd/generator"
    local systemd_system_dir="/etc/systemd/system"
    local pod_service_exists=false
    
    # Check if file exists in either location (with sudo if needed)
    if [[ -f "${generator_dir}/ztpbootstrap-pod.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-pod.service" ]]; then
        pod_service_exists=true
    elif [[ $EUID -ne 0 ]]; then
        if sudo test -f "${generator_dir}/ztpbootstrap-pod.service" 2>/dev/null || sudo test -f "${systemd_system_dir}/ztpbootstrap-pod.service" 2>/dev/null; then
            pod_service_exists=true
        fi
    fi
    
    if [[ "$pod_service_exists" == "false" ]]; then
        warn "⚠️  Pod service file not found. Reloading systemd and waiting for generation..."
        if [[ $EUID -eq 0 ]]; then
            systemctl daemon-reload
        else
            sudo systemctl daemon-reload
        fi
        sleep 5  # Give more time for systemd generator to run
        
        # Check again (both locations)
        pod_service_exists=false
        if [[ -f "${generator_dir}/ztpbootstrap-pod.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-pod.service" ]]; then
            pod_service_exists=true
        elif [[ $EUID -ne 0 ]]; then
            if sudo test -f "${generator_dir}/ztpbootstrap-pod.service" 2>/dev/null || sudo test -f "${systemd_system_dir}/ztpbootstrap-pod.service" 2>/dev/null; then
                pod_service_exists=true
            fi
        fi
        
        if [[ "$pod_service_exists" == "false" ]]; then
            error "Pod service file still not found. Cannot start services."
            error "Please run: sudo systemctl daemon-reload"
            error "Then check: sudo ls -la /run/systemd/generator/ | grep ztpbootstrap"
            error "Or check: sudo ls -la /etc/systemd/system/ | grep ztpbootstrap"
            return 1
        fi
    fi
    
    # Start pod service (quadlet generates ztpbootstrap-pod.service from ztpbootstrap.pod)
    local pod_service_name="ztpbootstrap-pod.service"
    if [[ $EUID -eq 0 ]]; then
        if systemctl start "$pod_service_name" 2>&1; then
            log "✓ Started $pod_service_name"
            sleep 2
        else
            local pod_error
            pod_error=$(systemctl status "$pod_service_name" --no-pager -l 2>&1 | tail -10 || echo "Could not get status")
            warn "Failed to start $pod_service_name"
            warn "Error details: ${pod_error:0:300}"
        fi
        
        # Start nginx container
        if systemctl start ztpbootstrap-nginx.service 2>/dev/null; then
            log "✓ Started ztpbootstrap-nginx.service"
        else
            warn "Failed to start ztpbootstrap-nginx.service"
        fi
        
        # Helper function to diagnose webui startup failures
        diagnose_webui_failure() {
            warn "=== WebUI Container Startup Diagnostics ==="
            
            # Check service file locations
            local generator_file="/run/systemd/generator/ztpbootstrap-webui.service"
            local system_file="/etc/systemd/system/ztpbootstrap-webui.service"
            
            warn "Service file locations:"
            if [[ -f "$generator_file" ]] || ([[ $EUID -ne 0 ]] && sudo test -f "$generator_file" 2>/dev/null); then
                warn "  ✓ Found: $generator_file"
            else
                warn "  ✗ Not found: $generator_file"
            fi
            if [[ -f "$system_file" ]] || ([[ $EUID -ne 0 ]] && sudo test -f "$system_file" 2>/dev/null); then
                warn "  ✓ Found: $system_file"
            else
                warn "  ✗ Not found: $system_file"
            fi
            
            # Check service status
            warn "Service status:"
            if [[ $EUID -eq 0 ]]; then
                systemctl status ztpbootstrap-webui.service --no-pager -l 2>&1 | head -20 | sed 's/^/    /' | while IFS= read -r line; do
                    warn "$line"
                done || true
            else
                sudo systemctl status ztpbootstrap-webui.service --no-pager -l 2>&1 | head -20 | sed 's/^/    /' | while IFS= read -r line; do
                    warn "$line"
                done || true
            fi
            
            # Check if container exists
            if podman ps -a --filter name=ztpbootstrap-webui --format "{{.Names}}" 2>/dev/null | grep -q ztpbootstrap-webui; then
                warn "Container exists (may be stopped):"
                podman ps -a --filter name=ztpbootstrap-webui 2>/dev/null | sed 's/^/    /' | while IFS= read -r line; do
                    warn "$line"
                done
                warn "Container logs (last 30 lines):"
                podman logs ztpbootstrap-webui --tail 30 2>&1 | sed 's/^/    /' | while IFS= read -r line; do
                    warn "$line"
                done || true
            else
                warn "  ✗ Container does not exist"
            fi
            
            # Check journal logs
            warn "Systemd journal (last 20 lines):"
            if [[ $EUID -eq 0 ]]; then
                journalctl -u ztpbootstrap-webui.service -n 20 --no-pager 2>&1 | sed 's/^/    /' | while IFS= read -r line; do
                    warn "$line"
                done || true
            else
                sudo journalctl -u ztpbootstrap-webui.service -n 20 --no-pager 2>&1 | sed 's/^/    /' | while IFS= read -r line; do
                    warn "$line"
                done || true
            fi
            
            # Check if required files exist
            warn "Required files:"
            if [[ -f "/opt/containerdata/ztpbootstrap/webui/start-webui.sh" ]] || ([[ $EUID -ne 0 ]] && sudo test -f "/opt/containerdata/ztpbootstrap/webui/start-webui.sh" 2>/dev/null); then
                warn "  ✓ /opt/containerdata/ztpbootstrap/webui/start-webui.sh exists"
                if [[ -x "/opt/containerdata/ztpbootstrap/webui/start-webui.sh" ]] || ([[ $EUID -ne 0 ]] && sudo test -x "/opt/containerdata/ztpbootstrap/webui/start-webui.sh" 2>/dev/null); then
                    warn "  ✓ start-webui.sh is executable"
                else
                    warn "  ✗ start-webui.sh is NOT executable"
                fi
            else
                warn "  ✗ /opt/containerdata/ztpbootstrap/webui/start-webui.sh NOT FOUND"
            fi
            if [[ -f "/opt/containerdata/ztpbootstrap/webui/app.py" ]] || ([[ $EUID -ne 0 ]] && sudo test -f "/opt/containerdata/ztpbootstrap/webui/app.py" 2>/dev/null); then
                warn "  ✓ /opt/containerdata/ztpbootstrap/webui/app.py exists"
            else
                warn "  ✗ /opt/containerdata/ztpbootstrap/webui/app.py NOT FOUND"
            fi
            
            warn "=== End Diagnostics ==="
        }
        
        # Start webui container if it exists
        if systemctl list-unit-files | grep -q ztpbootstrap-webui.service; then
            log "Starting webui container..."
            local start_cmd="systemctl start ztpbootstrap-webui.service"
            if [[ $EUID -ne 0 ]]; then
                start_cmd="sudo systemctl start ztpbootstrap-webui.service"
            fi
            
            if $start_cmd 2>&1; then
                # Wait a moment for container to start
                sleep 3
                
                # Verify service is actually running
                local is_active_cmd="systemctl is-active --quiet ztpbootstrap-webui.service"
                if [[ $EUID -ne 0 ]]; then
                    is_active_cmd="sudo systemctl is-active --quiet ztpbootstrap-webui.service"
                fi
                
                if $is_active_cmd; then
                    # Verify container is actually running
                    if podman ps --filter name=ztpbootstrap-webui --format "{{.Names}}" 2>/dev/null | grep -q ztpbootstrap-webui; then
                        log "✓ Started ztpbootstrap-webui.service and container is running"
                    else
                        warn "⚠️  Service reports active but container is not running"
                        diagnose_webui_failure
                    fi
                else
                    warn "⚠️  Service start command succeeded but service is not active"
                    diagnose_webui_failure
                    
                    # Try once more after showing diagnostics
                    log "Retrying webui container start..."
                    sleep 2
                    if $start_cmd 2>&1; then
                        sleep 3
                        if $is_active_cmd && podman ps --filter name=ztpbootstrap-webui --format "{{.Names}}" 2>/dev/null | grep -q ztpbootstrap-webui; then
                            log "✓ Started ztpbootstrap-webui.service on retry and container is running"
                        else
                            warn "⚠️  Webui container still not running after retry"
                            diagnose_webui_failure
                        fi
                    fi
                fi
            else
                warn "Failed to start ztpbootstrap-webui.service"
                diagnose_webui_failure
            fi
        fi
    else
        if sudo systemctl start "$pod_service_name" 2>&1; then
            log "✓ Started $pod_service_name"
            sleep 2
        else
            local pod_error
            pod_error=$(sudo systemctl status "$pod_service_name" --no-pager -l 2>&1 | tail -10 || echo "Could not get status")
            warn "Failed to start $pod_service_name"
            warn "Error details: ${pod_error:0:300}"
        fi
        
        if sudo systemctl start ztpbootstrap-nginx.service 2>/dev/null; then
            log "✓ Started ztpbootstrap-nginx.service"
        else
            warn "Failed to start ztpbootstrap-nginx.service"
        fi
        
        if systemctl list-unit-files | grep -q ztpbootstrap-webui.service; then
            if sudo systemctl start ztpbootstrap-webui.service 2>/dev/null; then
                log "✓ Started ztpbootstrap-webui.service"
            else
                warn "Failed to start ztpbootstrap-webui.service"
            fi
        fi
    fi
    
    log "Service startup completed"
    return 0
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
    
    # Section 1: Authentication Configuration (Web UI) - moved first
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Authentication Configuration (Web UI)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    log "The Web UI allows read-only access by default. Write operations (upload, delete,"
    log "modify scripts) require authentication. Set an admin password to enable this."
    echo ""
    
    # Check if --reset-pass was provided (takes precedence)
    if [[ -n "${RESET_PASSWORD:-}" ]]; then
        log "Password reset requested via --reset-pass flag."
        # Debug: log password details (without exposing the actual password)
        log "Password length: ${#RESET_PASSWORD} characters"
        # Validate password length
        if [[ ${#RESET_PASSWORD} -lt 8 ]]; then
            error "Password must be at least 8 characters long."
            exit 1
        fi
        # Hash the password using Python (use stdin to avoid shell escaping issues)
        log "Hashing password..."
        # Try werkzeug first (suppress stderr to avoid traceback)
        ADMIN_PASSWORD_HASH=$(echo "$RESET_PASSWORD" | python3 2>/dev/null <<'PYTHON_SCRIPT'
import sys
password = sys.stdin.read().rstrip('\n')
# Verify we got the password correctly
if len(password) == 0:
    sys.stderr.write("ERROR: Empty password received!\n")
    sys.exit(1)
try:
    from werkzeug.security import generate_password_hash
    hash_value = generate_password_hash(password)
    print(hash_value)
except ImportError:
    # Werkzeug not available, fall back to hashlib
    import hashlib
    import base64
    hash_value = 'pbkdf2:sha256:' + base64.b64encode(hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)).decode()
    print(hash_value)
PYTHON_SCRIPT
)
        
        if [[ -z "$ADMIN_PASSWORD_HASH" ]]; then
            # Fallback: use Python's built-in hashlib (should always be available)
            ADMIN_PASSWORD_HASH=$(echo "$RESET_PASSWORD" | python3 <<'PYTHON_SCRIPT' 2>/dev/null
import sys
import hashlib
import base64
password = sys.stdin.read().rstrip('\n')
hash_value = 'pbkdf2:sha256:' + base64.b64encode(hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)).decode()
print(hash_value)
PYTHON_SCRIPT
)
        fi
        
        if [[ -n "$ADMIN_PASSWORD_HASH" ]]; then
            log "Password hash generated successfully."
            log "Hash format: $(echo "$ADMIN_PASSWORD_HASH" | cut -d: -f1)"
            log "Hash length: ${#ADMIN_PASSWORD_HASH} characters"
            log "Hash preview: ${ADMIN_PASSWORD_HASH:0:30}..."
            
            # Verify the hash works with the password we just hashed
            log "Verifying hash matches password..."
            VERIFICATION_RESULT=$(echo "$RESET_PASSWORD" | python3 2>/dev/null <<PYTHON_VERIFY
import sys
import hashlib
import base64
password = sys.stdin.read().rstrip('\n')
hash_value = "$ADMIN_PASSWORD_HASH"

if hash_value.startswith('pbkdf2:sha256:') and '\$' not in hash_value:
    hash_part = hash_value.split(':', 2)[2]
    stored_hash = base64.b64decode(hash_part)
    computed_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)
    match = (stored_hash == computed_hash)
    print("MATCH" if match else "MISMATCH")
else:
    try:
        from werkzeug.security import check_password_hash
        match = check_password_hash(hash_value, password)
        print("MATCH" if match else "MISMATCH")
    except:
        print("ERROR")
PYTHON_VERIFY
)
            
            if [[ "$VERIFICATION_RESULT" == "MATCH" ]]; then
                log "✓ Hash verification successful - password and hash match"
            else
                error "✗ Hash verification FAILED - password and hash do not match!"
                error "This indicates a bug in password hashing. Please report this issue."
                error "Password length was: ${#RESET_PASSWORD}"
                exit 1
            fi
            
            SET_ADMIN_PASSWORD="true"
            # Clear password from memory
            RESET_PASSWORD=""
        else
            error "Failed to hash password. Authentication will not be configured."
            exit 1
        fi
    # In upgrade mode, use existing password hash if available (unless --reset-pass was used)
    elif [[ "${UPGRADE_MODE:-false}" == "true" ]] && [[ -n "${EXISTING_ADMIN_PASSWORD_HASH:-}" ]]; then
        log "Upgrade mode: Using existing admin password hash from previous installation."
        ADMIN_PASSWORD_HASH="${EXISTING_ADMIN_PASSWORD_HASH}"
        SET_ADMIN_PASSWORD="true"
        if [[ -n "${EXISTING_SESSION_TIMEOUT:-}" ]]; then
            SESSION_TIMEOUT="${EXISTING_SESSION_TIMEOUT}"
        fi
    else
        # Ask if user wants to set a password
        prompt_yes_no "Set admin password for Web UI write operations?" "y" SET_ADMIN_PASSWORD
        
        if [[ "$SET_ADMIN_PASSWORD" == "true" ]]; then
        # Prompt for password with confirmation
        local password_valid=false
        local attempts=0
        while [[ "$password_valid" == "false" ]] && [[ $attempts -lt 3 ]]; do
            attempts=$((attempts + 1))
            
            # Prompt for password (hidden input)
            echo -n "Enter admin password (min 8 characters): "
            read -s ADMIN_PASSWORD
            echo ""
            
            # Validate password length
            if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
                warn "Password must be at least 8 characters long."
                continue
            fi
            
            # Prompt for confirmation
            echo -n "Confirm admin password: "
            read -s ADMIN_PASSWORD_CONFIRM
            echo ""
            
            # Check if passwords match
            if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
                warn "Passwords do not match. Please try again."
                continue
            fi
            
            # Password is valid
            password_valid=true
            
            # Hash the password using Python
            log "Hashing password..."
            # Try werkzeug first (if available in webui container), but fall back to hashlib
            # Use || true to prevent script exit due to set -e
            ADMIN_PASSWORD_HASH=$(python3 -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('$ADMIN_PASSWORD'))" 2>/dev/null || true)
            
            if [[ -z "$ADMIN_PASSWORD_HASH" ]]; then
                # Fallback: use Python's built-in hashlib (should always be available)
                ADMIN_PASSWORD_HASH=$(python3 -c "import hashlib, base64; print('pbkdf2:sha256:' + base64.b64encode(hashlib.pbkdf2_hmac('sha256', b'$ADMIN_PASSWORD', b'ztpbootstrap', 100000)).decode())" 2>/dev/null || true)
            fi
            
            if [[ -n "$ADMIN_PASSWORD_HASH" ]]; then
                log "Password set successfully (hashed)"
            else
                error "Failed to hash password. Authentication will not be configured."
                ADMIN_PASSWORD_HASH=""
            fi
            
            # Clear plain text password from memory
            ADMIN_PASSWORD=""
            ADMIN_PASSWORD_CONFIRM=""
        done
        
        if [[ "$password_valid" == "false" ]]; then
            warn "Failed to set password after $attempts attempts. Skipping authentication setup."
            ADMIN_PASSWORD_HASH=""
        fi
        fi
    fi
    
    # Session timeout - only prompt in extended mode
    if [[ "${EXTENDED_MODE:-false}" == "true" ]]; then
        prompt_with_default "Session timeout in seconds" "3600" SESSION_TIMEOUT
    else
        # Use default when not in extended mode
        SESSION_TIMEOUT="${SESSION_TIMEOUT:-3600}"
    fi
    
    # Generate session secret
    if command -v python3 >/dev/null 2>&1; then
        SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || true)
    fi
    
    # Fallback to openssl if python3 method failed or is not available
    if [[ -z "$SESSION_SECRET" ]] && command -v openssl >/dev/null 2>&1; then
        SESSION_SECRET=$(openssl rand -hex 32 2>/dev/null || true)
    fi
    
    if [[ -z "$SESSION_SECRET" ]]; then
        warn "Failed to generate session secret. A default will be used (less secure)."
        SESSION_SECRET=""
    fi
    
    echo ""
    
    # Section 2: Directory Paths
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Directory Paths${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Main service directory" "${EXISTING_SCRIPT_DIR:-/opt/containerdata/ztpbootstrap}" SCRIPT_DIR
    # Validate SCRIPT_DIR is a reasonable path (not just a single character or yes/no)
    if [[ "${#SCRIPT_DIR}" -lt 3 ]] || [[ "$SCRIPT_DIR" =~ ^[yYnN]$ ]]; then
        warn "Invalid directory path: '$SCRIPT_DIR'. Using default."
        SCRIPT_DIR="${EXISTING_SCRIPT_DIR:-/opt/containerdata/ztpbootstrap}"
        log "Using default: $SCRIPT_DIR"
    fi
    prompt_with_default "SSL certificate directory" "/opt/containerdata/certs/wild" CERT_DIR
    # Store CERT_DIR for later use in SSL certificate detection
    local cert_dir_for_check="$CERT_DIR"
    prompt_with_default "Environment file path" "${SCRIPT_DIR}/ztpbootstrap.env" ENV_FILE
    prompt_with_default "Bootstrap script path" "${SCRIPT_DIR}/bootstrap.py" BOOTSTRAP_SCRIPT
    prompt_with_default "Nginx config file" "${SCRIPT_DIR}/nginx.conf" NGINX_CONF
    
    echo ""
    
    # Section 3: Network Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Network Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Determine default domain (existing, system FQDN, or example)
    local default_domain="${EXISTING_DOMAIN:-}"
    if [[ -z "$default_domain" ]]; then
        # Try system FQDN as fallback
        if command -v hostname >/dev/null 2>&1; then
            # Try -f first (FQDN)
            default_domain=$(hostname -f 2>/dev/null || echo "")
            # If that didn't work or returned just hostname, try to get FQDN another way
            if [[ -z "$default_domain" ]] || [[ "$default_domain" == "$(hostname 2>/dev/null || echo "")" ]]; then
                # Try using domainname or dnsdomainname
                local hostname_short
                hostname_short=$(hostname 2>/dev/null || echo "")
                local domainname
                domainname=$(domainname 2>/dev/null || dnsdomainname 2>/dev/null || echo "")
                if [[ -n "$hostname_short" ]] && [[ -n "$domainname" ]] && [[ "$domainname" != "(none)" ]]; then
                    default_domain="${hostname_short}.${domainname}"
                elif [[ -n "$hostname_short" ]]; then
                    # Fallback to just hostname if no domain available
                    default_domain="$hostname_short"
                fi
            fi
            if [[ -z "$default_domain" ]] || [[ "$default_domain" == "localhost" ]] || [[ "$default_domain" == "localhost.localdomain" ]]; then
                default_domain="ztpboot.example.com"
            fi
        else
            default_domain="ztpboot.example.com"
        fi
    fi
    prompt_with_default "Domain name" "$default_domain" DOMAIN
    
    # Ask about host network mode FIRST, so user can override detected IP addresses
    # Determine default host network mode from existing network config
    local default_host_network="n"
    if [[ "${EXISTING_NETWORK:-}" == "host" ]]; then
        default_host_network="y"
    fi
    prompt_yes_no "Use host network mode? (overrides IP addresses, useful for testing)" "$default_host_network" HOST_NETWORK
    
    # If host network is enabled, clear IP addresses and skip IP prompts
    if [[ "$HOST_NETWORK" == "true" ]]; then
        IPV4=""
        IPV6=""
        log "Host network mode enabled - IP addresses will be ignored"
    else
        # For IPv4, use existing value if set, otherwise default to 10.0.0.10
        local default_ipv4="10.0.0.10"
        if [[ -n "${EXISTING_IPV4:-}" ]]; then
            default_ipv4="$EXISTING_IPV4"
        fi
        # Clearer prompt wording: if there's a default, pressing Enter uses it
        if [[ -n "$default_ipv4" ]]; then
            prompt_with_default "IPv4 address" "$default_ipv4" IPV4 "false" "true"
        else
            prompt_with_default "IPv4 address (leave empty for host network)" "" IPV4 "false" "true"
        fi
        
        # For IPv6, use existing value if set (even if empty), otherwise default to empty
        local default_ipv6=""
        if [[ -n "${EXISTING_IPV6:-}" ]]; then
            default_ipv6="$EXISTING_IPV6"
        elif [[ -z "${EXISTING_IPV6:-}" ]] && [[ "${EXISTING_IPV6+set}" == "set" ]]; then
            # IPv6 was explicitly set to empty in existing config
            default_ipv6=""
        else
            # IPv6 was not set at all, use empty as default (to disable)
            default_ipv6=""
        fi
        # Clearer prompt wording: if there's a default, pressing Enter uses it
        if [[ -n "$default_ipv6" ]]; then
            prompt_with_default "IPv6 address" "$default_ipv6" IPV6 "false" "true"
        else
            prompt_with_default "IPv6 address (leave empty to disable)" "" IPV6 "false" "true"
        fi
    fi
    # HTTPS and HTTP ports - only prompt in extended mode
    if [[ "${EXTENDED_MODE:-false}" == "true" ]]; then
        prompt_with_default "HTTPS port" "${EXISTING_HTTPS_PORT:-443}" HTTPS_PORT
        prompt_with_default "HTTP port" "80" HTTP_PORT
    else
        # Use defaults when not in extended mode
        HTTPS_PORT="${HTTPS_PORT:-${EXISTING_HTTPS_PORT:-443}}"
        HTTP_PORT="${HTTP_PORT:-80}"
    fi
    # Determine default for HTTP-only mode
    local default_http_only="n"
    if [[ "${EXISTING_HTTP_ONLY:-}" == "true" ]]; then
        default_http_only="y"
    fi
    prompt_yes_no "Use HTTP-only mode (insecure, not recommended)" "$default_http_only" HTTP_ONLY
    
    echo ""
    
    # Section 4: CVaaS Configuration
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
    
    prompt_with_default "CVaaS address" "${EXISTING_CV_ADDR:-www.arista.io}" CV_ADDR
    prompt_with_default "Enrollment token (from CVaaS Device Registration)" "${EXISTING_ENROLLMENT_TOKEN:-}" ENROLLMENT_TOKEN "true"
    # Proxy URL and EOS image URL - only prompt in extended mode
    if [[ "${EXTENDED_MODE:-false}" == "true" ]]; then
        prompt_with_default "Proxy URL (leave empty if not needed)" "${EXISTING_CV_PROXY:-}" CV_PROXY
        prompt_with_default "EOS image URL (optional, for upgrades)" "${EXISTING_EOS_URL:-}" EOS_URL
    else
        # Use defaults when not in extended mode
        CV_PROXY="${CV_PROXY:-${EXISTING_CV_PROXY:-}}"
        EOS_URL="${EOS_URL:-${EXISTING_EOS_URL:-}}"
    fi
    prompt_with_default "NTP server" "${EXISTING_NTP_SERVER:-time.nist.gov}" NTP_SERVER
    
    echo ""
    
    # Section 5: SSL Certificate Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  SSL Certificate Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Certificate filename" "fullchain.pem" CERT_FILE
    prompt_with_default "Private key filename" "privkey.pem" KEY_FILE
    
    # Check if certificates already exist (use the cert_dir_for_check variable set earlier)
    local cert_path="${cert_dir_for_check}/${CERT_FILE}"
    local key_path="${cert_dir_for_check}/${KEY_FILE}"
    local certs_exist=false
    
    if [[ -f "$cert_path" ]] && [[ -f "$key_path" ]]; then
        certs_exist=true
        log "Existing SSL certificates detected at:"
        log "  Certificate: $cert_path"
        log "  Private Key: $key_path"
        log "Skipping Let's Encrypt and self-signed certificate prompts (certificates managed externally)"
    fi
    
    if [[ "$certs_exist" == "false" ]]; then
        prompt_yes_no "Use Let's Encrypt with certbot?" "n" USE_LETSENCRYPT
        
        if [[ "$USE_LETSENCRYPT" == "true" ]]; then
            prompt_with_default "Email for Let's Encrypt registration" "admin@example.com" LETSENCRYPT_EMAIL
        else
            LETSENCRYPT_EMAIL="admin@example.com"
        fi
        
        # Default to creating self-signed certificate if HTTP_ONLY is false (HTTPS mode)
        # This ensures nginx can start without manual certificate creation
        local default_self_signed="n"
        if [[ "${HTTP_ONLY:-false}" == "false" ]]; then
            default_self_signed="y"
        fi
        
        prompt_yes_no "Create self-signed certificate for testing (if no cert exists)?" "$default_self_signed" CREATE_SELF_SIGNED
    else
        # Certificates exist, skip these prompts
        USE_LETSENCRYPT="false"
        LETSENCRYPT_EMAIL="admin@example.com"
        CREATE_SELF_SIGNED="false"
    fi
    
    echo ""
    
    # Section 6: Container Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Container Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Container name" "ztpbootstrap" CONTAINER_NAME
    # Container image is not prompted - nginx uses alpine, webui uses fedora (or built image)
    # Set default value for config generation
    CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/nginx:alpine}"
    # Timezone - only prompt in extended mode
    if [[ "${EXTENDED_MODE:-false}" == "true" ]]; then
        prompt_with_default "Timezone" "${EXISTING_TIMEZONE:-UTC}" TIMEZONE
    else
        # Use default when not in extended mode
        TIMEZONE="${TIMEZONE:-${EXISTING_TIMEZONE:-UTC}}"
    fi
    # Note: Host network mode is now asked in the Network Configuration section above
    # This ensures it can override detected IP addresses
    prompt_with_default "DNS server 1" "${EXISTING_DNS1:-8.8.8.8}" DNS1
    prompt_with_default "DNS server 2" "${EXISTING_DNS2:-8.8.4.4}" DNS2
    
    echo ""
    
    # Section 7: WebUI Image Configuration (only shown if Containerfile exists)
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local containerfile="${repo_dir}/webui/Containerfile"
    
    if [[ -f "$containerfile" ]]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  WebUI Container Image${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        log "A Containerfile is available to build an optimized webui image."
        log "Building the image will pre-install Python, podman, and systemd,"
        log "resulting in much faster container startup times (no package installation)."
        echo ""
        
        if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
            BUILD_WEBUI_IMAGE="true"
            log "Non-interactive mode: Will build webui image from Containerfile"
        else
            prompt_yes_no "Build optimized webui image from Containerfile? (recommended)" "y" BUILD_WEBUI_IMAGE
        fi
        
        # Build the image now if requested
        if [[ "${BUILD_WEBUI_IMAGE:-false}" == "true" ]]; then
            if build_webui_image; then
                # Image built successfully, ask about registry
                if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
                    echo ""
                    log "Image built successfully. You can push it to a remote registry for use on other hosts."
                    prompt_yes_no "Push image to a remote registry?" "n" PUSH_TO_REGISTRY
                    
                    if [[ "${PUSH_TO_REGISTRY:-false}" == "true" ]]; then
                        prompt_with_default "Registry URL (e.g., registry.example.com or quay.io/username)" "" WEBUI_REGISTRY
                        
                        if [[ -n "${WEBUI_REGISTRY:-}" ]]; then
                            # Build and push multi-arch image
                            local local_tag="ztpbootstrap-webui:local"
                            local remote_tag="${WEBUI_REGISTRY}/ztpbootstrap-webui:latest"
                            
                            log "Building and pushing multi-arch image to $remote_tag..."
                            log "This will build for both amd64 (x86_64) and arm64 (aarch64) architectures..."
                            log "Note: Cross-platform builds may take longer and require emulation for non-native architectures."
                            
                            local repo_dir
                            repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                            local containerfile="${repo_dir}/webui/Containerfile"
                            local current_arch=$(uname -m)
                            local amd64_built=false
                            local arm64_built=false
                            local amd64_tag="${remote_tag}-amd64"
                            local arm64_tag="${remote_tag}-arm64"
                            
                            # Check if we can build multi-arch (requires buildah or podman with cross-platform support)
                            if command -v buildah >/dev/null 2>&1; then
                                # Use buildah for multi-arch builds (supports cross-platform via qemu)
                                
                                # Build for amd64 (x86_64) - needed for production servers
                                log "Building for amd64 (x86_64)..."
                                if buildah build --arch amd64 --tag "$amd64_tag" -f "$containerfile" "$repo_dir" 2>&1; then
                                    log "✓ Built amd64 image"
                                    if podman push "$amd64_tag" 2>&1; then
                                        log "✓ Pushed amd64 image to registry"
                                        amd64_built=true
                                    else
                                        warn "Failed to push amd64 image"
                                    fi
                                else
                                    warn "Failed to build amd64 image (may need qemu-user-static for cross-platform builds)"
                                fi
                                
                                # Build for arm64 (aarch64) - needed for ARM-based dev machines
                                log "Building for arm64 (aarch64)..."
                                if buildah build --arch arm64 --tag "$arm64_tag" -f "$containerfile" "$repo_dir" 2>&1; then
                                    log "✓ Built arm64 image"
                                    if podman push "$arm64_tag" 2>&1; then
                                        log "✓ Pushed arm64 image to registry"
                                        arm64_built=true
                                    else
                                        warn "Failed to push arm64 image"
                                    fi
                                else
                                    warn "Failed to build arm64 image"
                                fi
                                
                                # Create and push multi-arch manifest if at least one arch succeeded
                                if [[ "$amd64_built" == "true" ]] || [[ "$arm64_built" == "true" ]]; then
                                    log "Creating multi-arch manifest..."
                                    # Remove existing manifest if it exists (both local and remote)
                                    podman manifest rm "$remote_tag" 2>/dev/null || true
                                    
                                    if podman manifest create "$remote_tag" 2>/dev/null; then
                                        # Add remote registry images to the manifest (not local images)
                                        if [[ "$amd64_built" == "true" ]]; then
                                            if podman manifest add "$remote_tag" "docker://$amd64_tag" 2>&1; then
                                                log "✓ Added amd64 image to manifest"
                                            else
                                                warn "Failed to add amd64 image to manifest"
                                            fi
                                        fi
                                        if [[ "$arm64_built" == "true" ]]; then
                                            if podman manifest add "$remote_tag" "docker://$arm64_tag" 2>&1; then
                                                log "✓ Added arm64 image to manifest"
                                            else
                                                warn "Failed to add arm64 image to manifest"
                                            fi
                                        fi
                                        
                                        if podman manifest push --all "$remote_tag" "docker://$remote_tag" 2>&1; then
                                            log "✓ Successfully created and pushed multi-arch manifest"
                                            WEBUI_IMAGE_REGISTRY="$WEBUI_REGISTRY"
                                            WEBUI_IMAGE_TAG="$remote_tag"
                                        else
                                            warn "Failed to push multi-arch manifest. Will use local image only."
                                            WEBUI_IMAGE_REGISTRY=""
                                            WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                        fi
                                    else
                                        warn "Failed to create manifest. Will use local image only."
                                        WEBUI_IMAGE_REGISTRY=""
                                        WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                    fi
                                else
                                    warn "Failed to build images for any architecture. Will use local image only."
                                    WEBUI_IMAGE_REGISTRY=""
                                    WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                fi
                            else
                                # Fallback: buildah not available - prompt to install or build single-arch
                                warn "buildah not found. Multi-arch builds require buildah."
                                warn "To build multi-arch images, install buildah: sudo dnf install buildah"
                                warn "For cross-platform builds, also install: sudo dnf install qemu-user-static"
                                
                                if [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
                                    prompt_yes_no "Install buildah now to enable multi-arch builds?" "y" INSTALL_BUILDAH
                                    if [[ "${INSTALL_BUILDAH:-false}" == "true" ]]; then
                                        log "Installing buildah..."
                                        if sudo dnf install -y -q buildah 2>&1; then
                                            log "✓ buildah installed. Retrying multi-arch build..."
                                            # Now that buildah is installed, re-check and use it
                                            if command -v buildah >/dev/null 2>&1; then
                                                # Re-execute the multi-arch build logic (jump back to buildah section)
                                                log "Building and pushing multi-arch image to $remote_tag..."
                                                log "This will build for both amd64 (x86_64) and arm64 (aarch64) architectures..."
                                                
                                                local amd64_built=false
                                                local arm64_built=false
                                                local amd64_tag="${remote_tag}-amd64"
                                                local arm64_tag="${remote_tag}-arm64"
                                                
                                                # Build for amd64 (x86_64) - needed for production servers
                                                log "Building for amd64 (x86_64)..."
                                                if buildah build --arch amd64 --tag "$amd64_tag" -f "$containerfile" "$repo_dir" 2>&1; then
                                                    log "✓ Built amd64 image"
                                                    if podman push "$amd64_tag" 2>&1; then
                                                        log "✓ Pushed amd64 image to registry"
                                                        amd64_built=true
                                                    else
                                                        warn "Failed to push amd64 image"
                                                    fi
                                                else
                                                    warn "Failed to build amd64 image (may need qemu-user-static for cross-platform builds)"
                                                fi
                                                
                                                # Build for arm64 (aarch64) - needed for ARM-based dev machines
                                                log "Building for arm64 (aarch64)..."
                                                if buildah build --arch arm64 --tag "$arm64_tag" -f "$containerfile" "$repo_dir" 2>&1; then
                                                    log "✓ Built arm64 image"
                                                    if podman push "$arm64_tag" 2>&1; then
                                                        log "✓ Pushed arm64 image to registry"
                                                        arm64_built=true
                                                    else
                                                        warn "Failed to push arm64 image"
                                                    fi
                                                else
                                                    warn "Failed to build arm64 image"
                                                fi
                                                
                                                # Create and push multi-arch manifest if at least one arch succeeded
                                                if [[ "$amd64_built" == "true" ]] || [[ "$arm64_built" == "true" ]]; then
                                                    log "Creating multi-arch manifest..."
                                                    podman manifest rm "$remote_tag" 2>/dev/null || true
                                                    
                                                    if podman manifest create "$remote_tag" 2>/dev/null; then
                                                        if [[ "$amd64_built" == "true" ]]; then
                                                            if podman manifest add "$remote_tag" "docker://$amd64_tag" 2>&1; then
                                                                log "✓ Added amd64 image to manifest"
                                                            fi
                                                        fi
                                                        if [[ "$arm64_built" == "true" ]]; then
                                                            if podman manifest add "$remote_tag" "docker://$arm64_tag" 2>&1; then
                                                                log "✓ Added arm64 image to manifest"
                                                            fi
                                                        fi
                                                        
                                                        if podman manifest push --all "$remote_tag" "docker://$remote_tag" 2>&1; then
                                                            log "✓ Successfully created and pushed multi-arch manifest"
                                                            WEBUI_IMAGE_REGISTRY="$WEBUI_REGISTRY"
                                                            WEBUI_IMAGE_TAG="$remote_tag"
                                                        else
                                                            warn "Failed to push multi-arch manifest. Will use local image only."
                                                            WEBUI_IMAGE_REGISTRY=""
                                                            WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                                        fi
                                                    else
                                                        warn "Failed to create manifest. Will use local image only."
                                                        WEBUI_IMAGE_REGISTRY=""
                                                        WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                                    fi
                                                else
                                                    warn "Failed to build images for any architecture. Will use local image only."
                                                    WEBUI_IMAGE_REGISTRY=""
                                                    WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                                fi
                                                
                                                # Skip single-arch build since we just did multi-arch
                                                continue
                                            else
                                                warn "buildah installed but not found in PATH. Continuing with single-arch build."
                                            fi
                                        else
                                            warn "Failed to install buildah. Continuing with single-arch build."
                                        fi
                                    fi
                                fi
                                
                                # Build and push single-arch (current architecture)
                                log "Building single-arch image for current platform only..."
                                if [[ "$current_arch" == "aarch64" ]] || [[ "$current_arch" == "arm64" ]]; then
                                    current_arch="arm64"
                                    warn "Building arm64 only. Production x86_64 servers will need amd64 image."
                                else
                                    current_arch="amd64"
                                    warn "Building amd64 only. ARM64 dev machines will need arm64 image."
                                fi
                                
                                if podman tag "$local_tag" "$remote_tag" 2>/dev/null; then
                                    log "Pushing $current_arch image to $remote_tag..."
                                    if podman push "$remote_tag" 2>&1; then
                                        log "✓ Successfully pushed $current_arch image to $remote_tag"
                                        warn "Note: This is a single-arch image. To create multi-arch:"
                                        warn "  1. Install buildah: sudo dnf install buildah qemu-user-static"
                                        warn "  2. Re-run setup and choose to push to registry again"
                                        WEBUI_IMAGE_REGISTRY="$WEBUI_REGISTRY"
                                        WEBUI_IMAGE_TAG="$remote_tag"
                                    else
                                        warn "Failed to push image to registry. Will use local image only."
                                        WEBUI_IMAGE_REGISTRY=""
                                        WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                    fi
                                else
                                    warn "Failed to tag image. Will use local image only."
                                    WEBUI_IMAGE_REGISTRY=""
                                    WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                                fi
                            fi
                        else
                            log "No registry provided. Will use local image only."
                            WEBUI_IMAGE_REGISTRY=""
                            WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                        fi
                    else
                        WEBUI_IMAGE_REGISTRY=""
                        WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                    fi
                else
                    # Non-interactive: use local image
                    WEBUI_IMAGE_REGISTRY=""
                    WEBUI_IMAGE_TAG="ztpbootstrap-webui:local"
                fi
            else
                # Build failed, use base image
                WEBUI_IMAGE_REGISTRY=""
                WEBUI_IMAGE_TAG=""
            fi
        else
            WEBUI_IMAGE_REGISTRY=""
            WEBUI_IMAGE_TAG=""
        fi
        
        echo ""
    fi
    
    # Section 8: Service Configuration (only shown in extended mode)
    if [[ "${EXTENDED_MODE:-false}" == "true" ]]; then
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
    else
        # Use defaults when not in extended mode
        HEALTH_INTERVAL="${HEALTH_INTERVAL:-30s}"
        HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10s}"
        HEALTH_RETRIES="${HEALTH_RETRIES:-3}"
        HEALTH_START_PERIOD="${HEALTH_START_PERIOD:-60s}"
        RESTART_POLICY="${RESTART_POLICY:-on-failure}"
    fi
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
    
    # Systemd pod directory (may need sudo)
    local pod_dir="/etc/containers/systemd/ztpbootstrap"
    if [[ "$pod_dir" == /etc/* ]] && [[ $EUID -ne 0 ]]; then
        need_sudo=true
    fi
    dirs_to_create+=("$pod_dir")
    
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
    
    # Validate that required variables are set
    local missing_vars=()
    [[ -z "${SCRIPT_DIR:-}" ]] && missing_vars+=("SCRIPT_DIR")
    [[ -z "${CERT_DIR:-}" ]] && missing_vars+=("CERT_DIR")
    [[ -z "${DOMAIN:-}" ]] && missing_vars+=("DOMAIN")
    [[ -z "${CV_ADDR:-}" ]] && missing_vars+=("CV_ADDR")
    [[ -z "${ENROLLMENT_TOKEN:-}" ]] && missing_vars+=("ENROLLMENT_TOKEN")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        error "Cannot generate config.yaml: Missing required variables: ${missing_vars[*]}"
        error "This indicates a bug in the interactive setup. Please report this issue."
        return 1
    fi
    
    # Ensure optional variables have defaults
    ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/ztpbootstrap.env}"
    BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-${SCRIPT_DIR}/bootstrap.py}"
    NGINX_CONF="${NGINX_CONF:-${SCRIPT_DIR}/nginx.conf}"
    HTTPS_PORT="${HTTPS_PORT:-443}"
    HTTP_PORT="${HTTP_PORT:-80}"
    HTTP_ONLY="${HTTP_ONLY:-false}"
    HOST_NETWORK="${HOST_NETWORK:-false}"
    CONTAINER_NAME="${CONTAINER_NAME:-ztpbootstrap}"
    CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/nginx:alpine}"
    TIMEZONE="${TIMEZONE:-UTC}"
    DNS1="${DNS1:-}"
    DNS2="${DNS2:-}"
    CV_PROXY="${CV_PROXY:-}"
    EOS_URL="${EOS_URL:-}"
    NTP_SERVER="${NTP_SERVER:-pool.ntp.org}"
    CERT_FILE="${CERT_FILE:-fullchain.pem}"
    KEY_FILE="${KEY_FILE:-privkey.pem}"
    USE_LETSENCRYPT="${USE_LETSENCRYPT:-false}"
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
    CREATE_SELF_SIGNED="${CREATE_SELF_SIGNED:-false}"
    HEALTH_INTERVAL="${HEALTH_INTERVAL:-30s}"
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10s}"
    HEALTH_RETRIES="${HEALTH_RETRIES:-3}"
    HEALTH_START_PERIOD="${HEALTH_START_PERIOD:-60s}"
    RESTART_POLICY="${RESTART_POLICY:-on-failure}"
    ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}"
    SESSION_TIMEOUT="${SESSION_TIMEOUT:-3600}"
    SESSION_SECRET="${SESSION_SECRET:-}"
    
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
  nginx_conf: "$NGINX_CONF"

# ============================================================================
# Network Configuration
# ============================================================================
network:
  domain: "$DOMAIN"
  ipv4: "${IPV4:-}"
  ipv6: "${IPV6:-}"
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

# ============================================================================
# Authentication Configuration
# ============================================================================
auth:
  # Admin password hash (never store plain text passwords)
  # Set during setup or via ZTP_ADMIN_PASSWORD environment variable
  admin_password_hash: "${ADMIN_PASSWORD_HASH:-}"
  
  # Session timeout in seconds (default: 3600 = 1 hour)
  session_timeout: ${SESSION_TIMEOUT:-3600}
  
  # Session secret key for signing session tokens
  # Auto-generated during setup
  session_secret: "${SESSION_SECRET:-}"

# ============================================================================
# WebUI Container Image Configuration
# ============================================================================
webui:
  # Registry image (if pushed to remote registry)
  # Format: registry.example.com/ztpbootstrap-webui:latest
  registry_image: "${WEBUI_IMAGE_TAG:-}"
  
  # Registry URL (without image name/tag)
  # Format: registry.example.com or quay.io/username
  registry: "${WEBUI_IMAGE_REGISTRY:-}"
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
        
        # Create self-signed certificate if requested and certificates don't exist
        if [[ "${CREATE_SELF_SIGNED:-false}" == "true" ]]; then
            local cert_dir_for_check="${CERT_DIR:-/opt/containerdata/certs/wild}"
            local cert_path="${cert_dir_for_check}/${CERT_FILE:-fullchain.pem}"
            local key_path="${cert_dir_for_check}/${KEY_FILE:-privkey.pem}"
            
            if [[ ! -f "$cert_path" ]] || [[ ! -f "$key_path" ]]; then
                create_self_signed_cert "${CERT_DIR:-/opt/containerdata/certs/wild}" "${DOMAIN:-ztpboot.example.com}"
            else
                log "SSL certificates already exist, skipping self-signed certificate creation"
            fi
        fi
        
        # Copy source files to target directory
        copy_source_files
        
        # Copy config.yaml to installation directory (copy_source_files handles this, but ensure it's done)
        if [[ -f "$CONFIG_FILE" ]] && [[ -n "${SCRIPT_DIR:-}" ]]; then
            if [[ ("$SCRIPT_DIR" =~ ^/etc/ || "$SCRIPT_DIR" =~ ^/opt/) && $EUID -ne 0 ]]; then
                if sudo cp "$CONFIG_FILE" "${SCRIPT_DIR}/config.yaml" 2>/dev/null; then
                    sudo chown root:root "${SCRIPT_DIR}/config.yaml" 2>/dev/null || true
                    sudo chmod 644 "${SCRIPT_DIR}/config.yaml" 2>/dev/null || true
                    log "Copied config.yaml to installation directory: ${SCRIPT_DIR}/config.yaml"
                fi
            else
                if cp "$CONFIG_FILE" "${SCRIPT_DIR}/config.yaml" 2>/dev/null; then
                    chmod 644 "${SCRIPT_DIR}/config.yaml" 2>/dev/null || true
                    log "Copied config.yaml to installation directory: ${SCRIPT_DIR}/config.yaml"
                elif sudo cp "$CONFIG_FILE" "${SCRIPT_DIR}/config.yaml" 2>/dev/null; then
                    sudo chown root:root "${SCRIPT_DIR}/config.yaml" 2>/dev/null || true
                    sudo chmod 644 "${SCRIPT_DIR}/config.yaml" 2>/dev/null || true
                    log "Copied config.yaml with sudo to installation directory: ${SCRIPT_DIR}/config.yaml"
                fi
            fi
        fi
        
        # Verify config file exists and is readable
        if [[ ! -f "$CONFIG_FILE" ]]; then
            error "Config file not found: $CONFIG_FILE"
            error "Cannot proceed with update-config.sh"
            return 1
        fi
        
        # Verify config file has content (at least 100 bytes to ensure it's not empty)
        if [[ ! -s "$CONFIG_FILE" ]] || [[ $(stat -f%z "$CONFIG_FILE" 2>/dev/null || stat -c%s "$CONFIG_FILE" 2>/dev/null || echo 0) -lt 100 ]]; then
            error "Config file appears to be empty or too small: $CONFIG_FILE"
            error "This indicates the YAML generation failed. Please check the file contents."
            return 1
        fi
        
        if [[ -f "update-config.sh" ]]; then
            log "Running update-config.sh to apply configuration..."
            log "Using config file: $CONFIG_FILE"
            QUIET=true bash update-config.sh "$CONFIG_FILE"
        else
            warn "update-config.sh not found. Please run it manually:"
            warn "  bash update-config.sh $CONFIG_FILE"
        fi
        
        # After updating config, we need to create the pod/container systemd files
        # This is done by setup.sh's setup_pod() function, which copies files from systemd/ directory
        # We'll call setup.sh which will handle this, but we need to make sure it doesn't fail
        # on prerequisites that are already satisfied
        if [[ -f "setup.sh" ]]; then
            log "Creating pod and container systemd files..."
            # We need to run setup.sh, but it does a lot of checks
            # The simplest approach is to source it and call setup_pod directly
            # But that's complex due to dependencies. Instead, let's just run setup.sh
            # which should be mostly idempotent. However, setup.sh requires root and
            # does full setup. Let's create a simpler function that just does the pod setup.
            
            # Note: WebUI image build happens in Section 7 (interactive_config) if requested
            
            create_pod_files_from_config
            
            # Manually run quadlet generator for pod and container files to ensure services are created
            # This is needed because systemd's automatic generator may not always process all files
            local systemd_dir="/etc/containers/systemd/ztpbootstrap"
            local generator_dir="/run/systemd/generator"
            local systemd_system_dir="/etc/systemd/system"
            
            # Ensure generator directory exists
            if [[ $EUID -eq 0 ]]; then
                mkdir -p "$generator_dir" 2>/dev/null || true
                mkdir -p "$systemd_system_dir" 2>/dev/null || true
            else
                sudo mkdir -p "$generator_dir" 2>/dev/null || true
                sudo mkdir -p "$systemd_system_dir" 2>/dev/null || true
            fi
            
            # Reload systemd first to trigger the quadlet generator
            log "Reloading systemd to trigger quadlet generator..."
            if [[ $EUID -eq 0 ]]; then
                systemctl daemon-reload
            else
                sudo systemctl daemon-reload
            fi
            sleep 3  # Give systemd time to generate service files via automatic generator
            
            # Check both generator directory and systemd system directory
            # Generator files are temporary, systemd system files are permanent
            local pod_service_path=""
            if [[ -f "${generator_dir}/ztpbootstrap-pod.service" ]]; then
                pod_service_path="${generator_dir}/ztpbootstrap-pod.service"
            elif [[ -f "${systemd_system_dir}/ztpbootstrap-pod.service" ]]; then
                pod_service_path="${systemd_system_dir}/ztpbootstrap-pod.service"
            fi
            
            # Verify services were generated, if not try manual quadlet execution
            local services_generated=true
            if [[ -z "$pod_service_path" ]]; then
                warn "Pod service not auto-generated, trying manual quadlet execution..."
                services_generated=false
                
                if command -v /usr/libexec/podman/quadlet >/dev/null 2>&1; then
                    # Generate pod service manually
                    local pod_file="${systemd_dir}/ztpbootstrap.pod"
                    if [[ -f "$pod_file" ]]; then
                        log "Manually generating pod service file..."
                        local pod_output
                        local pod_exit_code=0
                        if [[ $EUID -eq 0 ]]; then
                            pod_output=$(/usr/libexec/podman/quadlet "$pod_file" 2>&1) || pod_exit_code=$?
                        else
                            pod_output=$(sudo /usr/libexec/podman/quadlet "$pod_file" 2>&1) || pod_exit_code=$?
                        fi
                        # Check both locations after quadlet execution
                        local pod_generated=false
                        if [[ -f "${generator_dir}/ztpbootstrap-pod.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-pod.service" ]]; then
                            pod_generated=true
                        fi
                        
                        if [[ $pod_exit_code -eq 0 ]] && [[ "$pod_generated" == "true" ]]; then
                            log "Pod service file generated successfully"
                            services_generated=true
                        else
                            if [[ -n "$pod_output" ]]; then
                                warn "Quadlet generator output for pod: ${pod_output:0:200}"
                            fi
                            warn "Failed to generate pod service file, creating manually..."
                            # Manually create pod service file as fallback
                            # Create in /etc/systemd/system/ for permanence (not /run/systemd/generator which is tmpfs)
                            local pod_name="ztpbootstrap"
                            if grep -q "^PodName=" "$pod_file" 2>/dev/null; then
                                pod_name=$(grep "^PodName=" "$pod_file" | cut -d'=' -f2 | tr -d ' ')
                            fi
                            local network_mode="bridge"
                            if grep -q "^Network=host" "$pod_file" 2>/dev/null; then
                                network_mode="host"
                            fi
                            if [[ $EUID -eq 0 ]]; then
                                cat > "${systemd_system_dir}/ztpbootstrap-pod.service" << EOFPOD
[Unit]
Description=ZTP Bootstrap Service Pod
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
RequiresMountsFor=%t/containers

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman pod stop -t 10 ${pod_name}
ExecStopPost=/usr/bin/podman pod rm -t 10 -f ${pod_name}
Delegate=yes
Type=forking
SyslogIdentifier=%N
ExecStart=/usr/bin/podman pod start ${pod_name}
ExecStartPre=-/usr/bin/podman pod stop ${pod_name}
ExecStartPre=-/usr/bin/podman pod rm -f ${pod_name}
ExecStartPre=/usr/bin/podman pod create --infra --name ${pod_name} --network ${network_mode}
EOFPOD
                            else
                                # Create file using sudo - write to temp file first, then move
                                local temp_file
                                temp_file=$(mktemp)
                                cat > "$temp_file" << EOFPOD
[Unit]
Description=ZTP Bootstrap Service Pod
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
RequiresMountsFor=%t/containers

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman pod stop -t 10 ${pod_name}
ExecStopPost=/usr/bin/podman pod rm -t 10 -f ${pod_name}
Delegate=yes
Type=forking
SyslogIdentifier=%N
ExecStart=/usr/bin/podman pod start ${pod_name}
ExecStartPre=-/usr/bin/podman pod stop ${pod_name}
ExecStartPre=-/usr/bin/podman pod rm -f ${pod_name}
ExecStartPre=/usr/bin/podman pod create --infra --name ${pod_name} --network ${network_mode}
EOFPOD
                                # Create in /etc/systemd/system/ for permanence
                                if sudo mv "$temp_file" "${systemd_system_dir}/ztpbootstrap-pod.service" 2>&1; then
                                    log "Pod service file created manually at ${systemd_system_dir}/ztpbootstrap-pod.service"
                                    # Verify immediately
                                    if sudo test -f "${systemd_system_dir}/ztpbootstrap-pod.service" 2>/dev/null; then
                                        log "✓ File verified immediately after creation"
                                        services_generated=true
                                    else
                                        warn "File was moved but not found at destination"
                                    fi
                                else
                                    warn "Failed to move temp file to systemd directory (temp file: $temp_file)"
                                    rm -f "$temp_file"
                                    # Try alternative method: use sudo tee
                                    if sudo tee "${systemd_system_dir}/ztpbootstrap-pod.service" > /dev/null << EOFPOD2
[Unit]
Description=ZTP Bootstrap Service Pod
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
RequiresMountsFor=%t/containers

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman pod stop -t 10 ${pod_name}
ExecStopPost=/usr/bin/podman pod rm -t 10 -f ${pod_name}
Delegate=yes
Type=forking
SyslogIdentifier=%N
ExecStart=/usr/bin/podman pod start ${pod_name}
ExecStartPre=-/usr/bin/podman pod stop ${pod_name}
ExecStartPre=-/usr/bin/podman pod rm -f ${pod_name}
ExecStartPre=/usr/bin/podman pod create --infra --name ${pod_name} --network ${network_mode}
EOFPOD2
                                    then
                                        log "Pod service file created using sudo tee"
                                        services_generated=true
                                    fi
                                fi
                            fi
                            
                            # Verify file exists (check both locations) - outside if/else block
                            local pod_verified=false
                            if [[ -f "${generator_dir}/ztpbootstrap-pod.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-pod.service" ]]; then
                                pod_verified=true
                            elif [[ $EUID -ne 0 ]]; then
                                if sudo test -f "${generator_dir}/ztpbootstrap-pod.service" 2>/dev/null || sudo test -f "${systemd_system_dir}/ztpbootstrap-pod.service" 2>/dev/null; then
                                    pod_verified=true
                                fi
                            fi
                            
                            if [[ "$pod_verified" == "true" ]]; then
                                log "✓ Pod service file verified"
                                services_generated=true
                            else
                                warn "Failed to verify pod service file was created (checked ${generator_dir} and ${systemd_system_dir})"
                            fi
                        fi
                    fi
                    
                    # Generate nginx container service manually
                    local nginx_container_file="${systemd_dir}/ztpbootstrap-nginx.container"
                    if [[ -f "$nginx_container_file" ]]; then
                        log "Manually generating nginx container service file..."
                        local nginx_output
                        local nginx_exit_code=0
                        if [[ $EUID -eq 0 ]]; then
                            nginx_output=$(/usr/libexec/podman/quadlet "$nginx_container_file" 2>&1) || nginx_exit_code=$?
                        else
                            nginx_output=$(sudo /usr/libexec/podman/quadlet "$nginx_container_file" 2>&1) || nginx_exit_code=$?
                        fi
                        # Check both locations after quadlet execution
                        local nginx_generated=false
                        if [[ -f "${generator_dir}/ztpbootstrap-nginx.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-nginx.service" ]]; then
                            nginx_generated=true
                        fi
                        
                        if [[ $nginx_exit_code -eq 0 ]] && [[ "$nginx_generated" == "true" ]]; then
                            log "Nginx container service file generated successfully"
                        else
                            if [[ -n "$nginx_output" ]]; then
                                warn "Quadlet generator output for nginx: ${nginx_output:0:200}"
                            fi
                            warn "Failed to generate nginx service file, creating manually..."
                            # Manually create nginx service file as fallback
                            local pod_name="ztpbootstrap"
                            if [[ -f "${systemd_dir}/ztpbootstrap.pod" ]] && grep -q "^PodName=" "${systemd_dir}/ztpbootstrap.pod" 2>/dev/null; then
                                pod_name=$(grep "^PodName=" "${systemd_dir}/ztpbootstrap.pod" | cut -d'=' -f2 | tr -d ' ')
                            fi
                            # The pod service name is always ztpbootstrap-pod.service (not ${pod_name}.service)
                            local pod_service_name="ztpbootstrap-pod.service"
                            # Extract volumes and environment from container file
                            # Filter out Fedora-specific systemd library paths on non-Fedora systems
                            local volumes=""
                            local env_vars=""
                            local distro=""
                            # Detect distribution
                            if [[ -f /etc/os-release ]]; then
                                distro=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
                            fi
                            
                            if [[ -f "$nginx_container_file" ]]; then
                                while IFS= read -r line; do
                                    if [[ "$line" =~ ^Volume= ]]; then
                                        local volume_path="${line#Volume=}"
                                        local source_path="${volume_path%%:*}"
                                        
                                        # Skip Fedora-specific systemd library paths on non-RHEL-based systems
                                        # RHEL-based distros (Fedora, RHEL, CentOS, CentOS Stream, Rocky, AlmaLinux) have these paths
                                        if [[ "$distro" != "fedora" ]] && [[ "$distro" != "rhel" ]] && [[ "$distro" != "centos" ]] && [[ "$distro" != "centos-stream" ]] && [[ "$distro" != "almalinux" ]] && [[ "$distro" != "rocky" ]]; then
                                            if [[ "$source_path" =~ ^/lib64/libsystemd ]] || [[ "$source_path" == "/usr/lib64/systemd" ]]; then
                                                continue
                                            fi
                                        fi
                                        
                                        # Only include volume if source path exists (or is a special path like /run)
                                        if [[ "$source_path" =~ ^/run ]] || [[ "$source_path" =~ ^/opt ]] || [[ -e "$source_path" ]] || ([[ $EUID -ne 0 ]] && sudo test -e "$source_path" 2>/dev/null); then
                                            volumes="${volumes} -v ${volume_path}"
                                        else
                                            warn "Skipping volume mount for non-existent path: $source_path"
                                        fi
                                    elif [[ "$line" =~ ^Environment= ]]; then
                                        env_vars="${env_vars} --env ${line#Environment=}"
                                    fi
                                done < "$nginx_container_file"
                            fi
                            # Create in /etc/systemd/system/ for permanence
                            if [[ $EUID -eq 0 ]]; then
                                cat > "${systemd_system_dir}/ztpbootstrap-nginx.service" << EOFNGINX
[Unit]
Description=ZTP Bootstrap Nginx Container
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap-nginx.container
RequiresMountsFor=%t/containers
BindsTo=${pod_service_name}
After=${pod_service_name}

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman rm -v -f -i ztpbootstrap-nginx
ExecStopPost=-/usr/bin/podman rm -v -f -i ztpbootstrap-nginx
Delegate=yes
Type=notify
NotifyAccess=all
SyslogIdentifier=%N
ExecStart=/usr/bin/podman run --name ztpbootstrap-nginx --replace --rm --cgroups=split --sdnotify=conmon -d --pod ${pod_name}${volumes}${env_vars} docker.io/nginx:alpine
EOFNGINX
                            else
                                # Create file using sudo - write to temp file first, then move
                                local temp_file
                                temp_file=$(mktemp)
                                cat > "$temp_file" << EOFNGINX
[Unit]
Description=ZTP Bootstrap Nginx Container
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap-nginx.container
RequiresMountsFor=%t/containers
BindsTo=${pod_service_name}
After=${pod_service_name}

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman rm -v -f -i ztpbootstrap-nginx
ExecStopPost=-/usr/bin/podman rm -v -f -i ztpbootstrap-nginx
Delegate=yes
Type=notify
NotifyAccess=all
SyslogIdentifier=%N
ExecStart=/usr/bin/podman run --name ztpbootstrap-nginx --replace --rm --cgroups=split --sdnotify=conmon -d --pod ${pod_name}${volumes}${env_vars} docker.io/nginx:alpine
EOFNGINX
                                # Create in /etc/systemd/system/ for permanence
                                if sudo mv "$temp_file" "${systemd_system_dir}/ztpbootstrap-nginx.service" 2>&1; then
                                    log "Nginx service file created manually at ${systemd_system_dir}/ztpbootstrap-nginx.service"
                                    # Verify immediately
                                    if sudo test -f "${systemd_system_dir}/ztpbootstrap-nginx.service" 2>/dev/null; then
                                        log "✓ Nginx file verified immediately after creation"
                                    else
                                        warn "Nginx file was moved but not found at destination"
                                    fi
                                else
                                    warn "Failed to move temp file (temp: $temp_file, dest: ${systemd_system_dir}/ztpbootstrap-nginx.service), trying sudo tee method..."
                                    rm -f "$temp_file"
                                    # Extract volumes and env again for tee method (with same filtering)
                                    local volumes_tee=""
                                    local env_vars_tee=""
                                    local distro_tee=""
                                    # Detect distribution
                                    if [[ -f /etc/os-release ]]; then
                                        distro_tee=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
                                    fi
                                    
                                    if [[ -f "$nginx_container_file" ]]; then
                                        while IFS= read -r line; do
                                            if [[ "$line" =~ ^Volume= ]]; then
                                                local volume_path_tee="${line#Volume=}"
                                                local source_path_tee="${volume_path_tee%%:*}"
                                                
                                                # Skip Fedora-specific systemd library paths on non-RHEL-based systems
                                                # RHEL-based distros (Fedora, RHEL, CentOS, Rocky, AlmaLinux) have these paths
                                                local is_dnf_distro_tee=false
                                                if [[ "$distro_tee" == "fedora" ]] || [[ "$distro_tee" == "rhel" ]] || [[ "$distro_tee" == "centos" ]] || [[ "$distro_tee" == "centos-stream" ]] || [[ "$distro_tee" == "almalinux" ]] || [[ "$distro_tee" == "rocky" ]]; then
                                                    is_dnf_distro_tee=true
                                                fi
                                                if [[ "$is_dnf_distro_tee" == "false" ]]; then
                                                    if [[ "$source_path_tee" =~ ^/lib64/libsystemd ]] || [[ "$source_path_tee" == "/usr/lib64/systemd" ]]; then
                                                        continue
                                                    fi
                                                fi
                                                
                                                # Only include if path exists
                                                if [[ "$source_path_tee" =~ ^/run ]] || [[ "$source_path_tee" =~ ^/opt ]] || [[ -e "$source_path_tee" ]] || ([[ $EUID -ne 0 ]] && sudo test -e "$source_path_tee" 2>/dev/null); then
                                                    volumes_tee="${volumes_tee} -v ${volume_path_tee}"
                                                fi
                                            elif [[ "$line" =~ ^Environment= ]]; then
                                                env_vars_tee="${env_vars_tee} --env ${line#Environment=}"
                                            fi
                                        done < "$nginx_container_file"
                                    fi
                                    if sudo tee "${systemd_system_dir}/ztpbootstrap-nginx.service" > /dev/null << EOFNGINX2
[Unit]
Description=ZTP Bootstrap Nginx Container
SourcePath=/etc/containers/systemd/ztpbootstrap/ztpbootstrap-nginx.container
RequiresMountsFor=%t/containers
BindsTo=${pod_service_name}
After=${pod_service_name}

[Service]
Restart=always
Environment=PODMAN_SYSTEMD_UNIT=%n
KillMode=mixed
ExecStop=/usr/bin/podman rm -v -f -i ztpbootstrap-nginx
ExecStopPost=-/usr/bin/podman rm -v -f -i ztpbootstrap-nginx
Delegate=yes
Type=notify
NotifyAccess=all
SyslogIdentifier=%N
ExecStart=/usr/bin/podman run --name ztpbootstrap-nginx --replace --rm --cgroups=split --sdnotify=conmon -d --pod ${pod_name}${volumes_tee}${env_vars_tee} docker.io/nginx:alpine
EOFNGINX2
                                    then
                                        log "Nginx service file created using sudo tee"
                                    fi
                                fi
                            fi
                            
                            # Verify file exists (check both locations) - outside if/else block
                            local nginx_verified=false
                            if [[ -f "${generator_dir}/ztpbootstrap-nginx.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-nginx.service" ]]; then
                                nginx_verified=true
                            elif [[ $EUID -ne 0 ]]; then
                                if sudo test -f "${generator_dir}/ztpbootstrap-nginx.service" 2>/dev/null || sudo test -f "${systemd_system_dir}/ztpbootstrap-nginx.service" 2>/dev/null; then
                                    nginx_verified=true
                                fi
                            fi
                            
                            if [[ "$nginx_verified" == "true" ]]; then
                                log "✓ Nginx service file verified"
                            else
                                warn "Failed to verify nginx service file (checked ${generator_dir} and ${systemd_system_dir})"
                            fi
                        fi
                    fi
                    
                    # Reload systemd again after manual generation
                    if [[ "$services_generated" == "true" ]]; then
                        log "Reloading systemd after manual service generation..."
                        if [[ $EUID -eq 0 ]]; then
                            systemctl daemon-reload
                        else
                            sudo systemctl daemon-reload
                        fi
                        sleep 2
                    fi
                else
                    warn "quadlet command not found, cannot generate service files manually"
                fi
            else
                log "✓ Pod service auto-generated by systemd"
            fi
            
            # Final verification that services exist (check both locations)
            local pod_service_exists=false
            if [[ -f "${generator_dir}/ztpbootstrap-pod.service" ]] || [[ -f "${systemd_system_dir}/ztpbootstrap-pod.service" ]]; then
                pod_service_exists=true
            elif [[ $EUID -ne 0 ]]; then
                if sudo test -f "${generator_dir}/ztpbootstrap-pod.service" 2>/dev/null || sudo test -f "${systemd_system_dir}/ztpbootstrap-pod.service" 2>/dev/null; then
                    pod_service_exists=true
                fi
            fi
            
            if [[ "$pod_service_exists" == "false" ]]; then
                warn "⚠️  Warning: Pod service file still not found after generation attempts"
                warn "   Checking if files exist in generator and systemd directories..."
                if [[ $EUID -eq 0 ]]; then
                    ls -la "${generator_dir}/" 2>/dev/null | grep ztpbootstrap || warn "   No ztpbootstrap files in ${generator_dir}"
                    ls -la "${systemd_system_dir}/" 2>/dev/null | grep ztpbootstrap || warn "   No ztpbootstrap files in ${systemd_system_dir}"
                else
                    sudo ls -la "${generator_dir}/" 2>/dev/null | grep ztpbootstrap || warn "   No ztpbootstrap files in ${generator_dir}"
                    sudo ls -la "${systemd_system_dir}/" 2>/dev/null | grep ztpbootstrap || warn "   No ztpbootstrap files in ${systemd_system_dir}"
                fi
                warn "   Services may not start. You may need to run: sudo systemctl daemon-reload"
            else
                log "✓ Pod service file verified"
            fi
        else
            warn "setup.sh not found. Pod files will not be created automatically."
            warn "You will need to run: sudo ./setup.sh"
        fi
        
        # Create logs directory (required for nginx container)
        if [[ -n "${SCRIPT_DIR:-}" ]]; then
            log "Creating logs directory..."
            local logs_dir="${SCRIPT_DIR}/logs"
            if [[ $EUID -eq 0 ]]; then
                mkdir -p "$logs_dir" 2>/dev/null || true
                chmod 777 "$logs_dir" 2>/dev/null || true
                # Try to set ownership to nginx user (UID 101) if possible
                chown 101:101 "$logs_dir" 2>/dev/null || chmod 777 "$logs_dir" 2>/dev/null || true
                # Set SELinux context if not on NFS
                if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
                    if ! is_nfs_mount "$logs_dir"; then
                        chcon -R -t container_file_t "$logs_dir" 2>/dev/null || true
                        log "Set SELinux context for logs directory (not NFS)"
                    fi
                fi
            else
                sudo mkdir -p "$logs_dir" 2>/dev/null || true
                sudo chmod 777 "$logs_dir" 2>/dev/null || true
                sudo chown 101:101 "$logs_dir" 2>/dev/null || sudo chmod 777 "$logs_dir" 2>/dev/null || true
                # Set SELinux context if not on NFS
                if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
                    if ! is_nfs_mount "$logs_dir"; then
                        sudo chcon -R -t container_file_t "$logs_dir" 2>/dev/null || true
                        log "Set SELinux context for logs directory (not NFS)"
                    fi
                fi
            fi
            log "Created logs directory: $logs_dir"
        fi
        
        # Ensure script directory is writable by webui container (runs as root)
        # This allows the webui to upload bootstrap scripts
        if [[ -n "${SCRIPT_DIR:-}" ]] && [[ -d "$SCRIPT_DIR" ]]; then
            log "Setting permissions for webui script uploads..."
            # Check if on NFS first
            if ! is_nfs_mount "$SCRIPT_DIR"; then
                # Change ownership to root so webui (running as root) can write
                if [[ ("$SCRIPT_DIR" =~ ^/etc/ || "$SCRIPT_DIR" =~ ^/opt/) && $EUID -ne 0 ]]; then
                    sudo chown root:root "$SCRIPT_DIR" 2>/dev/null || true
                    sudo chmod 775 "$SCRIPT_DIR" 2>/dev/null || true
                    sudo chown root:root "$SCRIPT_DIR"/*.py 2>/dev/null || true
                    sudo chmod 664 "$SCRIPT_DIR"/*.py 2>/dev/null || true
                    # Set SELinux context to container_file_t so containers can write
                    if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
                        sudo chcon -R -t container_file_t "$SCRIPT_DIR" 2>/dev/null || true
                        log "Set SELinux context to container_file_t for webui uploads"
                    fi
                else
                    chown root:root "$SCRIPT_DIR" 2>/dev/null || true
                    chmod 775 "$SCRIPT_DIR" 2>/dev/null || true
                    chown root:root "$SCRIPT_DIR"/*.py 2>/dev/null || true
                    chmod 664 "$SCRIPT_DIR"/*.py 2>/dev/null || true
                    # Set SELinux context to container_file_t so containers can write
                    if command -v chcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
                        chcon -R -t container_file_t "$SCRIPT_DIR" 2>/dev/null || true
                        log "Set SELinux context to container_file_t for webui uploads"
                    fi
                fi
                log "Set ownership and permissions on script directory for webui uploads (not NFS)"
            else
                # For NFS, ownership changes may not work, so use 777
                if [[ ("$SCRIPT_DIR" =~ ^/etc/ || "$SCRIPT_DIR" =~ ^/opt/) && $EUID -ne 0 ]]; then
                    sudo chmod 777 "$SCRIPT_DIR" 2>/dev/null || true
                    sudo chmod 666 "$SCRIPT_DIR"/*.py 2>/dev/null || true
                else
                    chmod 777 "$SCRIPT_DIR" 2>/dev/null || true
                    chmod 666 "$SCRIPT_DIR"/*.py 2>/dev/null || true
                fi
                log "Set permissions on script directory for webui uploads (NFS - using 777, SELinux context not applicable)"
            fi
        fi
    else
        log "Configuration saved. To apply later, run:"
        log "  bash update-config.sh $CONFIG_FILE"
        log ""
        log "Note: Directories will be created automatically when you apply the config."
    fi
}

# Check and install dependencies
check_and_install_dependencies() {
    local missing_deps=()
    local auto_installable=()
    local manual_install=()
    local distro=""
    
    # Detect distribution
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        distro="${ID:-}"
    fi
    
    # Helper: Check if distro uses dnf (RHEL-based)
    is_dnf_distro() {
        [[ "$distro" == "fedora" ]] || \
        [[ "$distro" == "rhel" ]] || \
        [[ "$distro" == "centos" ]] || \
        [[ "$distro" == "centos-stream" ]] || \
        [[ "$distro" == "almalinux" ]] || \
        [[ "$distro" == "rocky" ]]
    }
    
    # Helper: Check if distro uses apt (Debian-based)
    is_apt_distro() {
        [[ "$distro" == "ubuntu" ]] || \
        [[ "$distro" == "debian" ]]
    }
    
    # Helper: Check if distro uses zypper (SUSE-based)
    is_zypper_distro() {
        [[ "$distro" == "opensuse-leap" ]] || \
        [[ "$distro" == "opensuse" ]] || \
        [[ "$distro" == "sles" ]] || \
        [[ "$distro" == "opensuse-tumbleweed" ]]
    }
    
    log "Checking dependencies..."
    
    # Check for yq (required for YAML parsing)
    local yq_path
    yq_path=$(command -v yq 2>/dev/null || echo "")
    local yq_ok=false
    
    if [[ -n "$yq_path" ]]; then
        # Check if it's the correct yq (mikefarah/yq) or Python wrapper
        local yq_version_output
        yq_version_output=$(yq --version 2>&1 || echo "")
        
        if echo "$yq_version_output" | grep -q "yq version\|v[0-9]"; then
            # Correct yq found
            yq_ok=true
            log "✓ yq found: $yq_path ($yq_version_output)"
        elif echo "$yq_version_output" | grep -q "0.0.0\|usage:"; then
            # Python wrapper detected - try to install correct version
            warn "Python yq wrapper detected at $yq_path, installing correct version..."
            if install_correct_yq; then
                yq_ok=true
                log "✓ Installed correct yq (mikefarah/yq)"
            else
                missing_deps+=("yq")
                manual_install+=("yq")
            fi
        fi
    fi
    
    if [[ "$yq_ok" == "false" ]]; then
        # Try to install yq
        if install_correct_yq; then
            yq_ok=true
            log "✓ Installed yq"
        else
            missing_deps+=("yq")
            if is_dnf_distro; then
                auto_installable+=("yq (sudo dnf install -y yq)")
            elif is_apt_distro; then
                manual_install+=("yq (must install mikefarah/yq from GitHub, apt package is wrong version)")
            elif is_zypper_distro; then
                auto_installable+=("yq (sudo zypper install -y yq)")
            else
                manual_install+=("yq (install from https://github.com/mikefarah/yq)")
            fi
        fi
    fi
    
    # Check for podman
    if ! command -v podman >/dev/null 2>&1; then
        missing_deps+=("podman")
        if is_dnf_distro; then
            auto_installable+=("podman (sudo dnf install -y podman)")
        elif is_apt_distro; then
            auto_installable+=("podman (sudo apt-get update && sudo apt-get install -y podman)")
        elif is_zypper_distro; then
            auto_installable+=("podman (sudo zypper install -y podman)")
        else
            manual_install+=("podman")
        fi
    else
        log "✓ podman found: $(command -v podman)"
    fi
    
    # Check for openssl (needed for certificate generation)
    if ! command -v openssl >/dev/null 2>&1; then
        missing_deps+=("openssl")
        if is_dnf_distro; then
            auto_installable+=("openssl (sudo dnf install -y openssl)")
        elif is_apt_distro; then
            auto_installable+=("openssl (sudo apt-get install -y openssl)")
        elif is_zypper_distro; then
            auto_installable+=("openssl (sudo zypper install -y openssl)")
        else
            manual_install+=("openssl")
        fi
    else
        log "✓ openssl found: $(command -v openssl)"
    fi
    
    # Check for wget or curl (needed for downloads)
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("wget or curl")
        if is_dnf_distro; then
            auto_installable+=("wget (sudo dnf install -y wget)")
        elif is_apt_distro; then
            auto_installable+=("wget (sudo apt-get install -y wget)")
        elif is_zypper_distro; then
            auto_installable+=("wget (sudo zypper install -y wget)")
        else
            manual_install+=("wget or curl")
        fi
    else
        if command -v wget >/dev/null 2>&1; then
            log "✓ wget found: $(command -v wget)"
        else
            log "✓ curl found: $(command -v curl)"
        fi
    fi
    
    # Check for git (optional but recommended)
    if ! command -v git >/dev/null 2>&1; then
        warn "git not found (optional, but recommended for repository management)"
        if is_dnf_distro; then
            auto_installable+=("git (sudo dnf install -y git)")
        elif is_apt_distro; then
            auto_installable+=("git (sudo apt-get install -y git)")
        elif is_zypper_distro; then
            auto_installable+=("git (sudo zypper install -y git)")
        fi
    else
        log "✓ git found: $(command -v git)"
    fi
    
    # Check for sudo (needed for privileged operations)
    if ! command -v sudo >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
            log "✓ Running as root (sudo not needed)"
        else
            warn "sudo not found and not running as root - some operations may fail"
            manual_install+=("sudo or run script as root")
        fi
    else
        log "✓ sudo found: $(command -v sudo)"
    fi
    
    # Check for systemctl (needed for service management)
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found - service management may not work"
        manual_install+=("systemd (usually comes with systemd-based distributions)")
    else
        log "✓ systemctl found: $(command -v systemctl)"
    fi
    
    # If there are auto-installable dependencies, offer to install them
    if [[ ${#auto_installable[@]} -gt 0 ]]; then
        echo ""
        warn "The following dependencies can be installed automatically:"
        for dep in "${auto_installable[@]}"; do
            echo "  - $dep"
        done
        echo ""
        if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
            # Non-interactive mode: auto-install dependencies
            log "Non-interactive mode: Auto-installing dependencies..."
            for dep_cmd in "${auto_installable[@]}"; do
                # Extract the command from the description
                local install_cmd
                install_cmd=$(echo "$dep_cmd" | sed -n 's/.*(\(.*\))/\1/p')
                if [[ -n "$install_cmd" ]]; then
                    log "Running: $install_cmd"
                    if eval "$install_cmd" 2>&1; then
                        # Verify the dependency is actually available after installation
                        local dep_name
                        dep_name=$(echo "$dep_cmd" | sed -n 's/^\([^ ]*\).*/\1/p')
                        if command -v "$dep_name" >/dev/null 2>&1; then
                            log "✓ Successfully installed dependency: $dep_name"
                        else
                            warn "Installation command succeeded but $dep_name is still not found in PATH"
                            manual_install+=("$dep_cmd")
                        fi
                    else
                        warn "Failed to install dependency: $dep_cmd"
                        manual_install+=("$dep_cmd")
                    fi
                fi
            done
        else
            # Interactive mode: ask user
            echo -n -e "${CYAN}Would you like to install them now? [Y/n]: ${NC}"
            read -r response
            if [[ ! "$response" =~ ^[Nn]$ ]]; then
                for dep_cmd in "${auto_installable[@]}"; do
                    # Extract the command from the description
                    local install_cmd
                    install_cmd=$(echo "$dep_cmd" | sed -n 's/.*(\(.*\))/\1/p')
                    if [[ -n "$install_cmd" ]]; then
                        log "Running: $install_cmd"
                        if eval "$install_cmd" 2>&1; then
                            # Verify the dependency is actually available after installation
                            local dep_name
                            dep_name=$(echo "$dep_cmd" | sed -n 's/^\([^ ]*\).*/\1/p')
                            if command -v "$dep_name" >/dev/null 2>&1; then
                                log "✓ Successfully installed dependency: $dep_name"
                            else
                                warn "Installation command succeeded but $dep_name is still not found in PATH"
                                manual_install+=("$dep_cmd")
                            fi
                        else
                            warn "Failed to install dependency: $dep_cmd"
                            manual_install+=("$dep_cmd")
                        fi
                    fi
                done
            fi
        fi
    fi
    
    # Check if config template exists
    if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
        error "Configuration template not found: $CONFIG_TEMPLATE"
        return 1
    fi
    
    # Report missing dependencies that require manual installation
    if [[ ${#manual_install[@]} -gt 0 ]]; then
        echo ""
        error "The following dependencies require manual installation:"
        for dep in "${manual_install[@]}"; do
            if [[ -n "$dep" ]]; then
                echo "  - $dep"
            fi
        done
        echo ""
        return 1
    fi
    
    # Final check: verify all critical dependencies are available
    local critical_missing=()
    [[ -z "$(command -v yq 2>/dev/null)" ]] && critical_missing+=("yq")
    [[ -z "$(command -v podman 2>/dev/null)" ]] && critical_missing+=("podman")
    [[ -z "$(command -v openssl 2>/dev/null)" ]] && critical_missing+=("openssl")
    
    if [[ ${#critical_missing[@]} -gt 0 ]]; then
        error "Critical dependencies still missing: ${critical_missing[*]}"
        return 1
    fi
    
    log "All dependencies satisfied"
    return 0
}

# Install correct yq (mikefarah/yq) from GitHub
install_correct_yq() {
    local arch
    arch=$(uname -m)
    local yq_arch=""
    
    # Determine architecture
    if [[ "$arch" == "aarch64" ]] || [[ "$arch" == "arm64" ]]; then
        yq_arch="arm64"
    elif [[ "$arch" == "x86_64" ]] || [[ "$arch" == "amd64" ]]; then
        yq_arch="amd64"
    else
        warn "Unsupported architecture for yq: $arch"
        return 1
    fi
    
    local yq_version="v4.44.3"
    local yq_url="https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_${yq_arch}"
    local yq_dest="/usr/local/bin/yq"
    
    # Try wget first, then curl
    if command -v wget >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
            wget -qO "$yq_dest" "$yq_url" 2>/dev/null || return 1
        else
            sudo wget -qO "$yq_dest" "$yq_url" 2>/dev/null || return 1
        fi
    elif command -v curl >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
            curl -sL "$yq_url" -o "$yq_dest" 2>/dev/null || return 1
        else
            sudo curl -sL "$yq_url" -o "$yq_dest" 2>/dev/null || return 1
        fi
    else
        warn "Neither wget nor curl available to download yq"
        return 1
    fi
    
    # Make executable
    if [[ $EUID -eq 0 ]]; then
        chmod +x "$yq_dest" 2>/dev/null || return 1
    else
        sudo chmod +x "$yq_dest" 2>/dev/null || return 1
    fi
    
    # Ensure /usr/local/bin is in PATH
    export PATH="/usr/local/bin:$PATH"
    
    # Verify it works
    if "$yq_dest" --version >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check prerequisites (backward compatibility wrapper)
check_prerequisites() {
    check_and_install_dependencies
}

# Parse command line arguments
parse_args() {
    RESTORE_MODE=false
    RESTORE_TIMESTAMP=""
    NON_INTERACTIVE=false
    RESET_PASSWORD=""
    EXTENDED_MODE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --restore)
                RESTORE_MODE=true
                if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^- ]]; then
                    RESTORE_TIMESTAMP="$2"
                    shift
                fi
                shift
                ;;
            --non-interactive|--auto)
                NON_INTERACTIVE=true
                shift
                ;;
            --upgrade)
                UPGRADE_MODE=true
                NON_INTERACTIVE=true
                shift
                ;;
            --extended)
                EXTENDED_MODE=true
                shift
                ;;
            --reset-pass)
                # If password argument is provided, use it; otherwise default to "ztpboot"
                if [[ -n "${2:-}" ]] && [[ ! "$2" =~ ^- ]]; then
                    # Remove quotes if present (handles both single and double quotes)
                    RESET_PASSWORD="${2}"
                    # Remove surrounding quotes if they match
                    if [[ "${RESET_PASSWORD:0:1}" == "'" ]] && [[ "${RESET_PASSWORD: -1}" == "'" ]]; then
                        RESET_PASSWORD="${RESET_PASSWORD:1:-1}"
                    elif [[ "${RESET_PASSWORD:0:1}" == "\"" ]] && [[ "${RESET_PASSWORD: -1}" == "\"" ]]; then
                        RESET_PASSWORD="${RESET_PASSWORD:1:-1}"
                    fi
                    shift 2
                else
                    # No password provided, use default
                    RESET_PASSWORD="ztpboot123"
                    shift
                fi
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
    --restore [TIMESTAMP]    Restore from a previous backup
                            If TIMESTAMP is not provided, will list available backups
    --non-interactive        Run in non-interactive mode (use defaults, auto-answer prompts)
                            Works for fresh installs or upgrades. If previous install exists,
                            creates backup and uses previous values, but continues if backup fails.
    --auto                   Alias for --non-interactive
    --upgrade                Upgrade existing installation (requires previous install)
                            Strict upgrade mode: requires existing install, requires successful backup,
                            uses all previous values, runs non-interactively. Use for upgrades only.
    --extended               Show extended configuration options (health checks, restart policy, etc.)
                            By default, these options use sensible defaults and are not prompted.
    --reset-pass [PASSWORD] Set/reset admin password for Web UI (can be used with --upgrade)
                            If PASSWORD is not provided, defaults to "ztpboot123"
                            Password can be quoted: --reset-pass 'password' or --reset-pass "password"
                            Overrides existing password hash in upgrade mode.
    -h, --help              Show this help message

Examples:
    $0                      # Run interactive setup
    $0 --non-interactive    # Run automated setup (works for fresh installs or upgrades)
    $0 --auto               # Same as --non-interactive
    $0 --extended           # Run interactive setup with extended options
    $0 --upgrade            # Upgrade existing installation (non-interactive, preserves all values)
    $0 --upgrade --reset-pass 'newpassword'  # Upgrade and reset password
    $0 --upgrade --reset-pass  # Upgrade and reset to default password "ztpboot123"
    $0 --reset-pass 'mypass123'  # Set password during setup
    $0 --reset-pass  # Set default password "ztpboot123" during setup
    $0 --restore            # List and restore from available backups
    $0 --restore 20240101_120000  # Restore from specific backup

EOF
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

# Main function
main() {
    # Parse command line arguments
    parse_args "$@"
    
    # Handle restore mode
    if [[ "$RESTORE_MODE" == "true" ]]; then
        if ! restore_backup "$RESTORE_TIMESTAMP"; then
            exit 1
        fi
        exit 0
    fi
    
    # Check prerequisites first
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Check if running as root (optional for interactive mode)
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root. Some operations may require sudo."
    fi
    
    # Check for previous installation
    local default_script_dir="/opt/containerdata/ztpbootstrap"
    local had_previous_install=false
    
    # If --upgrade flag is used, require a previous installation
    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log "Upgrade mode: Checking for existing installation..."
        if ! detect_previous_install "$default_script_dir"; then
            error "Upgrade mode requires an existing installation to be present."
            error "No previous installation detected in: $default_script_dir"
            error "Please run without --upgrade flag for a fresh installation."
        fi
        log "Upgrade mode: Previous installation detected. Proceeding with upgrade..."
        echo ""
    fi
    
    # Always try to load existing values first (before any cleanup)
    # This allows us to use existing values even if detection fails
    log "Attempting to load existing installation values..."
    load_existing_installation_values "$default_script_dir"
    echo ""
    
    if detect_previous_install "$default_script_dir"; then
        had_previous_install=true
        echo ""
        warn "⚠️  Previous installation detected!"
        warn "Found existing files in:"
        if [[ -d "$default_script_dir" ]] && [[ -n "$(find "$default_script_dir" -type f 2>/dev/null | head -1)" ]]; then
            warn "  - $default_script_dir"
        fi
        if [[ -d "/etc/containers/systemd/ztpbootstrap" ]] && [[ -n "$(find /etc/containers/systemd/ztpbootstrap -type f 2>/dev/null | head -1)" ]]; then
            warn "  - /etc/containers/systemd/ztpbootstrap"
        fi
        echo ""
        
        # Check for running services
        local service_info
        service_info=$(check_running_services 2>/dev/null || echo "none:")
        local service_type="${service_info%%:*}"
        local services="${service_info#*:}"
        
        if [[ "$service_type" != "none" ]] && [[ -n "$services" ]]; then
            warn "⚠️  Services are currently running:"
            IFS=' ' read -ra SERVICE_ARRAY <<< "$services"
            for service in "${SERVICE_ARRAY[@]}"; do
                if [[ -n "$service" ]]; then
                    warn "  - $service"
                fi
            done
            echo ""
            warn "Services must be stopped before proceeding with installation/upgrade."
            if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
                STOP_SERVICES="true"
                log "Upgrade mode: Auto-stopping services..."
            elif [[ "$NON_INTERACTIVE" == "true" ]]; then
                STOP_SERVICES="true"
                log "Non-interactive mode: Auto-stopping services..."
            else
                prompt_yes_no "Stop services gracefully before proceeding?" "n" STOP_SERVICES
                
                if [[ "$STOP_SERVICES" != "true" ]]; then
                    log "Setup cancelled. Please stop services manually and try again."
                    exit 0
                fi
            fi
            
            # Stop services gracefully
            if ! stop_services_gracefully "$service_info"; then
                warn "Failed to stop some services. Proceeding anyway..."
            fi
            echo ""
        fi
        
        # Create backup
        if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
            CREATE_BACKUP="true"
            log "Upgrade mode: Auto-creating backup (required)..."
        elif [[ "$NON_INTERACTIVE" == "true" ]]; then
            CREATE_BACKUP="true"
            log "Non-interactive mode: Auto-creating backup..."
        else
            prompt_yes_no "Would you like to create a backup before proceeding?" "y" CREATE_BACKUP
        fi
        
        if [[ "$CREATE_BACKUP" == "true" ]]; then
            if ! create_backup "$default_script_dir"; then
                if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
                    error "Upgrade mode requires a successful backup. Backup failed."
                    error "Please resolve backup issues and try again."
                fi
                warn "Backup failed, but continuing with setup..."
                if [[ "$NON_INTERACTIVE" == "true" ]]; then
                    CONTINUE_SETUP="true"
                    log "Non-interactive mode: Continuing despite backup failure..."
                else
                    echo ""
                    prompt_yes_no "Continue with setup anyway?" "y" CONTINUE_SETUP
                    if [[ "$CONTINUE_SETUP" != "true" ]]; then
                        log "Setup cancelled."
                        exit 0
                    fi
                fi
            fi
        else
            warn "No backup will be created. Existing files may be overwritten."
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                CONTINUE_SETUP="true"
                log "Non-interactive mode: Continuing without backup..."
            else
                echo ""
                prompt_yes_no "Continue with setup?" "y" CONTINUE_SETUP
                if [[ "$CONTINUE_SETUP" != "true" ]]; then
                    log "Setup cancelled."
                    exit 0
                fi
            fi
        fi
        echo ""
        
        # Clean installation directories (after backup is safe)
        log "Cleaning installation directories for fresh installation..."
        clean_installation_directories "$default_script_dir"
        echo ""
    fi
    
    # Try to load existing config
    load_existing_config || true
    
    # Run interactive configuration
    if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
        log "Upgrade mode: Using all previous installation values for configuration..."
        log "All existing values will be preserved and applied automatically."
        # Set APPLY_NOW to true automatically
        APPLY_NOW="true"
        # Use loaded existing values or defaults for all config
        NON_INTERACTIVE=true interactive_config
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        log "Non-interactive mode: Using loaded defaults for all configuration..."
        # Set APPLY_NOW to true automatically
        APPLY_NOW="true"
        # Use loaded existing values or defaults for all config
        # The interactive_config function will be skipped, we'll set variables directly
        # But we still need to call it to set all variables - modify it to skip prompts in non-interactive mode
        NON_INTERACTIVE=true interactive_config
    else
        interactive_config
    fi
    
    # Generate YAML config
    generate_yaml_config
    
    log "Interactive setup completed!"
    echo ""
    if [[ "$APPLY_NOW" == "true" ]]; then
        log "Configuration has been applied to all files."
        log ""
        
        # Offer to start services if we had a previous installation
        if [[ -n "${default_script_dir:-}" ]] && detect_previous_install "$default_script_dir" 2>/dev/null; then
            # This shouldn't happen since we cleaned directories, but check anyway
            true
        fi
        
        # Offer to start services
        echo ""
        if [[ "${UPGRADE_MODE:-false}" == "true" ]]; then
            START_SERVICES="true"
            log "Upgrade mode: Auto-starting services..."
        elif [[ "$NON_INTERACTIVE" == "true" ]]; then
            START_SERVICES="true"
            log "Non-interactive mode: Auto-starting services..."
        else
            prompt_yes_no "Would you like to start the services now?" "y" START_SERVICES
        fi
        
        if [[ "$START_SERVICES" == "true" ]]; then
            start_services_after_install
            echo ""
            log "Services have been started. You can check status with:"
            log "  systemctl status ztpbootstrap-pod"
            log "  systemctl status ztpbootstrap-nginx"
            log "  systemctl status ztpbootstrap-webui"
            # If password was reset, verify hash was written and remind about webui restart
            if [[ -n "${ADMIN_PASSWORD_HASH:-}" ]]; then
                echo ""
                log "Password was reset. Verifying hash in config file..."
                if command -v yq >/dev/null 2>&1 && [[ -f "$CONFIG_FILE" ]]; then
                    local written_hash
                    written_hash=$(yq eval '.auth.admin_password_hash // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
                    if [[ -n "$written_hash" ]]; then
                        log "✓ Password hash found in config.yaml (length: ${#written_hash})"
                        if [[ "$written_hash" == "$ADMIN_PASSWORD_HASH" ]]; then
                            log "✓ Hash matches expected value"
                        else
                            warn "Hash mismatch! Expected: ${ADMIN_PASSWORD_HASH:0:30}..., Got: ${written_hash:0:30}..."
                        fi
                    else
                        warn "Password hash not found in config.yaml!"
                    fi
                fi
                log ""
                log "Note: The webui service has been restarted to load the new password."
                log "      If login still fails, verify the hash and restart webui:"
                log "      sudo systemctl restart ztpbootstrap-webui"
            fi
        else
            log "Next steps:"
            log "  1. Review the updated files if needed"
            log "  2. Run: sudo ./setup.sh"
            log "  3. Or run: sudo ./setup.sh --http-only (for testing)"
        fi
    else
        log "Next steps:"
        log "  1. Review config.yaml"
        log "  2. Run: ./update-config.sh config.yaml (to apply configuration)"
        log "  3. Then run: sudo ./setup.sh"
    fi
}

# Run main function
main "$@"
