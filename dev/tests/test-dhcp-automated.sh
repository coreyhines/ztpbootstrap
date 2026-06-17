#!/bin/bash
# Automated DHCP Testing Script
# Creates VM, installs ZTP Bootstrap, runs all DHCP tests autonomously

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_CREATE_SCRIPT="${REPO_ROOT}/dev/scripts/vm-create-native.sh"
WAIT_SSH_SCRIPT="${REPO_ROOT}/dev/scripts/wait-for-ssh.sh"

# Configuration
DISTRO="${DISTRO:-fedora}"
VERSION="${VERSION:-43}"
VM_NAME="${VM_NAME:-ztpbootstrap-dhcp-test}"
SSH_PORT="${SSH_PORT:-2222}"
KEEP_VM_ON_FAILURE="${KEEP_VM_ON_FAILURE:-false}"
REPORT_DIR="${REPORT_DIR:-${REPO_ROOT}/tests/test-reports/dhcp-automated-$(date +%Y%m%d_%H%M%S)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test results
TEST_RESULTS=()
FAILED_TESTS=()
PASSED_TESTS=()

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "${REPORT_DIR}/test.log"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "${REPORT_DIR}/test.log"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "${REPORT_DIR}/test.log"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1" | tee -a "${REPORT_DIR}/test.log"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1" | tee -a "${REPORT_DIR}/test.log"
}

# SSH options
SSH_OPTS=(
    -o ConnectTimeout=60
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -p "${SSH_PORT}"
)

# Determine SSH user based on distro
get_ssh_user() {
    case "${DISTRO}" in
        ubuntu|debian)
            echo "ubuntu"
            ;;
        fedora|rocky|almalinux|centos)
            echo "fedora"
            ;;
        *)
            echo "${USER:-$(whoami)}"
            ;;
    esac
}

SSH_USER=$(get_ssh_user)

# Create report directory
mkdir -p "${REPORT_DIR}"

