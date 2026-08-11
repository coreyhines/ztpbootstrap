# Automated DHCP Testing Guide

This guide describes the fully automated DHCP testing system that creates VMs, installs ZTP Bootstrap, and runs all tests autonomously.

## Overview

The automated test system (`test-dhcp-automated.sh`) provides end-to-end testing that:

1. **Creates a VM** using QEMU
2. **Installs ZTP Bootstrap** on the VM
3. **Waits for services** to be ready
4. **Runs integration tests** (API endpoints)
5. **Runs DHCP E2E tests** with client simulation
6. **Generates comprehensive reports**
7. **Cleans up** (unless KEEP_VM_ON_FAILURE is set)

## Quick Start

```bash
# Run automated tests (default: Fedora 43)
make test-dhcp-automated

# Or directly
./dev/tests/test-dhcp-automated.sh

# With custom distro/version
DISTRO=ubuntu VERSION=24.04 ./dev/tests/test-dhcp-automated.sh
```

## Prerequisites

### Required Tools

- **QEMU** - For VM creation
  ```bash
  # macOS
  brew install qemu

  # Linux
  sudo apt-get install qemu-system-x86_64 qemu-utils  # Ubuntu/Debian
  sudo dnf install qemu-system-x86_64 qemu-img        # Fedora/RHEL
  ```

- **SSH** - For VM access (usually pre-installed)

- **BATS** - For integration tests (installed automatically on VM)

### Optional Tools

- **rsync** - For faster file transfer to VM (optional)
- **git** - For cloning repository on VM (if not using rsync)

## Configuration

### Environment Variables

```bash
# VM Configuration
VM_NAME="ztpbootstrap-dhcp-test"      # VM name
DISTRO="fedora"                        # Distribution (fedora, ubuntu, rocky, etc.)
VERSION="43"                           # Version number
SSH_PORT="2222"                        # SSH port for VM access

# Test Configuration
KEEP_VM_ON_FAILURE="false"             # Keep VM running on failure for debugging
REPORT_DIR="./tests/test-reports/..."  # Report directory (auto-generated)

# DHCP Test Configuration (passed to E2E test)
DHCP_SUBNET="10.0.0.0/24"
DHCP_RANGE_START="10.0.0.50"
DHCP_RANGE_END="10.0.0.250"
DHCP_GATEWAY="10.0.0.1"
```

### Supported Distributions

- **Fedora** (default) - Versions 38+
- **Ubuntu** - Versions 22.04+
- **Rocky Linux** - Versions 9+
- **AlmaLinux** - Versions 9+
- **CentOS Stream** - Versions 9+

## Test Execution Flow

### Step 1: VM Creation

The script creates a fresh VM using QEMU:

```bash
./dev/scripts/vm-create-native.sh \
    --download fedora \
    --type cloud \
    --arch aarch64 \
    --version 43 \
    --headless \
    --name ztpbootstrap-dhcp-test
```

- Downloads cloud image if not present
- Creates QCOW2 disk image
- Starts VM in headless mode
- Waits for SSH to be available

**Logs**: `{REPORT_DIR}/vm-create.log`

### Step 2: ZTP Bootstrap Installation

The script installs ZTP Bootstrap on the VM:

1. **Repository Setup**
   - Clones repository (or uses existing)
   - Installs dependencies (podman, Python packages)

2. **Configuration**
   - Creates `config.yaml` from template
   - Sets HTTP-only mode for testing (no SSL certs needed)
   - Configures basic settings

3. **Service Installation**
   - Runs `setup-interactive.sh --non-interactive --http-only`
   - Installs systemd services
   - Starts containers

**Logs**: Included in main test log

### Step 3: Service Readiness

Waits for WebUI service to be ready:

- Checks `/api/health` endpoint
- Timeout: 5 minutes
- Polls every 5 seconds

### Step 4: Integration Tests

Runs BATS integration tests:

```bash
bats tests/integration/test_dhcp_api.bats
```

Tests:
- DHCP config endpoint
- DHCP status endpoint
- DHCP auto-detect endpoint
- DHCP leases endpoint
- DHCP reservations endpoint
- DHCP statistics endpoint

**Logs**: `{REPORT_DIR}/integration-tests.log`

### Step 5: DHCP E2E Test

Runs full DHCP E2E test with client simulation:

```bash
./dev/tests/test-dhcp-e2e.sh
```

This test:
1. Configures DHCP via WebUI API
2. Enables DHCP server
3. Simulates DHCP client (using system tools or Python)
4. Verifies lease appears in API

**Logs**: `{REPORT_DIR}/dhcp-e2e-test.log`

### Step 6: Report Generation

Generates comprehensive test report:

- Test summary (passed/failed)
- Links to all log files
- VM access information (if kept)

