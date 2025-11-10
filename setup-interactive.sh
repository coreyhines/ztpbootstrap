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
    
    # Check for old single-container service
    if systemctl is-active --quiet ztpbootstrap.service 2>/dev/null; then
        running_services+=("ztpbootstrap.service")
        service_type="single-container"
    fi
    
    # Check for new pod-based services
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
    
    if [[ "$service_type" == "single-container" ]]; then
        # Old version: stop single container service
        log "Stopping ztpbootstrap.service (single-container setup)..."
        if [[ $EUID -eq 0 ]]; then
            systemctl stop ztpbootstrap.service 2>/dev/null || warn "Failed to stop ztpbootstrap.service"
        else
            sudo systemctl stop ztpbootstrap.service 2>/dev/null || warn "Failed to stop ztpbootstrap.service"
        fi
        sleep 2
    elif [[ "$service_type" == "pod-based" ]]; then
        # New version: stop containers first, then pod
        log "Stopping pod-based services..."
        if [[ $EUID -eq 0 ]]; then
            systemctl stop ztpbootstrap-nginx.service ztpbootstrap-webui.service 2>/dev/null || true
            sleep 1
            systemctl stop ztpbootstrap-pod.service 2>/dev/null || warn "Failed to stop ztpbootstrap-pod.service"
        else
            sudo systemctl stop ztpbootstrap-nginx.service ztpbootstrap-webui.service 2>/dev/null || true
            sleep 1
            sudo systemctl stop ztpbootstrap-pod.service 2>/dev/null || warn "Failed to stop ztpbootstrap-pod.service"
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
    
    # Prefer pod file, but if it's missing IP6 and container file has it, use container file
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
    
    log "Reading existing installation values..."
    
    # First, try to read from config.yaml in installation directory (highest priority)
    # Only use repo's config.yaml as fallback if installation directory doesn't have one
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local install_config_file="${script_dir}/config.yaml"
    local repo_config_file="${repo_dir}/config.yaml"
    local config_file=""
    
    # Prefer config.yaml in installation directory over repo directory
    if [[ -f "$install_config_file" ]] && command -v yq >/dev/null 2>&1; then
        config_file="$install_config_file"
        log "Reading from config.yaml in installation directory (highest priority)..."
    elif [[ -f "$repo_config_file" ]] && command -v yq >/dev/null 2>&1; then
        # Only use repo's config.yaml if installation directory doesn't have one
        # This prevents using template values from the repo
        config_file="$repo_config_file"
        log "Reading from config.yaml in repo directory..."
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
            esac
        done < <(read_config_yaml "config.yaml" "$(dirname "$config_file")")
        log "  Loaded values from config.yaml"
    elif [[ -f "$install_config_file" ]] || [[ -f "$repo_config_file" ]]; then
        log "config.yaml found but yq is not installed, skipping config.yaml read"
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
    fi
    
    return 0
}

