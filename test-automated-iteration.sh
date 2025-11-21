#!/bin/bash
# Automated Testing Iteration Script
# Runs comprehensive tests across multiple scenarios and iterates on failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="${DISTRO:-fedora}"
VERSION="${VERSION:-43}"
TEST_MATRIX="${TEST_MATRIX:-test-matrix.yaml}"
MAX_ITERATIONS="${MAX_ITERATIONS:-1}"
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-false}"
REPORT_DIR="${REPORT_DIR:-./test-reports}"
SSH_PORT="${SSH_PORT:-2222}"
VM_NAME="${VM_NAME:-ztpbootstrap-test-vm}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
CURRENT_ITERATION=0

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

# Common SSH options to prevent hanging
SSH_OPTS=(
    -o ConnectTimeout=60
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

# SSH command with timeout wrapper
# Usage: ssh_with_timeout [timeout_seconds] [ssh_args...] [command]
ssh_with_timeout() {
    local timeout_sec="${1:-900}"  # Default 15 minutes
    shift
    local ssh_cmd=("ssh" "${SSH_OPTS[@]}" "$@")
    
    # Check if timeout command is available on remote system
    # If not, we'll rely on ServerAliveInterval to detect dead connections
    local test_timeout=$(ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@localhost" "command -v timeout >/dev/null 2>&1 && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
    
    if [[ "$test_timeout" == "yes" ]]; then
        # Wrap command in timeout
        local last_arg="${!#}"
        set -- "${@:1:$(($#-1))}"
        "${ssh_cmd[@]}" "timeout ${timeout_sec} ${last_arg}"
    else
        # No timeout command available, just run normally (ServerAliveInterval will help)
        "${ssh_cmd[@]}"
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DISTRO] [VERSION]

Automated Testing Iteration Script

Runs comprehensive tests from a test matrix, iterating on failures until all pass
or max iterations reached.

Options:
    --test-matrix FILE      Test matrix YAML file (default: test-matrix.yaml)
    --keep-on-failure       Keep VM for debugging on failure (default: false)
    --max-iterations N      Maximum iterations before stopping (default: 1)
    --report-dir DIR        Directory for test reports (default: ./test-reports)
    --ssh-port PORT         SSH port for VM access (default: 2222)
    --help, -h              Show this help message

Arguments:
    DISTRO                  Distribution name (fedora, ubuntu, rocky, almalinux, etc.)
                            Default: fedora
    VERSION                 Distribution version (e.g., 43, 24.04, 9)
                            Default: 43

Examples:
    # Run tests with default settings
    $0

    # Run tests for Ubuntu 24.04
    $0 ubuntu 24.04

    # Run with custom test matrix and keep VM on failure
    $0 --test-matrix my-tests.yaml --keep-on-failure fedora 43

EOF
}

# Parse arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --test-matrix)
            TEST_MATRIX="$2"
            shift 2
            ;;
        --keep-on-failure)
            KEEP_ON_FAILURE=true
            shift
            ;;
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --report-dir)
            REPORT_DIR="$2"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Set distro and version from positional args
if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
    DISTRO="${POSITIONAL_ARGS[0]}"
fi
if [[ ${#POSITIONAL_ARGS[@]} -gt 1 ]]; then
    VERSION="${POSITIONAL_ARGS[1]}"
fi

# Set defaults
DISTRO="${DISTRO:-fedora}"
VERSION="${VERSION:-43}"

# Check if yq is available (needed for parsing YAML)
if ! command -v yq &> /dev/null; then
    log_error "yq is required but not installed"
    log_info "Install with: brew install yq"
    exit 1
fi

# Check if test matrix exists
if [[ ! -f "$TEST_MATRIX" ]]; then
    log_error "Test matrix file not found: $TEST_MATRIX"
    exit 1
fi

# Create report directory
mkdir -p "$REPORT_DIR"

# Determine distro-specific SSH user
get_ssh_user() {
    local distro_lower=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
    case "$distro_lower" in
        ubuntu|debian)
            echo "ubuntu"
            ;;
        rocky|rockylinux)
            echo "rocky"
            ;;
        almalinux|alma)
            echo "almalinux"
            ;;
        centos|centos-stream|centosstream)
            echo "cloud-user"
            ;;
        opensuse|opensuse-leap|leap)
            echo "opensuse"
            ;;
        *)
            # For Fedora and others, use current user
            echo "${USER:-$(whoami)}"
            ;;
    esac
}

SSH_USER=$(get_ssh_user)
CURRENT_USER="${USER:-$(whoami)}"