**Report**: `{REPORT_DIR}/test-report.txt`

## Test Reports

Reports are saved to: `tests/test-reports/dhcp-automated-{timestamp}/`

### Report Structure

```
tests/test-reports/dhcp-automated-20240101_120000/
├── test-report.txt          # Summary report
├── test.log                 # Full test execution log
├── vm-create.log            # VM creation log
├── integration-tests.log    # Integration test output
└── dhcp-e2e-test.log        # E2E test output
```

### Report Contents

- Test execution summary
- Passed/failed test counts
- Links to detailed logs
- VM access information (if kept for debugging)

## Debugging Failed Tests

### Keep VM Running

Set `KEEP_VM_ON_FAILURE=true` to keep VM running after test failure:

```bash
KEEP_VM_ON_FAILURE=true ./dev/tests/test-dhcp-automated.sh
```

Then SSH into the VM:

```bash
ssh -p 2222 fedora@localhost  # or ubuntu@localhost for Ubuntu
```

### Manual Verification

Once in the VM:

```bash
# Check service status
sudo systemctl status ztpbootstrap-webui.service
sudo systemctl status ztpbootstrap-dhcp.service

# Check containers
podman ps

# Check logs
sudo journalctl -u ztpbootstrap-webui.service -n 50
sudo journalctl -u ztpbootstrap-dhcp.service -n 50

# Test API manually
curl http://localhost:8080/api/health
curl http://localhost:8080/api/dhcp/status
```

### Common Issues

1. **VM Creation Fails**
   - Check QEMU installation
   - Verify disk space
   - Check VM creation log

2. **SSH Connection Fails**
   - Wait longer (cloud-init takes time)
   - Check SSH port (default: 2222)
   - Verify VM is running: `ps aux | grep qemu`

3. **Service Installation Fails**
   - Check podman installation
   - Verify network connectivity
   - Check setup logs

4. **Tests Fail**
   - Check service logs
   - Verify API endpoints are accessible
   - Check DHCP container status

## CI/CD Integration

### Forgejo Actions Example

(Historical example shape; live CI is under `.forgejo/workflows/` — see
[FORGEJO_GITHUB_MIRROR.md](FORGEJO_GITHUB_MIRROR.md).)

```yaml
name: DHCP Automated Tests

on:
  push:
    branches: [ main, feature/dhcp-* ]
  pull_request:
    branches: [ main ]

jobs:
  test-dhcp:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install QEMU
        run: brew install qemu

      - name: Run Automated DHCP Tests
        run: make test-dhcp-automated

      - name: Upload Test Reports
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: dhcp-test-reports
          path: tests/test-reports/
```

### GitLab CI Example

```yaml
dhcp-automated-tests:
  image: macos:latest
  before_script:
    - brew install qemu
  script:
    - make test-dhcp-automated
  artifacts:
    when: always
    paths:
      - tests/test-reports/
    expire_in: 1 week
```

## Performance Considerations

### Test Duration

Typical test execution times:

- **VM Creation**: 2-5 minutes (first time, includes download)
- **VM Creation**: 30-60 seconds (subsequent runs)
- **Installation**: 2-5 minutes
- **Service Startup**: 1-2 minutes
- **Integration Tests**: 30-60 seconds
- **E2E Test**: 1-2 minutes

**Total**: ~10-15 minutes (first run), ~5-8 minutes (subsequent runs)

### Optimization Tips

1. **Reuse Cloud Images**: Keep downloaded cloud images
2. **Parallel Testing**: Run multiple VMs on different ports
3. **Skip VM Creation**: Use existing VM if available
4. **Faster Networks**: Use local mirrors for package installation

## Advanced Usage

### Custom Test Matrix

Create a test matrix file:

```yaml
# test-matrix-dhcp.yaml
tests:
  - name: "dhcp_basic"
    distro: "fedora"
    version: "43"
    dhcp_config:
      subnet: "10.0.0.0/24"
      range_start: "10.0.0.50"
      range_end: "10.0.0.250"
```

Run with custom matrix:

```bash
TEST_MATRIX=test-matrix-dhcp.yaml ./dev/tests/test-dhcp-automated.sh
```

### Multiple Distribution Testing

Test across multiple distributions:

```bash
for distro in fedora ubuntu rocky; do
    DISTRO=$distro ./dev/tests/test-dhcp-automated.sh
done
```

## Troubleshooting

See [DHCP_TESTING.md](./DHCP_TESTING.md) for detailed troubleshooting guide.

## Related Documentation

- [DHCP_TESTING.md](./DHCP_TESTING.md) - Manual testing guide
- [DHCP_IMPLEMENTATION_PLAN.md](./DHCP_IMPLEMENTATION_PLAN.md) - Implementation details
- [TESTING.md](./TESTING.md) - General testing guide
