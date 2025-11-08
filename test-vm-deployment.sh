#!/bin/bash
# Test VM Deployment Script
# Run this script inside a test VM to validate the ZTP Bootstrap deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/coreyhines/ztpbootstrap.git}"
REPO_DIR="${REPO_DIR:-./ztpbootstrap}"

echo "=========================================="
echo "ZTP Bootstrap Test Deployment"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
else
    log_error "Cannot detect OS. Please run on a supported Linux distribution."
    exit 1
fi

log_info "Detected OS: $OS $OS_VERSION"

# Install prerequisites
log_info "Installing prerequisites..."

case $OS in
    fedora|rhel|rocky|almalinux|centos)
        log_info "Installing Podman and dependencies (RHEL-based)..."
        dnf install -y podman git curl yq || {
            log_error "Failed to install packages"
            exit 1
        }
        ;;
    ubuntu|debian)
        log_info "Installing Podman and dependencies (Debian-based)..."
        apt-get update
        apt-get install -y podman git curl yq || {
            log_error "Failed to install packages"
            exit 1
        }
        ;;
    *)
        log_error "Unsupported OS: $OS"
        log_warn "Please install Podman, git, curl, and yq manually"
        ;;
esac

# Verify Podman
if ! command -v podman &> /dev/null; then
    log_error "Podman is not installed"
    exit 1
fi

PODMAN_VERSION=$(podman --version)
log_info "Podman installed: $PODMAN_VERSION"

# Clone repo if not already present
if [[ ! -d "$REPO_DIR" ]]; then
    log_info "Cloning repository..."
    git clone "$REPO_URL" "$REPO_DIR" || {
        log_error "Failed to clone repository"
        exit 1
    }
fi

cd "$REPO_DIR" || exit 1

log_info "Repository location: $(pwd)"

# Check for macvlan network
log_info "Checking for macvlan network..."
if podman network exists ztpbootstrap-net 2>/dev/null; then
    log_info "Macvlan network 'ztpbootstrap-net' exists"
else
    log_warn "Macvlan network 'ztpbootstrap-net' not found"
    log_warn "For testing, we'll create a simple bridge network instead"
    log_info "Creating test network..."
    
    # Get the default network interface
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$DEFAULT_IFACE" ]]; then
        log_error "Cannot determine default network interface"
        exit 1
    fi
    
    log_info "Default interface: $DEFAULT_IFACE"
    log_warn "For full macvlan testing, you'll need to create the network manually"
    log_warn "See check-macvlan.sh for instructions"
    
    # Create a simple bridge network for testing
    if ! podman network exists ztpbootstrap-test-net 2>/dev/null; then
        podman network create ztpbootstrap-test-net || {
            log_error "Failed to create test network"
            exit 1
        }
        log_info "Created test network: ztpbootstrap-test-net"
    fi
fi

# Create test environment file
log_info "Creating test environment file..."
cat > ztpbootstrap.env <<EOF
# Test Configuration
CV_ADDR=www.arista.io
ENROLLMENT_TOKEN=test_token_replace_me
CV_PROXY=
EOS_URL=
NTP_SERVER=ntp1.aristanetworks.com
DOMAIN=ztpboot.test.local
EOF

log_warn "Using test configuration. Update ENROLLMENT_TOKEN in ztpbootstrap.env if needed."

# Test HTTP-only mode (no SSL certs needed)
log_info "Testing HTTP-only mode (no SSL certificates required)..."
log_info "Running setup script..."

if ./setup.sh --http-only; then
    log_info "✓ Setup completed successfully!"
    
    # Check service status
    log_info "Checking service status..."
    systemctl status ztpbootstrap-pod --no-pager || true
    
    # Test endpoints
    log_info "Testing endpoints..."
    sleep 5  # Give service time to start
    
    if curl -f http://localhost/health 2>/dev/null; then
        log_info "✓ Health endpoint responding"
    else
        log_warn "Health endpoint not responding (service may still be starting)"
    fi
    
    if curl -f http://localhost/bootstrap.py 2>/dev/null | head -5; then
        log_info "✓ Bootstrap script accessible"
    else
        log_warn "Bootstrap script not accessible"
    fi
    
    log_info ""
    log_info "=========================================="
    log_info "Test Deployment Complete!"
    log_info "=========================================="
    log_info ""
    log_info "Service Status:"
    systemctl status ztpbootstrap-pod --no-pager -l || true
    log_info ""
    log_info "Pod Status:"
    podman pod ps || true
    log_info ""
    log_info "Container Status:"
    podman ps --filter pod=ztpbootstrap-pod || true
    log_info ""
    log_info "Test endpoints:"
    log_info "  Health: curl http://localhost/health"
    log_info "  Bootstrap: curl http://localhost/bootstrap.py"
    log_info ""
    log_info "To stop the service:"
    log_info "  sudo systemctl stop ztpbootstrap-pod"
    log_info ""
    log_info "To view logs:"
    log_info "  sudo journalctl -u ztpbootstrap-pod -f"
    log_info "  sudo podman logs ztpbootstrap-nginx"
    
else
    log_error "Setup failed. Check the output above for errors."
    exit 1
fi