# Find ztpbootstrap directory in VM
find_ztpbootstrap_dir() {
    local ssh_user="$1"
    local possible_dirs=(
        "/home/${ssh_user}/ztpbootstrap"
        "/home/${CURRENT_USER}/ztpbootstrap"
        "/home/fedora/ztpbootstrap"
        "/home/ubuntu/ztpbootstrap"
        "/home/rocky/ztpbootstrap"
        "/home/almalinux/ztpbootstrap"
        "~/ztpbootstrap"
    )
    
    for dir in "${possible_dirs[@]}"; do
        local found_dir=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${ssh_user}@localhost" "test -d ${dir} && echo -n ${dir}" 2>/dev/null | tr -d '\n\r' || echo "")
        if [[ -n "$found_dir" ]]; then
            echo -n "$found_dir"
            return 0
        fi
    done
    
    return 1
}

# Wait for VM to be ready
wait_for_vm_ready() {
    local max_wait=300  # 5 minutes
    local elapsed=0
    
    log_info "Waiting for VM to be ready..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p "$SSH_PORT" "${SSH_USER}@localhost" "echo 'ready'" 2>/dev/null; then
            log_info "✓ VM is ready"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "  Still waiting... (${elapsed}s elapsed)"
        fi
    done
    
    log_error "VM did not become ready within ${max_wait}s"
    return 1
}

# Ensure repository is cloned in VM
ensure_repository_cloned() {
    log_info "Ensuring repository is cloned in VM..."
    
    # Install git if needed
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
        "if ! command -v git &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y -qq git || true
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y -q git || true
            elif command -v zypper &>/dev/null; then
                sudo zypper refresh -q && sudo zypper install -y git || true
            fi
        fi" >/dev/null 2>&1 || true
    
    local target_dir="/home/${SSH_USER}/ztpbootstrap"
    
    # Check if directory exists and is a valid git repo
    local dir_exists=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
        "test -d ${target_dir} && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
    
    local is_git_repo=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
        "test -d ${target_dir}/.git && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
    
    local script_exists=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
        "test -f ${target_dir}/setup-interactive.sh && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
    
    if [[ "$script_exists" == "yes" ]] && [[ "$is_git_repo" == "yes" ]]; then
        log_info "Repository already exists and is valid at: ${target_dir}"
        # Update it anyway
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "cd ${target_dir} && git pull || true" >/dev/null 2>&1 || true
        return 0
    fi
    
    # Repository doesn't exist or is invalid, clone it
    if [[ "$dir_exists" == "yes" ]]; then
        log_info "Directory exists but is not a valid git repo, removing and cloning fresh..."
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "rm -rf ${target_dir}" >/dev/null 2>&1 || true
    else
        log_info "Repository not found, cloning..."
    fi
    
    # Clone repository to user's home directory
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
        "cd ~ && git clone https://github.com/coreyhines/ztpbootstrap.git ${target_dir}" >/dev/null 2>&1 || {
        log_error "Failed to clone repository"
        return 1
    }
    
    # Verify script exists after clone
    script_exists=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
        "test -f ${target_dir}/setup-interactive.sh && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
    
    if [[ "$script_exists" != "yes" ]]; then
        log_error "Repository cloned but setup-interactive.sh not found"
        return 1
    fi
    
    log_info "✓ Repository cloned to ${target_dir}"
    return 0
}

# Create or reset VM
create_vm() {
    log_info "Creating/resetting VM..."
    
    # Stop existing VM if running
    pkill -f "qemu-system.*${VM_NAME}" 2>/dev/null || true
    sleep 2
    
    # Remove existing disk if present
    if [[ -f "${VM_NAME}.qcow2" ]] || [[ -f "${VM_NAME}-cloud.qcow2" ]]; then
        rm -f "${VM_NAME}.qcow2" "${VM_NAME}-cloud.qcow2" 2>/dev/null || true
    fi
    
    # Create fresh VM
    log_info "Creating fresh VM..."
    local create_log="${REPORT_DIR}/vm-create-$(date +%Y%m%d_%H%M%S).log"
    ./vm-create-native.sh --download "$DISTRO" --type cloud --arch aarch64 --version "$VERSION" --headless --name "$VM_NAME" > "$create_log" 2>&1 &
    local vm_pid=$!
    
    # Wait a bit for VM to start
    sleep 10
    
    # Wait for VM to be ready
    wait_for_vm_ready || {
        log_error "VM creation failed or VM did not become ready"
        return 1
    }
    
    log_info "✓ VM created and ready"
    
    # Ensure repository is cloned
    ensure_repository_cloned || {
        log_warn "Repository clone failed, but continuing (will retry in test execution)"
    }
}