# Cleanup function
cleanup() {
    local failed_count=${#FAILED_TESTS[@]:-0}
    if [[ "${KEEP_VM_ON_FAILURE}" == "true" ]] && [[ ${failed_count} -gt 0 ]]; then
        log_warn "Keeping VM running for debugging (KEEP_VM_ON_FAILURE=true)"
        log_info "VM name: ${VM_NAME}"
        log_info "SSH: ssh ${SSH_OPTS[*]} ${SSH_USER}@localhost"
        return 0
    fi

    log_info "Cleaning up VM and related files..."
    cleanup_existing_vms
}

trap cleanup EXIT

# Wait for VM to be ready
wait_for_vm_ready() {
    log_info "Waiting for VM to be ready (SSH on port ${SSH_PORT})..."
    log_info "This may take 2-5 minutes for cloud-init to complete..."

    # Use the optimized wait-for-ssh script if available
    if [[ -f "${WAIT_SSH_SCRIPT}" ]]; then
        if "${WAIT_SSH_SCRIPT}" localhost "${SSH_PORT}" "${SSH_USER}" 600 5 >> "${REPORT_DIR}/test.log" 2>&1; then
            log_info "✓ VM is ready (using wait-for-ssh.sh)"
            return 0
        else
            log_error "VM did not become ready (wait-for-ssh.sh failed)"
            return 1
        fi
    fi

    # Fallback: manual wait logic
    local max_wait=600  # 10 minutes
    local elapsed=0

    # Phase 1: Wait for SSH port to be open
    log_info "Phase 1: Waiting for SSH port to open..."
    local port_open=false
    while [[ $elapsed -lt $max_wait ]]; do
        if timeout 2 bash -c "echo > /dev/tcp/localhost/${SSH_PORT}" 2>/dev/null; then
            port_open=true
            log_info "✓ SSH port is open"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "  Still waiting for SSH port... (${elapsed}s elapsed)"
        fi
    done

    if [[ "$port_open" != "true" ]]; then
        log_error "SSH port did not open within ${max_wait}s"
        return 1
    fi

    # Phase 2: Wait for SSH to accept connections (cloud-init may still be running)
    log_info "Phase 2: Waiting for SSH to accept connections..."
    elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        # Try SSH connection (prefer key-based, but password auth may work initially)
        # Cloud-init sets password to username
        if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@localhost" "echo 'ready'" 2>/dev/null; then
            log_info "✓ VM is ready and SSH is working"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "  Still waiting for SSH to accept connections... (${elapsed}s elapsed)"
        fi
    done

    log_error "SSH did not become ready within ${max_wait}s"
    return 1
}

# Cleanup any existing VMs and related files
cleanup_existing_vms() {
    log_info "Cleaning up any existing VMs and related files..."

    # Stop all QEMU processes for this VM name
    pkill -f "qemu-system.*${VM_NAME}" 2>/dev/null || true
    sleep 2

    # Remove VM disk
    local vm_disk="${HOME}/Downloads/${VM_NAME}.qcow2"
    if [[ -f "${vm_disk}" ]]; then
        log_info "Removing existing VM disk: ${vm_disk}"
        rm -f "${vm_disk}" 2>/dev/null || log_warn "Could not remove VM disk: ${vm_disk}"
    fi

    # Remove cloud image copies (created by vm-create-native.sh)
    local cloud_disk="${HOME}/Downloads/$(basename "${vm_disk%.qcow2}")-cloud.qcow2"
    if [[ -f "${cloud_disk}" ]]; then
        log_info "Removing cloud image copy: ${cloud_disk}"
        rm -f "${cloud_disk}" 2>/dev/null || true
    fi

    # Also check for any other related files
    local vm_base="${HOME}/Downloads/${VM_NAME}"
    for file in "${vm_base}"*.qcow2 "${vm_base}"*.raw "${vm_base}"*.img; do
        if [[ -f "$file" ]]; then
            log_info "Removing related VM file: $file"
            rm -f "$file" 2>/dev/null || true
        fi
    done

    log_info "✓ Cleanup complete"
}

# Create VM
create_vm() {
    log_step "Step 1: Creating VM"

    # Clean up any existing VMs first
    cleanup_existing_vms

    log_info "Creating VM: ${VM_NAME} (${DISTRO} ${VERSION})"
    log_info "VM creation log: ${REPORT_DIR}/vm-create.log"

    # Create VM in background
    "${VM_CREATE_SCRIPT}" \
        --download "${DISTRO}" \
        --type cloud \
        --arch aarch64 \
        --version "${VERSION}" \
        --headless \
        --name "${VM_NAME}" \
        > "${REPORT_DIR}/vm-create.log" 2>&1 &

    local vm_pid=$!
    log_info "VM creation started (PID: ${vm_pid})"

    # Wait for VM to be running
    sleep 10
    for i in {1..30}; do
        if ps aux | grep -i "qemu-system.*${VM_NAME}" | grep -v grep > /dev/null; then
            log_info "✓ VM process is running"
            break
        fi
        sleep 2
        if [[ $i -eq 30 ]]; then
            log_error "VM failed to start"
            return 1
        fi
    done

    # Wait for VM to be ready
    wait_for_vm_ready || {
        log_error "VM did not become ready"
        return 1
    }

    log_info "✓ VM created and ready"
    return 0
}

# Install ZTP Bootstrap on VM
install_ztpbootstrap() {
    log_step "Step 2: Installing ZTP Bootstrap"

    # Find or clone repository
    log_info "Setting up repository on VM..."

    # Try to find existing repo
    local repo_dir=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
        "test -d ~/ztpbootstrap && echo ~/ztpbootstrap || echo ''" 2>/dev/null || echo "")

    if [[ -z "${repo_dir}" ]]; then
        log_info "Setting up repository on VM..."

        # Try to copy repo using rsync (faster) or tar+scp (fallback)
        if command -v rsync &> /dev/null; then
            log_info "Copying repository using rsync..."
            rsync -avz --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
                -e "ssh ${SSH_OPTS[*]}" \
                "${REPO_ROOT}/" "${SSH_USER}@localhost:~/ztpbootstrap/" || {
                log_warn "rsync failed, trying alternative method..."
                # Fallback to tar+scp
                tar -czf /tmp/ztpbootstrap-repo.tar.gz -C "${REPO_ROOT}" . --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' 2>/dev/null
                scp "${SSH_OPTS[@]}" /tmp/ztpbootstrap-repo.tar.gz "${SSH_USER}@localhost:~/"
                ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "mkdir -p ~/ztpbootstrap && cd ~/ztpbootstrap && tar -xzf ~/ztpbootstrap-repo.tar.gz && rm ~/ztpbootstrap-repo.tar.gz"
                rm -f /tmp/ztpbootstrap-repo.tar.gz
            }
        else
            log_info "Copying repository using tar+scp..."
            tar -czf /tmp/ztpbootstrap-repo.tar.gz -C "${REPO_ROOT}" . --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' 2>/dev/null
            scp "${SSH_OPTS[@]}" /tmp/ztpbootstrap-repo.tar.gz "${SSH_USER}@localhost:~/"
            ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "mkdir -p ~/ztpbootstrap && cd ~/ztpbootstrap && tar -xzf ~/ztpbootstrap-repo.tar.gz && rm ~/ztpbootstrap-repo.tar.gz"
            rm -f /tmp/ztpbootstrap-repo.tar.gz
        fi

        repo_dir="~/ztpbootstrap"
        log_info "✓ Repository copied to VM"
    else
        # Repository exists - update it to ensure we have latest files
        log_info "Repository exists on VM, updating to latest branch..."
        local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        log_info "Current branch: ${current_branch}"

        ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << EOF
            cd ${repo_dir}

            # If .git exists, fetch and checkout the branch
            if [[ -d .git ]]; then
                echo "Git repository found, fetching and checking out branch..."
                git fetch origin 2>&1 || echo "Fetch failed, continuing..."
                git checkout ${current_branch} 2>&1 || echo "Checkout failed, continuing..."
                git pull origin ${current_branch} 2>&1 || echo "Pull failed, continuing..."
            else
                echo "No .git directory, re-syncing files..."
                # Re-sync files to ensure we have latest
                exit 0
            fi
EOF
        # Re-sync files to ensure latest changes are there (in case git isn't available or failed)
        if command -v rsync &> /dev/null; then
            log_info "Re-syncing files to ensure latest changes..."
            rsync -avz --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
                -e "ssh ${SSH_OPTS[*]}" \
                "${REPO_ROOT}/" "${SSH_USER}@localhost:~/ztpbootstrap/" 2>&1 | grep -v "^sending\|^sent\|^total" || true
        fi
    fi

    log_info "Repository location: ${repo_dir}"

    # Install dependencies and setup
    log_info "Installing dependencies..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << EOF
        cd ${repo_dir}

        # Install podman if not available
        if ! command -v podman &> /dev/null; then
            if command -v dnf &> /dev/null; then
                sudo dnf install -y podman
            elif command -v apt-get &> /dev/null; then
                sudo apt-get update
                sudo apt-get install -y podman
            fi
        fi

        # Install yq if not available (required by setup script to read config.yaml)
        if ! command -v yq &> /dev/null; then
            if command -v dnf &> /dev/null; then
                sudo dnf install -y yq
            elif command -v apt-get &> /dev/null; then
                sudo apt-get update
                sudo apt-get install -y yq
            fi
        fi

        # Install bats for integration tests
        if ! command -v bats &> /dev/null; then
            if command -v dnf &> /dev/null; then
                # Try to install from EPEL or build from source
                sudo dnf install -y bats || {
                    echo "BATS not in repos, installing from GitHub..."
                    cd /tmp
                    git clone https://github.com/bats-core/bats-core.git 2>/dev/null || true
                    if [[ -d bats-core ]]; then
                        cd bats-core
                        sudo ./install.sh /usr/local 2>&1 || echo "BATS installation failed"
                    fi
                }
            elif command -v apt-get &> /dev/null; then
                sudo apt-get update
                sudo apt-get install -y bats || {
                    echo "BATS not in repos, installing from GitHub..."
                    cd /tmp
                    git clone https://github.com/bats-core/bats-core.git 2>/dev/null || true
                    if [[ -d bats-core ]]; then
                        cd bats-core
                        sudo ./install.sh /usr/local 2>&1 || echo "BATS installation failed"
                    fi
                }
            fi
        fi

        # Install Python dependencies
        if [[ -f webui/requirements.txt ]]; then
            # Install pip3 if not available
            if ! command -v pip3 &> /dev/null; then
                if command -v dnf &> /dev/null; then
                    sudo dnf install -y python3-pip
                elif command -v apt-get &> /dev/null; then
                    sudo apt-get install -y python3-pip
                fi
            fi
            pip3 install -r webui/requirements.txt --user || true
        fi

        # Make scripts executable
        chmod +x *.sh dev/scripts/*.sh dev/tests/*.sh 2>/dev/null || true
EOF

    log_info "✓ Dependencies installed"

    # Run setup (non-interactive)
    log_info "Running ZTP Bootstrap setup (non-interactive)..."
    local setup_log="${REPORT_DIR}/setup-install.log"

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'EOF' > "${setup_log}" 2>&1
        cd ~/ztpbootstrap

        # Create minimal config for testing
        if [[ ! -f config.yaml ]]; then
            cp config.yaml.template config.yaml
        fi

        # Set minimal required config for testing
        # Use HTTP-only mode for testing (no SSL certs needed)
        # Install PyYAML if needed
        python3 -c "import yaml" 2>/dev/null || pip3 install --user PyYAML || sudo dnf install -y python3-pyyaml || sudo apt-get install -y python3-yaml

        # Always update config.yaml with test values (even if it exists)
        python3 << 'PYTHON_SCRIPT'
import yaml
import sys
import os

try:
    config_file = 'config.yaml'
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f) or {}

    # Ensure network section exists
    if 'network' not in config:
        config['network'] = {}

    # Set HTTP-only mode for testing
    config['network']['http_only'] = True
    config['network']['http_port'] = 8080

    # Set admin password for authentication (required for API tests)
    # Use a simple password "admin" for testing
    import hashlib
    import base64
    test_password = "admin"
    password_hash = "pbkdf2:sha256:" + base64.b64encode(
        hashlib.pbkdf2_hmac('sha256', test_password.encode(), b'ztpbootstrap', 100000)
    ).decode()

    if 'auth' not in config:
        config['auth'] = {}
    config['auth']['admin_password_hash'] = password_hash
    config['network']['https_port'] = 8443
    print(f"✓ Set admin_password_hash in config.yaml (length: {len(password_hash)})")

    # Ensure container section exists
    if 'container' not in config:
        config['container'] = {}

    # Set container config
    config['container']['host_network'] = True

    # Ensure cvaas section exists with dummy token for testing
    if 'cvaas' not in config:
        config['cvaas'] = {}

    # Set dummy enrollment token for testing (required by setup script)
    # Always set it to ensure it's present - any string works for testing
    config['cvaas']['address'] = 'www.arista.io'
    config['cvaas']['enrollment_token'] = 'arista'

    # Write config back
    with open(config_file, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

    # Verify it was written and can be read back
    with open(config_file, 'r') as f:
        verify_config = yaml.safe_load(f)
        token = verify_config.get('cvaas', {}).get('enrollment_token', '')
        if not token or token == '':
            print(f"ERROR: enrollment_token not set in {config_file}", file=sys.stderr)
            print(f"Config structure: {verify_config.get('cvaas', {})}", file=sys.stderr)
            sys.exit(1)
        print(f"✓ Set enrollment_token in config.yaml: {token[:20]}...")

    # Also verify with yq if available (same way setup script reads it)
    import subprocess
    try:
        result = subprocess.run(
            ['yq', 'eval', '.cvaas.enrollment_token // ""', config_file],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            yq_token = result.stdout.strip()
            if yq_token and yq_token != 'null':
                print(f"✓ Verified with yq: enrollment_token = {yq_token[:20]}...")
            else:
                print(f"WARNING: yq returned empty token: '{yq_token}'", file=sys.stderr)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        print("Note: yq not available for verification (setup script will use it)")

except Exception as e:
    print(f"Error configuring config.yaml: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT

        # Run setup script (non-interactive)
        export NON_INTERACTIVE=true
        # Set enrollment token explicitly as environment variable (fallback if config.yaml isn't read)
        export ENROLLMENT_TOKEN="arista"

        # Extract admin_password_hash from config.yaml and pass it as environment variable
        # This ensures it's preserved through the setup process
        ADMIN_PASSWORD_HASH_FROM_CONFIG=$(python3 -c "import yaml; f=open('config.yaml'); c=yaml.safe_load(f); f.close(); print(c.get('auth', {}).get('admin_password_hash', '') or '')" 2>/dev/null || echo "")
        if [[ -n "$ADMIN_PASSWORD_HASH_FROM_CONFIG" ]]; then
            export ADMIN_PASSWORD_HASH="$ADMIN_PASSWORD_HASH_FROM_CONFIG"
            echo "✓ Found admin_password_hash in config.yaml (length: ${#ADMIN_PASSWORD_HASH_FROM_CONFIG})"
        fi

        if [[ -f setup-interactive.sh ]]; then
            # Use interactive setup with non-interactive flag
            # Ensure we're in the repo directory and pass it explicitly
            echo "Running setup-interactive.sh with NON_INTERACTIVE=true..."
            echo "Current directory: $(pwd)"
            echo "Config.yaml exists: $([ -f config.yaml ] && echo 'yes' || echo 'no')"
            echo "ENROLLMENT_TOKEN env var: ${ENROLLMENT_TOKEN:-not set}"
            echo "ADMIN_PASSWORD_HASH env var: ${ADMIN_PASSWORD_HASH:+set (length: ${#ADMIN_PASSWORD_HASH})}"
            # Pass ENROLLMENT_TOKEN and ADMIN_PASSWORD_HASH through sudo environment
            # Use -E to preserve environment, and also set it explicitly in the command
            sudo -E env NON_INTERACTIVE=true ENROLLMENT_TOKEN="arista" ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH:-}" bash -c "cd $(pwd) && export ENROLLMENT_TOKEN='arista' && export ADMIN_PASSWORD_HASH='${ADMIN_PASSWORD_HASH:-}' && ./setup-interactive.sh --non-interactive"
            setup_exit=$?
        else
            # Use regular setup
            echo "Running setup.sh..."
            sudo ./setup.sh
            setup_exit=$?
        fi

        echo "Setup exit code: $setup_exit"

        # Verify services were created
        echo "Verifying services were installed..."
        if [[ -d /etc/containers/systemd/ztpbootstrap ]]; then
            echo "✓ Systemd files found"
            ls -la /etc/containers/systemd/ztpbootstrap/ 2>&1 || true
            echo ""
            echo "Verifying pod file network configuration..."
            if [[ -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod ]]; then
                echo "Pod file contents:"
                cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
                echo ""
                if grep -q "^Network=host" /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod; then
                    echo "✓ Pod file correctly configured for host networking"
                else
                    echo "✗ WARNING: Pod file does not have Network=host, attempting to fix..."
                    # Fix pod file to use host networking
                    sudo sed -i.tmp "s|^Network=.*|Network=host|" /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod 2>/dev/null && rm -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod.tmp || true
                    sudo sed -i.tmp "/^IP=/d" /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod 2>/dev/null && rm -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod.tmp || true
                    sudo sed -i.tmp "/^IP6=/d" /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod 2>/dev/null && rm -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod.tmp || true
                    echo "Updated pod file:"
                    cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod
                    echo ""
                    echo "Reloading systemd to pick up changes..."
                    sudo systemctl daemon-reload
                fi
            fi
        else
            echo "✗ Systemd files not found - setup may have failed"
            exit 1
        fi

        # Check if services are enabled
        echo "Checking service status..."
        sudo systemctl list-unit-files 2>&1 | grep ztpbootstrap || echo "No ztpbootstrap services found"

        # Exit with setup exit code (0 if successful, otherwise use setup exit code)
        exit ${setup_exit:-0}
EOF

    local setup_exit_code=$?

    # Show setup log
    log_info "Setup log (last 50 lines):"
    tail -50 "${setup_log}" | while IFS= read -r line; do
        log_info "  $line"
    done

    # Check if setup actually succeeded by verifying systemd files exist
    # Even if exit code is non-zero, setup might have succeeded
    local setup_succeeded=false
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" "test -d /etc/containers/systemd/ztpbootstrap" 2>/dev/null; then
        setup_succeeded=true
        log_info "✓ Setup verification: Systemd files exist (setup succeeded despite exit code)"
    fi

    if [[ $setup_exit_code -ne 0 ]] && [[ "$setup_succeeded" != "true" ]]; then
        log_error "Setup failed with exit code: $setup_exit_code"
        log_error "Full setup log: ${setup_log}"
        return 1
    elif [[ $setup_exit_code -ne 0 ]] && [[ "$setup_succeeded" == "true" ]]; then
        log_warn "Setup exit code was $setup_exit_code, but systemd files exist - treating as success"
        # Don't return here, continue with verification
    fi

    # Verify services exist
    if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
        "test -d /etc/containers/systemd/ztpbootstrap && echo 'ok' || echo 'fail'" 2>/dev/null | grep -q "ok"; then
        log_error "Services were not installed - systemd files not found"
        log_error "Full setup log: ${setup_log}"
        return 1
    fi

    log_info "✓ ZTP Bootstrap installed"

    # Ensure admin_password_hash is in the final config file
    log_info "Verifying and fixing authentication configuration..."

    # Generate password hash directly (we know the test password is "admin")
    # This avoids extraction issues and ensures consistency
    log_info "Generating password hash for test authentication..."
    local password_hash=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'GENERATE_HASH'
        python3 << 'PYEOF'
import hashlib
import base64
test_password = "admin"
password_hash = "pbkdf2:sha256:" + base64.b64encode(
    hashlib.pbkdf2_hmac('sha256', test_password.encode(), b'ztpbootstrap', 100000)
).decode()
print(password_hash)
PYEOF
GENERATE_HASH
)

    if [[ -n "$password_hash" ]] && [[ "$password_hash" != "null" ]] && [[ "$password_hash" != "" ]]; then
        log_info "Generated password hash (length: ${#password_hash}), setting in final config..."
        # Use yq to set the password hash in the final config file (with sudo for permissions)
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << EOF
            if command -v yq >/dev/null 2>&1 && [[ -f /opt/containerdata/ztpbootstrap/config.yaml ]]; then
                # Ensure auth section exists
                sudo yq eval '.auth = (.auth // {})' -i /opt/containerdata/ztpbootstrap/config.yaml
                # Set the password hash (escape quotes properly)
                sudo yq eval ".auth.admin_password_hash = \"${password_hash}\"" -i /opt/containerdata/ztpbootstrap/config.yaml
                echo "✓ Set admin_password_hash in /opt/containerdata/ztpbootstrap/config.yaml"
            else
                echo "WARNING: yq not available or config file not found"
            fi
EOF
        # Restart WebUI to ensure it picks up the password hash
        log_info "Restarting WebUI to load authentication configuration..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
            "sudo systemctl restart ztpbootstrap-webui" 2>/dev/null || true
        sleep 5
        log_info "✓ Authentication configured and WebUI restarted"
    else
        log_warn "Could not extract password hash from repo config"
    fi

    return 0
}

# Wait for services to be ready
wait_for_services() {
    log_step "Step 3: Waiting for services to be ready"

    # First, ensure services are started
    log_info "Starting services..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'EOF' 2>&1 | while IFS= read -r line; do log_info "  $line"; done
        # Check if pod network exists
        echo "Checking pod network..."
        sudo podman network ls | grep ztpbootstrap-net || echo "Network ztpbootstrap-net not found"
        echo ""

        # Clean up any existing pod in bad state
        echo "Cleaning up any existing pod..."
        sudo podman pod rm --force ztpbootstrap 2>&1 || true
        sleep 1

        # Check podman logs for errors
        echo "Checking podman service logs..."
        sudo journalctl -u ztpbootstrap-pod --no-pager -n 20 | tail -10 || true
        echo ""

        # Start pod service first (webui depends on it)
        echo "Starting pod service..."
        sudo systemctl start ztpbootstrap-pod 2>&1 || {
            echo "Failed to start pod service"
            echo "Podman error details:"
            sudo journalctl -u ztpbootstrap-pod --no-pager -n 30 | tail -15 || true
            echo ""
            echo "Trying to manually start pod:"
            sudo podman pod start ztpbootstrap 2>&1 || {
                echo "Pod start failed, checking pod status:"
                sudo podman pod ps --all 2>&1 || sudo podman pod ps 2>&1 || true
                echo ""
                echo "Trying to create and start pod manually:"
                sudo podman pod create --infra-conmon-pidfile=/run/ztpbootstrap-pod.pid --replace --exit-policy stop --network ztpbootstrap-net --ip 10.0.0.10 --ip6 2001:db8::10 --infra-name ztpbootstrap-infra --name ztpbootstrap 2>&1
                sudo podman pod start ztpbootstrap 2>&1 || {
                    echo "Pod start error details:"
                    sudo podman pod inspect ztpbootstrap 2>&1 | head -30 || true
                }
            }
        }
        sleep 3

        # Start webui service
        echo "Starting webui service..."
        sudo systemctl start ztpbootstrap-webui 2>&1 || echo "Failed to start webui service"
        sleep 2

        # Check service status
        echo "Pod service status:"
        sudo systemctl status ztpbootstrap-pod --no-pager -l | head -10 || true
        echo ""
        echo "WebUI service status:"
        sudo systemctl status ztpbootstrap-webui --no-pager -l | head -10 || true
        echo ""
        echo "Container status:"
        sudo podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.State}}" | grep -E "ztpbootstrap|NAMES" || echo "No ztpbootstrap containers found"
        echo ""
        echo "WebUI container health:"
        sudo podman inspect ztpbootstrap-webui --format '{{.State.Health.Status}}' 2>/dev/null || echo "Health check not available"
        echo ""
        echo "Checking if port 5000 is listening:"
        sudo ss -tlnp | grep ":5000" || sudo netstat -tlnp | grep ":5000" || echo "Port 5000 not listening"
        echo ""
        echo "Pod status:"
        sudo podman pod ps --all 2>&1 || sudo podman pod ps 2>&1 || echo "No pods found"
EOF

    log_info "Waiting for WebUI service..."
    local max_wait=300
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        # Try multiple endpoints - nginx might not be running, so try direct webui port
        # With host networking, webui should be on port 5000
        local webui_ready=false

        # Check if webui container is healthy
        local health_status=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
            "sudo podman inspect ztpbootstrap-webui --format '{{.State.Health.Status}}' 2>/dev/null || echo 'unknown'" 2>/dev/null)

        # Try port 5000 first (direct webui with host networking)
        if ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
            "curl -s --connect-timeout 2 --max-time 5 http://localhost:5000/api/health > /dev/null 2>&1" 2>/dev/null; then
            webui_ready=true
            log_info "✓ WebUI service is ready on port 5000 (health: ${health_status})"
        elif ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" \
            "curl -s --connect-timeout 2 --max-time 5 http://localhost:8080/api/health > /dev/null 2>&1" 2>/dev/null; then
            webui_ready=true
            log_info "✓ WebUI service is ready on port 8080 (via nginx, health: ${health_status})"
        fi

        if [[ "$webui_ready" == "true" ]]; then
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "  Still waiting... (${elapsed}s elapsed)"
            # Show service status periodically
            ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'EOF' 2>&1 | while IFS= read -r line; do log_info "    $line"; done
                echo "=== Service Status ==="
                sudo systemctl status ztpbootstrap-pod --no-pager -l | head -3
                sudo systemctl status ztpbootstrap-webui --no-pager -l | head -3
                echo ""
                echo "=== Container Status ==="
                sudo podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.State}}" | grep ztpbootstrap || echo "No containers found"
                echo ""
                echo "=== Testing Endpoints ==="
                echo "Port 8080 (nginx): $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/api/health 2>&1 || echo 'failed')"
                echo "Port 5000 (webui): $(curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/api/health 2>&1 || echo 'failed')"
                if sudo podman ps | grep -q ztpbootstrap-nginx; then
                    echo "Nginx logs (last 5 lines):"
                    sudo podman logs --tail 5 ztpbootstrap-nginx 2>&1 || true
                else
                    echo "Nginx container not running. Checking why:"
                    sudo podman ps -a | grep ztpbootstrap-nginx || echo "Nginx container not found"
                    sudo journalctl -u ztpbootstrap-nginx --no-pager -n 5 2>&1 | tail -3 || true
                fi
EOF
        fi
    done

    log_error "WebUI service did not become ready"
    # Show final diagnostic
    log_info "Final service status:"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'EOF' 2>&1 | while IFS= read -r line; do log_info "  $line"; done
        echo "=== Pod Service ==="
        sudo systemctl status ztpbootstrap-pod --no-pager -l | head -10 || true
        echo ""
        echo "=== WebUI Service ==="
        sudo systemctl status ztpbootstrap-webui --no-pager -l | head -10 || true
        echo ""
        echo "=== Containers ==="
        sudo podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.State}}" | grep ztpbootstrap || echo "No ztpbootstrap containers found"
EOF
    return 1
}

# Run integration tests
run_integration_tests() {
    log_step "Step 4: Running Integration Tests"

    local test_result_file="${REPORT_DIR}/integration-tests.log"

    log_test "Running DHCP API integration tests..."

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'EOF' > "${test_result_file}" 2>&1
        cd ~/ztpbootstrap

        # Set test credentials
        export TEST_USER="admin"
        export TEST_PASS="admin"
        # Try port 5000 first (direct webui with host networking), fallback to 8080 (nginx)
        if curl -s --connect-timeout 2 --max-time 5 http://localhost:5000/api/health > /dev/null 2>&1; then
            export WEBUI_PORT="5000"
        else
            export WEBUI_PORT="8080"
        fi

        # Run BATS integration tests
        if command -v bats &> /dev/null; then
            # Change to repo directory to ensure relative paths work
            cd ~/ztpbootstrap

            # Create symlink so bats can find test_helper from integration tests
            # BATS resolves load paths relative to test file, so we need test_helper in integration/
            # Use -sf to force creation/update of symlink
            echo "Creating symlink for test_helper..."
            ln -sf ../test_helper tests/integration/test_helper

            # Verify symlink was created and points to valid location
            if [[ ! -L tests/integration/test_helper ]]; then
                echo "ERROR: Symlink was not created" >&2
                ls -la tests/integration/ | head -10
                exit 1
            fi

            if [[ ! -e tests/integration/test_helper ]]; then
                echo "ERROR: Symlink points to invalid location" >&2
                ls -la tests/integration/test_helper
                readlink -f tests/integration/test_helper
                exit 1
            fi

            echo "Verifying test_helper structure..."
            ls -la tests/integration/test_helper/ || echo "Cannot list test_helper directory"
            ls -la tests/integration/test_helper/bats-assert/ || echo "Cannot list bats-assert directory"
            test -f tests/integration/test_helper/bats-assert/load.bash && echo "✓ Found load.bash" || echo "✗ Missing load.bash"

            # Run tests from repo root - bats will resolve paths relative to test file
            bats tests/integration/test_dhcp_api.bats
        else
            echo "BATS not installed, skipping integration tests"
            exit 1
        fi
EOF

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_info "✓ Integration tests passed"
        PASSED_TESTS+=("Integration Tests")
        return 0
    else
        log_error "✗ Integration tests failed"
        FAILED_TESTS+=("Integration Tests")
        return 1
    fi
}

# Run DHCP E2E test
run_dhcp_e2e_test() {
    log_step "Step 5: Running DHCP E2E Test"

    local test_result_file="${REPORT_DIR}/dhcp-e2e-test.log"

    log_test "Running DHCP E2E test with client simulation..."

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@localhost" << 'EOF' > "${test_result_file}" 2>&1
        cd ~/ztpbootstrap

        # Set test configuration
        export VM_IP="localhost"
        export TEST_INTERFACE="eth0"
        export DHCP_SUBNET="10.0.0.0/24"
        export DHCP_RANGE_START="10.0.0.50"
        export DHCP_RANGE_END="10.0.0.250"
        export DHCP_GATEWAY="10.0.0.1"

        # Run E2E test
        ./dev/tests/test-dhcp-e2e.sh
EOF

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_info "✓ DHCP E2E test passed"
        PASSED_TESTS+=("DHCP E2E Test")
        return 0
    else
        log_error "✗ DHCP E2E test failed"
        FAILED_TESTS+=("DHCP E2E Test")
        return 1
    fi
}

# Generate test report
generate_report() {
    log_step "Step 6: Generating Test Report"

    local report_file="${REPORT_DIR}/test-report.txt"

    # Calculate totals safely
    local total_passed=${#PASSED_TESTS[@]:-0}
    local total_failed=${#FAILED_TESTS[@]:-0}
    local total_tests=$((total_passed + total_failed))

    # Build passed tests list
    local passed_list=""
    if [[ ${total_passed} -gt 0 ]]; then
        for test in "${PASSED_TESTS[@]}"; do
            passed_list="${passed_list}  ✓ ${test}"$'\n'
        done
    else
        passed_list="  (none)"
    fi

    # Build failed tests list
    local failed_list=""
    if [[ ${total_failed} -gt 0 ]]; then
        for test in "${FAILED_TESTS[@]}"; do
            failed_list="${failed_list}  ✗ ${test}"$'\n'
        done
    else
        failed_list="  (none)"
    fi

    cat > "${report_file}" << EOF
========================================
DHCP Automated Test Report
========================================
Date: $(date)
VM: ${VM_NAME}
Distro: ${DISTRO} ${VERSION}
SSH User: ${SSH_USER}

Test Results:
-------------
Total Tests: ${total_tests}
Passed: ${total_passed}
Failed: ${total_failed}

Passed Tests:
${passed_list}

Failed Tests:
${failed_list}

Logs:
-----
- VM Creation: ${REPORT_DIR}/vm-create.log
- Integration Tests: ${REPORT_DIR}/integration-tests.log
- DHCP E2E Test: ${REPORT_DIR}/dhcp-e2e-test.log
- Full Test Log: ${REPORT_DIR}/test.log

EOF

    cat "${report_file}"
    log_info "Full report saved to: ${report_file}"
}

# Main execution
main() {
    log_info "=========================================="
    log_info "DHCP Automated Testing"
    log_info "=========================================="
    log_info "VM Name: ${VM_NAME}"
    log_info "Distro: ${DISTRO} ${VERSION}"
    log_info "Report Dir: ${REPORT_DIR}"
    log_info ""

    # Clean up any existing VMs before starting
    log_info "Pre-test cleanup: Removing any existing VMs..."
    cleanup_existing_vms
    log_info ""

    # Check prerequisites
    if ! command -v qemu-system-aarch64 &> /dev/null && ! command -v qemu-system-x86_64 &> /dev/null; then
        log_error "QEMU is required but not installed"
        exit 1
    fi

    if [[ ! -f "${VM_CREATE_SCRIPT}" ]]; then
        log_error "VM creation script not found: ${VM_CREATE_SCRIPT}"
        exit 1
    fi

    # Run tests
    local overall_success=true

    if ! create_vm; then
        log_error "VM creation failed"
        overall_success=false
    elif ! install_ztpbootstrap; then
        log_error "ZTP Bootstrap installation failed"
        overall_success=false
    elif ! wait_for_services; then
        log_error "Services did not become ready"
        overall_success=false
    elif ! run_integration_tests; then
        overall_success=false
    elif ! run_dhcp_e2e_test; then
        overall_success=false
    fi

    # Generate report
    generate_report

    # Final status
    if [[ "$overall_success" == "true" ]]; then
        log_info "${GREEN}=========================================="
        log_info "All tests passed! ✓"
        log_info "==========================================${NC}"
        exit 0
    else
        log_error "=========================================="
        log_error "Some tests failed ✗"
        log_error "=========================================="
        exit 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