start_services_after_install() {
    log "Starting new services..."
    
    # Reload systemd first
    if [[ $EUID -eq 0 ]]; then
        systemctl daemon-reload
    else
        sudo systemctl daemon-reload
    fi
    
    sleep 2
    
    # Start pod service
    if [[ $EUID -eq 0 ]]; then
        if systemctl start ztpbootstrap-pod.service 2>/dev/null; then
            log "✓ Started ztpbootstrap-pod.service"
            sleep 2
        else
            warn "Failed to start ztpbootstrap-pod.service"
        fi
        
        # Start nginx container
        if systemctl start ztpbootstrap-nginx.service 2>/dev/null; then
            log "✓ Started ztpbootstrap-nginx.service"
        else
            warn "Failed to start ztpbootstrap-nginx.service"
        fi
        
        # Start webui container if it exists
        if systemctl list-unit-files | grep -q ztpbootstrap-webui.service; then
            if systemctl start ztpbootstrap-webui.service 2>/dev/null; then
                log "✓ Started ztpbootstrap-webui.service"
            else
                warn "Failed to start ztpbootstrap-webui.service"
            fi
        fi
    else
        if sudo systemctl start ztpbootstrap-pod.service 2>/dev/null; then
            log "✓ Started ztpbootstrap-pod.service"
            sleep 2
        else
            warn "Failed to start ztpbootstrap-pod.service"
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
    
    # Section 1: Directory Paths
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
    
    # Section 2: Network Configuration
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
    prompt_with_default "HTTPS port" "${EXISTING_HTTPS_PORT:-443}" HTTPS_PORT
    prompt_with_default "HTTP port" "80" HTTP_PORT
    # Determine default for HTTP-only mode
    local default_http_only="n"
    if [[ "${EXISTING_HTTP_ONLY:-}" == "true" ]]; then
        default_http_only="y"
    fi
    prompt_yes_no "Use HTTP-only mode (insecure, not recommended)" "$default_http_only" HTTP_ONLY
    
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
    
    prompt_with_default "CVaaS address" "${EXISTING_CV_ADDR:-www.arista.io}" CV_ADDR
    prompt_with_default "Enrollment token (from CVaaS Device Registration)" "${EXISTING_ENROLLMENT_TOKEN:-}" ENROLLMENT_TOKEN "true"
    prompt_with_default "Proxy URL (leave empty if not needed)" "${EXISTING_CV_PROXY:-}" CV_PROXY
    prompt_with_default "EOS image URL (optional, for upgrades)" "${EXISTING_EOS_URL:-}" EOS_URL
    prompt_with_default "NTP server" "${EXISTING_NTP_SERVER:-time.nist.gov}" NTP_SERVER
    
    echo ""
    
    # Section 4: SSL Certificate Configuration
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
        
        prompt_yes_no "Create self-signed certificate for testing (if no cert exists)?" "n" CREATE_SELF_SIGNED
    else
        # Certificates exist, skip these prompts
        USE_LETSENCRYPT="false"
        LETSENCRYPT_EMAIL="admin@example.com"
        CREATE_SELF_SIGNED="false"
    fi
    
    echo ""
    
    # Section 5: Container Configuration
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Container Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    prompt_with_default "Container name" "ztpbootstrap" CONTAINER_NAME
    prompt_with_default "Container image" "docker.io/nginx:alpine" CONTAINER_IMAGE
    prompt_with_default "Timezone" "${EXISTING_TIMEZONE:-UTC}" TIMEZONE
    # Note: Host network mode is now asked in the Network Configuration section above
    # This ensures it can override detected IP addresses
    prompt_with_default "DNS server 1" "${EXISTING_DNS1:-8.8.8.8}" DNS1
    prompt_with_default "DNS server 2" "${EXISTING_DNS2:-8.8.4.4}" DNS2
    
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
            create_pod_files_from_config
        else
            warn "setup.sh not found. Pod files will not be created automatically."
            warn "You will need to run: sudo ./setup.sh"
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

# Parse command line arguments
parse_args() {
    RESTORE_MODE=false
    RESTORE_TIMESTAMP=""
    
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
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
    --restore [TIMESTAMP]    Restore from a previous backup
                            If TIMESTAMP is not provided, will list available backups
    -h, --help              Show this help message

Examples:
    $0                      # Run interactive setup
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
            prompt_yes_no "Stop services gracefully before proceeding?" "n" STOP_SERVICES
            
            if [[ "$STOP_SERVICES" != "true" ]]; then
                log "Setup cancelled. Please stop services manually and try again."
                exit 0
            fi
            
            # Stop services gracefully
            if ! stop_services_gracefully "$service_info"; then
                warn "Failed to stop some services. Proceeding anyway..."
            fi
            echo ""
        fi
        
        # Create backup
        prompt_yes_no "Would you like to create a backup before proceeding?" "y" CREATE_BACKUP
        
        if [[ "$CREATE_BACKUP" == "true" ]]; then
            if ! create_backup "$default_script_dir"; then
                warn "Backup failed, but continuing with setup..."
                echo ""
                prompt_yes_no "Continue with setup anyway?" "y" CONTINUE_SETUP
                if [[ "$CONTINUE_SETUP" != "true" ]]; then
                    log "Setup cancelled."
                    exit 0
                fi
            fi
        else
            warn "No backup will be created. Existing files may be overwritten."
            echo ""
            prompt_yes_no "Continue with setup?" "y" CONTINUE_SETUP
            if [[ "$CONTINUE_SETUP" != "true" ]]; then
                log "Setup cancelled."
                exit 0
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
    interactive_config
    
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
        prompt_yes_no "Would you like to start the services now?" "y" START_SERVICES
        
        if [[ "$START_SERVICES" == "true" ]]; then
            start_services_after_install
            echo ""
            log "Services have been started. You can check status with:"
            log "  systemctl status ztpbootstrap-pod"
            log "  systemctl status ztpbootstrap-nginx"
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