# Diagnose and fix execution issues (exit code 126)
diagnose_and_fix_execution() {
    local ztpbootstrap_dir="$1"
    local test_dir="$2"
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        log_info "Diagnosing execution environment (attempt $((retry + 1))/$max_retries)..."
        
        # Check if script exists
        local script_exists=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "test -f ${ztpbootstrap_dir}/setup-interactive.sh && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
        
        if [[ "$script_exists" != "yes" ]]; then
            log_error "setup-interactive.sh does not exist at ${ztpbootstrap_dir}/setup-interactive.sh"
            log_info "Checking if directory exists and is a valid git repo..."
            
            # Check if directory exists and is a git repo
            local is_git_repo=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "test -d ${ztpbootstrap_dir}/.git && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
            
            if [[ "$is_git_repo" == "yes" ]]; then
                log_info "Directory is a git repo, attempting to pull..."
                ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "cd ${ztpbootstrap_dir} && git pull 2>&1 || true" \
                    > "${test_dir}/diagnosis-${retry}.log" 2>&1
            else
                log_info "Directory is not a valid git repo, removing and cloning fresh..."
                local parent_dir=$(dirname "${ztpbootstrap_dir}")
                local repo_name=$(basename "${ztpbootstrap_dir}")
                ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "rm -rf ${ztpbootstrap_dir} 2>&1 && cd ${parent_dir} && git clone https://github.com/coreyhines/ztpbootstrap.git ${repo_name} 2>&1 || true" \
                    > "${test_dir}/diagnosis-${retry}.log" 2>&1
            fi
            
            # Verify script exists after clone/pull
            sleep 2
            script_exists=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "test -f ${ztpbootstrap_dir}/setup-interactive.sh && echo 'yes' || echo 'no'" 2>/dev/null || echo "no")
            
            if [[ "$script_exists" != "yes" ]]; then
                log_warn "Script still doesn't exist after clone attempt. Log:"
                cat "${test_dir}/diagnosis-${retry}.log" 2>/dev/null | head -20 || true
                retry=$((retry + 1))
                sleep 2
                continue
            else
                log_info "✓ Script now exists after clone/pull"
            fi
        fi
        
        # Check if bash is available (check common locations first, then PATH)
        local bash_path=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "(test -x /bin/bash && echo '/bin/bash') || (test -x /usr/bin/bash && echo '/usr/bin/bash') || (command -v bash 2>/dev/null) || echo 'not found'" 2>/dev/null | head -1 | tr -d '\n\r' || echo "not found")
        
        if [[ "$bash_path" == "not found" ]] || [[ -z "$bash_path" ]]; then
            log_error "bash not found in common locations or PATH"
            return 1
        else
            log_info "Found bash at: $bash_path"
        fi
        
        # Check and fix permissions
        log_info "Checking and fixing script permissions..."
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "cd ${ztpbootstrap_dir} && \
            chmod +x setup-interactive.sh 2>&1 && \
            ls -la setup-interactive.sh 2>&1" \
            > "${test_dir}/permissions-${retry}.log" 2>&1
        
        # Verify script is readable and executable
        local script_check=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "test -r ${ztpbootstrap_dir}/setup-interactive.sh && test -x ${ztpbootstrap_dir}/setup-interactive.sh && echo 'ok' || echo 'fail'" 2>/dev/null || echo "fail")
        
        if [[ "$script_check" == "ok" ]]; then
            log_info "✓ Script permissions are correct"
            
            # Test if we can actually execute it
            log_info "Testing script execution..."
            local test_exec=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "cd ${ztpbootstrap_dir} && bash -n setup-interactive.sh 2>&1 && echo 'syntax_ok' || echo 'syntax_error'" 2>/dev/null || echo "error")
            
            if [[ "$test_exec" == "syntax_ok" ]]; then
                log_info "✓ Script syntax is valid"
                return 0
            else
                log_warn "Script syntax check failed: $test_exec"
                cat "${test_dir}/permissions-${retry}.log" 2>/dev/null || true
            fi
        else
            log_warn "Script permissions check failed"
            cat "${test_dir}/permissions-${retry}.log" 2>/dev/null || true
        fi
        
        retry=$((retry + 1))
        if [[ $retry -lt $max_retries ]]; then
            log_info "Retrying diagnosis in 2 seconds..."
            sleep 2
        fi
    done
    
    log_error "Failed to fix execution issues after $max_retries attempts"
    return 1
}

