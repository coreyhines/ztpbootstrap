# DHCP Testing Guide

This document describes the testing infrastructure for the DHCP server implementation.

## Test Structure

The DHCP implementation includes three levels of testing:

1. **Unit Tests** - Test individual Python modules in isolation
2. **Integration Tests** - Test API endpoints with a running service
3. **End-to-End Tests** - Test full DHCP functionality with VMs

## Unit Tests

### Python Unit Tests

Located in `tests/unit/test_dhcp_*.py`:

- **test_dhcp_config.py** - Tests Kea configuration generation
  - Configuration generation for IPv4/IPv6
  - OUI filtering rules
  - PXE options
  - Relay subnet configuration

- **test_dhcp_utils.py** - Tests utility functions
  - Subnet detection
  - Gateway detection
  - Range validation
  - Networking mode detection

**Run Python unit tests:**
```bash
cd tests/unit
python3 -m unittest test_dhcp_*.py
```

Or via Makefile:
```bash
make test-quick  # Includes Python unit tests
```

### BATS Unit Tests

Located in `tests/unit/test_*.bats`:

- Configuration validation tests
- Script syntax tests

**Run BATS unit tests:**
```bash
bats tests/unit/*.bats
```

## Integration Tests

### API Integration Tests

Located in `tests/integration/test_dhcp_api.bats`:

Tests DHCP API endpoints:
- `/api/dhcp/config` - Configuration management
- `/api/dhcp/status` - Service status
- `/api/dhcp/config/auto-detect` - Auto-detection
- `/api/dhcp/leases` - Lease management
- `/api/dhcp/reservations` - Reservation management
- `/api/dhcp/statistics` - Statistics

**Prerequisites:**
- WebUI service must be running (`ztpbootstrap-webui.service`)
- Default credentials: `admin`/`admin` (or set `TEST_USER`/`TEST_PASS`)

**Run integration tests:**
```bash
bats tests/integration/test_dhcp_api.bats
```

Or via Makefile:
```bash
make test-integration
```

## End-to-End Tests

### VM-Based E2E Test

Located in `dev/tests/test-dhcp-e2e.sh`:

Tests complete DHCP server functionality:
1. VM setup and ZTP Bootstrap installation
2. DHCP server configuration via WebUI
3. DHCP server enablement
4. Lease verification
5. DHCP client simulation (requires separate test client)

**Prerequisites:**
- QEMU installed
- Podman available
- VM creation script (`dev/scripts/vm-create-native.sh`)

**Run E2E test:**
```bash
./dev/tests/test-dhcp-e2e.sh
```

Or via Makefile:
```bash
make test-dhcp-e2e
```

**Configuration:**
```bash
export VM_NAME="ztpbootstrap-dhcp-test"
export VM_IP="10.0.0.100"
export DHCP_SUBNET="10.0.0.0/24"
export DHCP_RANGE_START="10.0.0.50"
export DHCP_RANGE_END="10.0.0.250"
export DHCP_GATEWAY="10.0.0.1"
```

## Test Scenarios

### Basic DHCP Functionality

1. **Configuration Test**
   - Configure IPv4 subnet and range
   - Configure DNS servers
   - Enable DHCP server
   - Verify container starts

2. **Lease Management Test**
   - Enable DHCP server
   - Simulate DHCP client (or use real client)
   - Verify lease appears in `/api/dhcp/leases`
   - Delete lease via API
   - Verify lease removed

3. **Reservation Test**
   - Add static reservation via API
   - Verify reservation in config
   - Verify reservation applied to Kea

### Advanced Features

1. **OUI Filtering Test**
   - Enable Arista-only mode
   - Configure allowed OUIs
   - Configure blocked OUIs
   - Verify client classification rules generated

2. **PXE Boot Test**
   - Enable PXE configuration
   - Configure boot server URL
   - Configure boot file name
   - Verify PXE options in Kea config

3. **Relay/Proxy Test**
   - Configure relay mode
   - Add relay subnets
   - Verify relay subnet configuration
   - Test relay agent forwarding

4. **Host Networking Mode Test**
   - Configure with `host_network: true`
   - Verify port conflict detection
   - Verify interface binding
   - Test DHCP server binding to host interfaces

## Manual Testing

### Quick Manual Test

1. **Start WebUI service:**
   ```bash
   sudo systemctl start ztpbootstrap-webui.service
   ```

2. **Access WebUI:**
   - Navigate to `http://localhost:8080`
   - Login with admin credentials

3. **Configure DHCP:**
   - Go to DHCP tab
   - Click "Auto-detect" for subnet/gateway
   - Configure DHCP range
   - Click "Save Configuration"
   - Toggle DHCP server to "Enabled"

4. **Verify DHCP:**
   - Check container status: `podman ps | grep dhcp`
   - Check leases: View leases table in UI
   - Check logs: View DHCP logs in Logs tab

### DHCP Client Test

The E2E test includes automated DHCP client simulation:

1. **Using System Tools (Recommended):**
   ```bash
   # Uses dhclient, udhcpc, or dhcpcd
   ./dev/tests/dhcp_client_simple.sh eth0
   ```

2. **Using Python Simulator:**
   ```bash
   # Requires scapy (optional) or root for raw sockets
   python3 dev/tests/dhcp_client_simulator.py --interface eth0
   ```

3. **Manual Test with Real Client:**
   - Create test client VM:
     ```bash
     ./dev/scripts/vm-create-native.sh --name dhcp-client-test
     ```
   - Configure client to use DHCP
   - Verify IP assignment
   - Check leases in WebUI

## Continuous Integration

Tests are integrated into CI pipeline:

- **Pre-commit**: `make check` (lint + quick tests)
- **CI Pipeline**: Full test suite including integration tests
- **E2E Tests**: Run manually or in separate pipeline

## Troubleshooting

### Tests Fail to Import Modules

If Python tests fail with import errors:
```bash
# Ensure webui directory is in Python path
export PYTHONPATH="${PYTHONPATH}:$(pwd)/webui"
```

### Integration Tests Fail Authentication

If API tests fail:
- Verify WebUI service is running
- Check credentials in test environment
- Verify CSRF token handling

### E2E Tests Fail VM Creation

If VM tests fail:
- Verify QEMU is installed
- Check VM creation script permissions
- Verify sufficient disk space
- Check VM name doesn't conflict with existing VMs

## Test Coverage

Current test coverage:

- ✅ Configuration generation (unit tests)
- ✅ Utility functions (unit tests)
- ✅ API endpoints (integration tests)
- ⚠️  DHCP client simulation (manual/E2E)
- ⚠️  Relay agent testing (manual/E2E)
- ⚠️  PXE boot testing (manual/E2E)

## Future Improvements

- [ ] Add pytest for better Python test framework
- [ ] Add DHCP client simulation in E2E tests
- [ ] Add automated relay agent testing
- [ ] Add performance/load testing
- [ ] Add IPv6-specific tests
- [ ] Add multi-subnet testing