# Run a single test
run_test() {
    local test_name="$1"
    local test_config="$2"
    local iteration="$3"
    
    log_test "Running test: $test_name (iteration $iteration)"
    
    local test_dir="${REPORT_DIR}/test-${test_name}-iter${iteration}-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$test_dir"
    
    # Find ztpbootstrap directory (strip any trailing whitespace/newlines)
    local ztpbootstrap_dir=$(find_ztpbootstrap_dir "$SSH_USER" | tr -d '\n\r' | xargs)
    if [[ -z "$ztpbootstrap_dir" ]]; then
        log_error "Could not find ztpbootstrap directory"
        echo "FAILED: Could not find ztpbootstrap directory" > "${test_dir}/result.txt"
        return 1
    fi
    
    log_info "Found ztpbootstrap at: $ztpbootstrap_dir"
    
    # Extract test configuration
    # test_config is a YAML string passed as parameter, so we need to echo it and pipe to yq
    local scenario=$(echo "$test_config" | yq -r '.scenario // "fresh"')
    
    # Extract setup_interactive_args - handle array properly
    # First check if the field exists
    local has_args=$(echo "$test_config" | yq -r 'has("setup_interactive_args")' 2>/dev/null || echo "false")
    local setup_args=""
    
    if [[ "$has_args" == "true" ]]; then
        # Extract array elements and join with spaces
        setup_args=$(echo "$test_config" | yq -r '.setup_interactive_args[]?' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' | xargs || echo "")
    fi
    
    local expected_exit=$(echo "$test_config" | yq -r '.expected_exit_code // 0')
    local requires_existing=$(echo "$test_config" | yq -r '.requires_existing_install // false')
    
    # Debug: log setup_args (always log to help debug)
    log_info "Setup args extracted: '${setup_args:-<empty>}'"
    
    # If test requires existing installation, set one up first
    if [[ "$requires_existing" == "true" ]]; then
        log_info "Test requires existing installation, setting up..."
        
        # Check if initial_setup_env is specified for upgrade tests
        local initial_env_vars=""
        local initial_setup_env=$(echo "$test_config" | yq -r '.initial_setup_env // {}' 2>/dev/null || echo "{}")
        if [[ "$initial_setup_env" != "null" ]] && [[ "$initial_setup_env" != "{}" ]]; then
            while IFS='=' read -r key value; do
                initial_env_vars="${initial_env_vars}export ${key}=${value}; "
            done < <(echo "$initial_setup_env" | yq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null || echo "")
        fi
        
        # Ensure script is executable before running
        diagnose_and_fix_execution "$ztpbootstrap_dir" "$test_dir" || {
            log_warn "Diagnosis found issues, but continuing with existing install setup..."
        }
        
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
            "cd ${ztpbootstrap_dir} && ${initial_env_vars}bash ./setup-interactive.sh --non-interactive" \
            > "${test_dir}/setup-existing.log" 2>&1 || {
            log_warn "Failed to set up existing installation, continuing anyway..."
        }
        
        # Wait a moment for services to start
        sleep 5
    else
        # For tests that don't require existing installation, ensure clean state
        # This is especially important for tests like upgrade_without_existing_install
        # that expect no existing installation
        if echo "$setup_args" | grep -qE "\--upgrade"; then
            log_info "Upgrade test without existing install: cleaning any leftover installation files and directories..."
            ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "sudo rm -rf /opt/containerdata/ztpbootstrap /etc/containers/systemd/ztpbootstrap 2>/dev/null || true; \
                 sudo mkdir -p /opt/containerdata/ztpbootstrap /etc/containers/systemd/ztpbootstrap 2>/dev/null || true" >/dev/null 2>&1 || true
            # Verify cleanup worked
            local remaining_files=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "sudo find /opt/containerdata/ztpbootstrap /etc/containers/systemd/ztpbootstrap -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d '\n\r' || echo "0")
            if [[ "$remaining_files" != "0" ]]; then
                log_warn "Warning: $remaining_files files still remain after cleanup"
            else
                log_info "✓ Cleanup verified: no installation files remain"
            fi
        fi
    fi
    
    # Set up environment if needed
    # For non-interactive mode, we need to pre-create config.yaml with desired values
    # since setup-interactive.sh doesn't read environment variables directly
    local env_vars=""
    local env_config=$(echo "$test_config" | yq -r '.environment // {}')
    
    # Check if we're using non-interactive mode (check setup_args)
    local is_non_interactive=false
    if echo "$setup_args" | grep -qE "non-interactive|--non-interactive"; then
        is_non_interactive=true
    fi
    
    if [[ "$env_config" != "null" ]] && [[ "$env_config" != "{}" ]]; then
        # For non-interactive mode, pre-create config.yaml
        if [[ "$is_non_interactive" == "true" ]]; then
            # Pre-create config.yaml with environment values
            log_info "Pre-creating config.yaml with test environment values..."
            local config_yaml="${ztpbootstrap_dir}/config.yaml"
            
            # Read existing config.yaml if it exists, or start from template
            if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "test -f ${config_yaml}" 2>/dev/null; then
                # Copy existing config as backup
                ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "cp ${config_yaml} ${config_yaml}.backup" 2>/dev/null || true
            else
                # Create from template if available, otherwise create minimal config
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "test -f ${ztpbootstrap_dir}/config.yaml.template" 2>/dev/null; then
                    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                        "cp ${ztpbootstrap_dir}/config.yaml.template ${config_yaml}" 2>/dev/null || true
                else
                    # Create minimal config.yaml if template doesn't exist
                    log_warn "config.yaml.template not found, creating minimal config.yaml"
                    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                        "cat > ${config_yaml} << 'CONFIGEOF'
paths:
  script_dir: \"/opt/containerdata/ztpbootstrap\"
  cert_dir: \"/opt/containerdata/certs/wild\"
network:
  domain: \"ztpboot.example.com\"
  ipv4: \"10.0.0.10\"
  https_port: 443
  http_port: 80
  http_only: false
cvaas:
  address: \"www.arista.io\"
  enrollment_token: \"test_token_for_automated_testing\"
  ntp_server: \"time.nist.gov\"
ssl:
  cert_file: \"fullchain.pem\"
  key_file: \"privkey.pem\"
  use_letsencrypt: false
  create_self_signed: false
container:
  host_network: false
CONFIGEOF
" 2>/dev/null || true
                fi
            fi
            
            # Set required default values in config.yaml if not already set
            # These are needed for non-interactive mode to work
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "cd ${ztpbootstrap_dir} && \
                yq e '.cvaas.enrollment_token = \"test_token_for_automated_testing\"' -i config.yaml 2>/dev/null || true && \
                yq e '.cvaas.address = \"www.arista.io\"' -i config.yaml 2>/dev/null || true && \
                yq e '.network.domain = \"ztpboot.example.com\"' -i config.yaml 2>/dev/null || true && \
                yq e '.network.https_port = 443' -i config.yaml 2>/dev/null || true && \
                yq e '.network.http_port = 80' -i config.yaml 2>/dev/null || true && \
                yq e '.cvaas.ntp_server = \"time.nist.gov\"' -i config.yaml 2>/dev/null || true" >/dev/null 2>&1 || true
            
            # Update config.yaml with environment values using yq
            while IFS='=' read -r key value; do
                case "$key" in
                    HTTP_ONLY)
                        # Boolean value - convert string to boolean
                        local bool_val="false"
                        [[ "$value" == "true" ]] && bool_val="true"
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.network.http_only = ${bool_val}' -i config.yaml" 2>/dev/null || true
                        ;;
                    HOST_NETWORK)
                        # Boolean value - convert string to boolean
                        local bool_val="false"
                        [[ "$value" == "true" ]] && bool_val="true"
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.container.host_network = ${bool_val}' -i config.yaml" 2>/dev/null || true
                        ;;
                    USE_LETSENCRYPT)
                        # Boolean value - convert string to boolean
                        local bool_val="false"
                        [[ "$value" == "true" ]] && bool_val="true"
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.ssl.use_letsencrypt = ${bool_val}' -i config.yaml" 2>/dev/null || true
                        ;;
                    CREATE_SELF_SIGNED)
                        # Boolean value - convert string to boolean
                        local bool_val="false"
                        [[ "$value" == "true" ]] && bool_val="true"
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.ssl.create_self_signed = ${bool_val}' -i config.yaml" 2>/dev/null || true
                        ;;
                    IPV4)
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.network.ipv4 = \"${value}\"' -i config.yaml" 2>/dev/null || true
                        ;;
                    IPV6)
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.network.ipv6 = \"${value}\"' -i config.yaml" 2>/dev/null || true
                        ;;
                    LETSENCRYPT_EMAIL)
                        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                            "cd ${ztpbootstrap_dir} && yq e '.ssl.letsencrypt_email = \"${value}\"' -i config.yaml" 2>/dev/null || true
                        ;;
                    CREATE_BACKUP)
                        # This is handled by setup-interactive.sh prompts, not config.yaml
                        env_vars="${env_vars}export ${key}=${value}; "
                        ;;
                    *)
                        # For other vars, just export them
                        env_vars="${env_vars}export ${key}=${value}; "
                        ;;
                esac
            done < <(echo "$env_config" | yq -r 'to_entries[] | "\(.key)=\(.value)"')
        else
            # For interactive mode, just export environment variables
            while IFS='=' read -r key value; do
                env_vars="${env_vars}export ${key}=${value}; "
            done < <(echo "$env_config" | yq -r 'to_entries[] | "\(.key)=\(.value)"')
        fi
    fi
    
    # Prepare interactive responses if needed
    local responses_file=""
    local interactive_responses=$(echo "$test_config" | yq -r '.interactive_responses[]? // empty' 2>/dev/null || echo "")
    if [[ -n "$interactive_responses" ]] && [[ "$interactive_responses" != "null" ]] && [[ "$interactive_responses" != "" ]]; then
        responses_file="${test_dir}/responses.txt"
        echo "$interactive_responses" | yq -r '.[]' 2>/dev/null > "$responses_file" || {
            # Fallback: try to extract as array
            echo "$test_config" | yq -r '.interactive_responses[]?' 2>/dev/null > "$responses_file" || true
        }
    fi
    
    # Run the test with automatic retry on exit code 126
    # Ensure setup_args is properly trimmed and formatted
    setup_args=$(echo "$setup_args" | xargs)
    
    local max_exec_retries=3
    local exec_retry=0
    local exit_code=0
    local last_error=""
    
    while [[ $exec_retry -lt $max_exec_retries ]]; do
        # Diagnose and fix execution issues before running
        if [[ $exec_retry -eq 0 ]]; then
            # First attempt: do quick check
            diagnose_and_fix_execution "$ztpbootstrap_dir" "$test_dir" || {
                log_warn "Initial diagnosis found issues, but continuing..."
            }
        else
            # Subsequent attempts: full diagnosis
            log_info "Re-diagnosing after exit code 126 (retry $exec_retry/$max_exec_retries)..."
            diagnose_and_fix_execution "$ztpbootstrap_dir" "$test_dir" || {
                log_error "Failed to fix execution issues"
                exit_code=126
                break
            }
        fi
        
        # Construct command properly - ensure env_vars and setup_args are properly quoted
        local cmd="cd ${ztpbootstrap_dir} && ${env_vars}bash ./setup-interactive.sh ${setup_args}"
        log_info "Executing: $cmd"
        
        exit_code=0
        if [[ -n "$responses_file" ]] && [[ -f "$responses_file" ]]; then
            # Interactive mode with canned responses - copy responses file to VM first
            scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$SSH_PORT" \
                "$responses_file" "${SSH_USER}@localhost:/tmp/responses.txt" >/dev/null 2>&1
            # Interactive mode with canned responses - use a here-doc to avoid quoting issues
            # Use timeout to prevent hanging, and ServerAlive to detect dead connections
            ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "cd ${ztpbootstrap_dir} && (command -v timeout >/dev/null 2>&1 && timeout 900 ${env_vars}cat /tmp/responses.txt | bash ./setup-interactive.sh ${setup_args} || ${env_vars}cat /tmp/responses.txt | bash ./setup-interactive.sh ${setup_args})" \
                > "${test_dir}/output.log" 2>&1 || exit_code=$?
            
            # Check if timeout killed the process
            if grep -q "Terminated\|timeout:" "${test_dir}/output.log" 2>/dev/null; then
                log_error "Command was terminated by timeout (15 minutes exceeded)"
                exit_code=124  # timeout exit code
            fi
        else
            # Non-interactive mode (or no responses file)
            # SIMPLE APPROACH: Just run the script directly via SSH, like test-interactive-setup.sh does
            log_info "Running: cd ${ztpbootstrap_dir} && ${env_vars}bash ./setup-interactive.sh ${setup_args}"
            
            # Run script directly - simplest possible approach (same as test-interactive-setup.sh)
            # Use timeout to prevent hanging, and ServerAlive to detect dead connections
            # Timeout: 15 minutes (900 seconds) should be enough for any setup
            ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@localhost" \
                "cd ${ztpbootstrap_dir} && (command -v timeout >/dev/null 2>&1 && timeout 900 ${env_vars}bash ./setup-interactive.sh ${setup_args} || ${env_vars}bash ./setup-interactive.sh ${setup_args})" \
                > "${test_dir}/output.log" 2>&1 || exit_code=$?
            
            # Check if timeout killed the process
            if grep -q "Terminated\|timeout:" "${test_dir}/output.log" 2>/dev/null; then
                log_error "Command was terminated by timeout (15 minutes exceeded)"
                exit_code=124  # timeout exit code
            fi
            
            # Check output
            if [[ -f "${test_dir}/output.log" ]]; then
                local line_count=$(wc -l < "${test_dir}/output.log" 2>/dev/null | tr -d ' ' || echo "0")
                log_info "Output log has $line_count lines"
                if [[ $line_count -lt 5 ]]; then
                    log_warn "Output log is very short - script may not have run. First 20 lines:"
                    head -20 "${test_dir}/output.log" | while IFS= read -r line; do
                        log_info "  $line"
                    done || true
                fi
            fi
        fi
        
        # Always show output for debugging when exit code doesn't match expected
        if [[ $exit_code -ne $expected_exit ]]; then
            log_warn "Script exited with code $exit_code (expected $expected_exit). Last 50 lines of output:"
            tail -50 "${test_dir}/output.log" 2>/dev/null | while IFS= read -r line; do
                log_info "  $line"
            done || true
        elif [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 126 ]]; then
            # Show output for non-zero exit codes even if they match expected (for debugging)
            log_info "Script exited with expected code $exit_code. Last 20 lines of output:"
            tail -20 "${test_dir}/output.log" 2>/dev/null | while IFS= read -r line; do
                log_info "  $line"
            done || true
        fi
        
        # If exit code is 126 (command not executable), retry after fixing
        if [[ $exit_code -eq 126 ]]; then
            log_warn "Exit code 126 detected (command not executable), attempting to fix..."
            last_error=$(tail -20 "${test_dir}/output.log" 2>/dev/null || echo "No error output")
            log_info "Last error output:"
            echo "$last_error" | while IFS= read -r line; do
                log_info "  $line"
            done
            
            exec_retry=$((exec_retry + 1))
            if [[ $exec_retry -lt $max_exec_retries ]]; then
                log_info "Waiting 3 seconds before retry..."
                sleep 3
                continue
            else
                log_error "Failed after $max_exec_retries attempts to fix exit code 126"
                # Save full diagnostic info
                ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "cd ${ztpbootstrap_dir} && ls -la setup-interactive.sh && file setup-interactive.sh && head -1 setup-interactive.sh" \
                    > "${test_dir}/final-diagnosis.log" 2>&1 || true
                break
            fi
        else
            # Not exit code 126, break out of retry loop
            break
        fi
    done
    
    # Check exit code
    if [[ $exit_code -eq $expected_exit ]]; then
        if [[ $expected_exit -eq 0 ]]; then
            log_info "✓ Test exit code matches expected (success: $expected_exit)"
        else
            log_info "✓ Test exit code matches expected (expected failure: $expected_exit) - PASSED"
        fi
        echo "PASSED: Exit code $exit_code (expected $expected_exit)" > "${test_dir}/result.txt"
        
        # Run verification checks if test passed
        verify_test "$test_config" "$test_dir" || {
            echo "FAILED: Verification checks failed" >> "${test_dir}/result.txt"
            return 1
        }
        
        return 0
    else
        log_error "✗ Test exit code mismatch: got $exit_code, expected $expected_exit"
        if [[ $exit_code -eq 126 ]]; then
            log_error "Command execution failed (exit code 126) - see ${test_dir}/output.log and ${test_dir}/final-diagnosis.log for details"
        fi
        echo "FAILED: Exit code $exit_code (expected $expected_exit)" > "${test_dir}/result.txt"
        return 1
    fi
}

# Verify test results
verify_test() {
    local test_config="$1"
    local test_dir="$2"
    
    local verify_checks=$(echo "$test_config" | yq '.verify[]?' 2>/dev/null || echo "")
    if [[ -z "$verify_checks" ]] || [[ "$verify_checks" == "null" ]]; then
        return 0  # No verification needed
    fi
    
    log_info "Running verification checks..."
    local all_passed=true
    
    while IFS= read -r check; do
        if [[ -z "$check" ]] || [[ "$check" == "null" ]]; then
            continue
        fi
        
        local check_type=$(echo "$check" | yq -r 'keys[0]' 2>/dev/null || echo "")
        local check_value=$(echo "$check" | yq -r '.[keys[0]]' 2>/dev/null || echo "")
        
        if [[ -z "$check_type" ]] || [[ -z "$check_value" ]]; then
            continue
        fi
        
        case "$check_type" in
            service_running)
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "sudo systemctl is-active --quiet ${check_value}" 2>/dev/null; then
                    log_info "  ✓ Service $check_value is running"
                else
                    log_error "  ✗ Service $check_value is not running"
                    all_passed=false
                fi
                ;;
            file_exists)
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "test -f ${check_value}" 2>/dev/null; then
                    log_info "  ✓ File $check_value exists"
                else
                    log_error "  ✗ File $check_value does not exist"
                    all_passed=false
                fi
                ;;
            config_contains)
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "grep -q '${check_value}' /opt/containerdata/ztpbootstrap/ztpbootstrap.env 2>/dev/null" 2>/dev/null; then
                    log_info "  ✓ Config contains: $check_value"
                else
                    log_error "  ✗ Config does not contain: $check_value"
                    all_passed=false
                fi
                ;;
            backup_exists)
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "test -d /opt/containerdata/ztpbootstrap-backup-* 2>/dev/null || ls /tmp/ztpbootstrap-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null; then
                    log_info "  ✓ Backup exists"
                else
                    log_error "  ✗ Backup does not exist"
                    all_passed=false
                fi
                ;;
            password_reset)
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "grep -q 'admin_password_hash' /opt/containerdata/ztpbootstrap/config.yaml 2>/dev/null && grep -vq 'admin_password_hash: \"\"' /opt/containerdata/ztpbootstrap/config.yaml 2>/dev/null" 2>/dev/null; then
                    log_info "  ✓ Password was set/reset"
                else
                    log_error "  ✗ Password was not set/reset"
                    all_passed=false
                fi
                ;;
            network_type)
                if [[ "$check_value" == "host" ]]; then
                    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                        "grep -q 'Network=host' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod 2>/dev/null || grep -q 'Network=host' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container 2>/dev/null" 2>/dev/null; then
                        log_info "  ✓ Network type is host"
                    else
                        log_error "  ✗ Network type is not host"
                        all_passed=false
                    fi
                elif [[ "$check_value" == "macvlan" ]]; then
                    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                        "grep -q 'Network=ztpbootstrap-net' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod 2>/dev/null || grep -q 'Network=ztpbootstrap-net' /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container 2>/dev/null" 2>/dev/null; then
                        log_info "  ✓ Network type is macvlan"
                    else
                        log_error "  ✗ Network type is not macvlan"
                        all_passed=false
                    fi
                fi
                ;;
            config_preserved)
                # Check that key config values were preserved during upgrade
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "${SSH_USER}@localhost" \
                    "test -f /opt/containerdata/ztpbootstrap/ztpbootstrap.env && test -f /opt/containerdata/ztpbootstrap/config.yaml" 2>/dev/null; then
                    log_info "  ✓ Config files preserved"
                else
                    log_error "  ✗ Config files not preserved"
                    all_passed=false
                fi
                ;;
            error_message)
                # Check that error message appears in output
                if grep -qi "${check_value}" "${test_dir}/output.log" 2>/dev/null; then
                    log_info "  ✓ Error message found: $check_value"
                else
                    log_error "  ✗ Error message not found: $check_value"
                    all_passed=false
                fi
                ;;
            *)
                log_warn "  Unknown verification check: $check_type"
                ;;
        esac
    done < <(echo "$verify_checks" | yq '.[]')
    
    if [[ "$all_passed" == "true" ]]; then
        log_info "✓ All verification checks passed"
        return 0
    else
        log_error "✗ Some verification checks failed"
        return 1
    fi
}

# Main test loop
main() {
    log_info "Starting automated testing iteration"
    log_info "Distribution: $DISTRO $VERSION"
    log_info "Test matrix: $TEST_MATRIX"
    log_info "Max iterations: $MAX_ITERATIONS"
    log_info "Report directory: $REPORT_DIR"
    echo ""
    
    # Parse test matrix
    local test_count=$(yq -r '.tests | length' "$TEST_MATRIX")
    log_info "Found $test_count tests in matrix"
    echo ""
    
    CURRENT_ITERATION=0
    
    while [[ $CURRENT_ITERATION -lt $MAX_ITERATIONS ]]; do
        CURRENT_ITERATION=$((CURRENT_ITERATION + 1))
        log_info "=========================================="
        log_info "Iteration $CURRENT_ITERATION of $MAX_ITERATIONS"
        log_info "=========================================="
        echo ""
        
        # Create/reset VM
        create_vm || {
            log_error "Failed to create VM"
            exit 1
        }
        
        # Run all tests
        local iteration_passed=true
        local test_index=0
        
        while [[ $test_index -lt $test_count ]]; do
            local test_name=$(yq -r ".tests[${test_index}].name" "$TEST_MATRIX")
            local test_config=$(yq ".tests[${test_index}]" "$TEST_MATRIX")
            
            TOTAL_TESTS=$((TOTAL_TESTS + 1))
            
            if run_test "$test_name" "$test_config" "$CURRENT_ITERATION"; then
                PASSED_TESTS=$((PASSED_TESTS + 1))
                log_info "✓ Test passed: $test_name"
            else
                FAILED_TESTS=$((FAILED_TESTS + 1))
                log_error "✗ Test failed: $test_name"
                iteration_passed=false
            fi
            
            echo ""
            test_index=$((test_index + 1))
        done
        
        # Check if all tests passed
        if [[ "$iteration_passed" == "true" ]]; then
            log_info "=========================================="
            log_info "✓ All tests passed in iteration $CURRENT_ITERATION!"
            log_info "=========================================="
            break
        else
            log_warn "Some tests failed in iteration $CURRENT_ITERATION"
            
            if [[ "$KEEP_ON_FAILURE" == "true" ]]; then
                log_info "Keeping VM for debugging (--keep-on-failure enabled)"
                log_info "VM is accessible at: ssh -p $SSH_PORT ${SSH_USER}@localhost"
                break
            fi
            
            if [[ $CURRENT_ITERATION -lt $MAX_ITERATIONS ]]; then
                log_info "Wiping VM and starting new iteration..."
                pkill -f "qemu-system.*${VM_NAME}" 2>/dev/null || true
                sleep 2
            fi
        fi
    done
    
    # Final summary
    echo ""
    log_info "=========================================="
    log_info "Test Summary"
    log_info "=========================================="
    log_info "Total tests run: $TOTAL_TESTS"
    log_info "Passed: $PASSED_TESTS"
    log_info "Failed: $FAILED_TESTS"
    log_info "Iterations: $CURRENT_ITERATION"
    log_info "Report directory: $REPORT_DIR"
    echo ""
    
    if [[ $FAILED_TESTS -eq 0 ]]; then
        log_info "✓ All tests passed!"
        exit 0
    else
        log_error "✗ Some tests failed"
        exit 1
    fi
}

# Run main function
main
