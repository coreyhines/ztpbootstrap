# DHCP Server Implementation Plan (Kea-based) - Complete

## Overview

This plan implements Kea DHCP server integration into the ZTP Bootstrap Service, providing API-driven DHCP management with OUI filtering, reservations, dynamic DNS, PXE support, log viewing, and relay/proxy support. All configuration is done via Web UI with zero setup prompts.

**Host Networking Mode Support**: The DHCP server fully supports both host networking mode (`host_network: true`) and macvlan networking mode. When using host networking mode, Kea binds directly to the host's network interfaces, making it suitable for VM testing and simple deployments. The system automatically detects the networking mode and configures Kea accordingly.

## Phase 1: Configuration Schema and Core Infrastructure

### 1.1 Extend config.yaml.template

**File**: `config.yaml.template`

Add DHCP section after `auth` section:

```yaml
# ============================================================================
# DHCP Server Configuration
# ============================================================================
dhcp:
  # Enable DHCP server (configured via Web UI)
  enabled: false

  # DHCP server type (kea or dnsmasq)
  server: "kea"

  # IPv4 Configuration
  ipv4:
    subnet: ""
    range_start: ""
    range_end: ""
    gateway: ""
    dns_servers: []
    domain: ""
    ntp_servers: []

  # IPv6 Configuration
  ipv6:
    subnet: ""
    range_start: ""
    range_end: ""
    gateway: ""
    dns_servers: []
    domain: ""

  # OUI Filtering
  oui_filtering:
    arista_only_mode: false
    allowed_ouis: []
    blocked_ouis: []

  # DHCP Options
  options:
    standard:
      dns_servers: []
      ntp_servers: []
      domain: ""
    custom: []

  # PXE Configuration (hidden until enabled)
  pxe:
    enabled: false
    boot_file_source: "local"  # "local" or "external"
    boot_server_url: ""
    boot_file_name: ""

  # Relay/Proxy Support
  relay:
    enabled: false  # Set to true if serving via relay agents
    subnets: []  # List of subnets served via relays
      # - subnet: "10.0.1.0/24"
      #   relay_agent: "10.0.1.1"  # giaddr from relay
      #   range_start: "10.0.1.100"
      #   range_end: "10.0.1.200"

  # Backend Configuration
  backend:
    type: "memfile"  # "memfile" or "postgresql"
    postgresql:
      host: ""
      port: 5432
      database: ""
      user: ""
      password: ""
```

### 1.2 Create Kea Configuration Generator

**File**: `webui/dhcp_config.py` (new)

Create module to:
- Generate Kea JSON configuration from YAML config
- Support memfile and PostgreSQL backends
- Handle IPv4 and IPv6 configurations
- Generate client classification rules for OUI filtering
- Generate DHCP options (standard and custom)
- Generate PXE boot configurations
- **Support relay/proxy configurations** (multiple subnets via giaddr)

**Key Functions**:
- `generate_kea_config(config_yaml) -> dict`: Main config generator
- `generate_dhcp4_config(dhcp_config) -> dict`: IPv4 configuration
- `generate_dhcp6_config(dhcp_config) -> dict`: IPv6 configuration
- `generate_client_classes(oui_config) -> list`: OUI filtering classes
- `generate_dhcp_options(options_config) -> list`: DHCP options
- `generate_relay_subnets(relay_config) -> list`: Generate subnet configs per relay agent
- `configure_giaddr_matching(relay_config) -> dict`: Configure giaddr-based routing
- `detect_networking_mode(config_yaml) -> str`: Detect if host networking or macvlan (returns "host" or "macvlan")
- `get_interfaces_for_kea(networking_mode, subnet) -> list`: Get list of interfaces Kea should bind to

### 1.3 Create Gateway Detection Utility

**File**: `webui/dhcp_utils.py` (new)

Functions for:
- `detect_gateway(ipv4_address=None, ipv6_address=None) -> dict`: Detect gateway from host routes
- `detect_subnet(ip_address) -> str`: Infer subnet from IP address
- `validate_dhcp_range(subnet, range_start, range_end, gateway, pod_ip) -> tuple`: Validate range and return conflicts
- `calculate_default_range(subnet, gateway, pod_ip) -> tuple`: Calculate default .50-.250 range excluding conflicts
- `check_dhcp_port_conflicts() -> dict`: Check if ports 67/68 (IPv4) or 547/548 (IPv6) are already in use
- `detect_host_interfaces(subnet=None) -> list`: Detect available network interfaces on host (for host networking mode)

## Phase 2: Container Deployment

### 2.1 Create Kea Container Quadlet File

**File**: `systemd/ztpbootstrap-dhcp.container` (new)

```ini
[Unit]
Description=ZTP Bootstrap DHCP Server (Kea)
After=ztpbootstrap-pod.service
Requires=ztpbootstrap-pod.service

[Container]
Image=docker.io/iscorg/kea:latest
ContainerName=ztpbootstrap-dhcp
Pod=ztpbootstrap.pod
Exec=/usr/sbin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf
Exec=/usr/sbin/kea-dhcp6 -c /etc/kea/kea-dhcp6.conf
Exec=/usr/sbin/kea-ctrl-agent -c /etc/kea/kea-ctrl-agent.conf
Volume=/opt/containerdata/ztpbootstrap/dhcp:/etc/kea:ro
Volume=/opt/containerdata/ztpbootstrap/dhcp/leases:/var/lib/kea:rw
Volume=/opt/containerdata/ztpbootstrap/dhcp/logs:/var/log/kea:rw
Environment=TZ=UTC

[Service]
Restart=on-failure

[Install]
WantedBy=ztpbootstrap-pod.service
```

### 2.2 Create Container Deployment Module

**File**: `webui/dhcp_deploy.py` (new)

Functions for on-the-fly container creation:
- `create_dhcp_container() -> bool`: Create quadlet file and systemd service
- `start_dhcp_container() -> bool`: Start DHCP container
- `stop_dhcp_container() -> bool`: Stop DHCP container
- `remove_dhcp_container() -> bool`: Remove container (when disabled)
- `check_dhcp_container_status() -> dict`: Get container status

**Implementation Notes**:
- Use podman socket (`/run/podman/podman.sock`) for container management
- Create quadlet file in `/etc/containers/systemd/ztpbootstrap/`
- Run `systemctl daemon-reload` after creating files
- Use `podman exec` to check Kea Control Agent health
- **Host Networking Mode**: When `host_network: true` in config, the DHCP container inherits host networking from the pod. Kea will bind to host interfaces directly. No special container configuration needed - the pod's `Network=host` setting applies.
- **Port Conflict Detection**: Before enabling DHCP, check if ports 67/68 (IPv4) or 547/548 (IPv6) are already in use. Warn user if conflicts detected.

### 2.3 Update setup.sh for Optional DHCP Container

**File**: `setup.sh`

Modify `setup_pod()` to:
- Only copy DHCP container file if it exists (for fallback 4a)
- Don't fail if DHCP container file doesn't exist
- Add comment about on-the-fly creation (4b)

## Phase 3: Web UI Integration

### 3.1 Add DHCP Tab to Web UI

**File**: `webui/templates/index.html`

Add new tab in navigation:
- "DHCP" tab (after "Logs" or "Device Connections")
- Tab content includes:
  - Enable/Disable toggle
  - Configuration form (hidden when disabled)
  - Leases table
  - Reservations management
  - Statistics dashboard
  - OUI filtering rules
  - PXE configuration (hidden until enabled)
  - Relay configuration (if relay mode enabled)

### 3.2 Create DHCP Configuration Form

**File**: `webui/templates/index.html` (DHCP section)

Form fields:
- **Basic Settings**:
  - IPv4 Subnet (CIDR) - with auto-detect button
  - IPv4 Range Start
  - IPv4 Range End
  - IPv4 Gateway - with auto-detect button
  - IPv6 Subnet (CIDR) - with auto-detect button
  - IPv6 Range Start
  - IPv6 Range End
  - IPv6 Gateway - with auto-detect button
- **DNS & Domain**:
  - DNS Servers (comma-separated)
  - Domain Name
  - NTP Servers (comma-separated)
- **OUI Filtering**:
  - Arista-only mode toggle
  - Allowed OUIs list
  - Blocked OUIs list
- **DHCP Options**:
  - Standard options (pre-filled from config)
  - Custom options (add/remove)
- **Relay/Proxy Mode** (toggle):
  - Enable relay mode
  - List of relay subnets (add/remove)
  - Each relay subnet: subnet, relay agent IP, range
- **PXE** (hidden until enabled):
  - Enable PXE toggle
  - Boot file source (local/external)
  - Boot server URL (if external)
  - Boot file name

**Auto-detection UI**:
- "Auto-detect" buttons next to subnet/gateway fields
- Show detected values in modal/alert
- Require user confirmation before applying
- Highlight auto-detected vs manually entered values

**Host Networking Mode Warning**:
- When `host_network: true` is detected in config, show an informational banner/warning:
  - "Host networking mode detected. DHCP server will bind directly to host interfaces."
  - "Ensure no other DHCP server is running on ports 67/68 (IPv4) or 547/548 (IPv6)."
  - "Port conflict check will be performed before enabling DHCP."
- Display networking mode status (host/macvlan) in DHCP status section
- Show detected interfaces when in host networking mode

### 3.3 Create DHCP JavaScript Module

**File**: `webui/templates/index.html` (script section)

Alpine.js components:
- `dhcpConfig`: Main DHCP configuration state
- `dhcpLeases`: Leases table data
- `dhcpReservations`: Reservations management
- `dhcpStatistics`: Statistics display

Functions:
- `loadDhcpConfig()`: Load current configuration
- `autoDetectSubnet(ipv4)`: Call API to detect subnet
- `autoDetectGateway()`: Call API to detect gateway
- `validateDhcpConfig()`: Client-side validation
- `saveDhcpConfig()`: Save configuration
- `enableDhcp()`: Enable DHCP (creates container if needed)
- `disableDhcp()`: Disable DHCP
- `loadDhcpLeases()`: Load current leases
- `addReservation()`: Add static reservation
- `removeReservation()`: Remove reservation

## Phase 4: API Endpoints

### 4.1 DHCP Configuration Endpoints

**File**: `webui/app.py`

Add routes:

```python
@app.route('/api/dhcp/config', methods=['GET'])
@require_auth
def get_dhcp_config():
    """Get current DHCP configuration"""

@app.route('/api/dhcp/config', methods=['PUT'])
@require_auth
def update_dhcp_config():
    """Update DHCP configuration"""

@app.route('/api/dhcp/config/auto-detect', methods=['POST'])
@require_auth
def auto_detect_dhcp_config():
    """Auto-detect subnet and gateway"""

@app.route('/api/dhcp/status', methods=['GET'])
@require_auth
def get_dhcp_status():
    """Get DHCP service status (enabled/disabled, container status, networking mode)"""
    # Include networking_mode: "host" or "macvlan"
    # Include port conflict status
    # Include detected interfaces (if host networking mode)

@app.route('/api/dhcp/enable', methods=['POST'])
@require_auth
def enable_dhcp():
    """Enable DHCP (creates container if needed)"""
    # Check for port conflicts before enabling
    # Warn if host networking mode and ports are in use
    # Return networking mode info in response

@app.route('/api/dhcp/disable', methods=['POST'])
@require_auth
def disable_dhcp():
    """Disable DHCP"""
```

### 4.2 DHCP Logs Endpoints

**File**: `webui/app.py`

Extend existing `/api/logs` endpoint to support DHCP logs:

```python
@app.route('/api/logs')
def get_logs():
    """Get recent logs from specified source"""
    # Add 'dhcp' as a log source option
    # When source == 'dhcp':
    #   - Read from Kea log file or journalctl
    #   - Parse Kea log format
    #   - Include relay agent information if present
    #   - Filter out UI/API requests (similar to nginx_access)
    #   - Support search and marking (same as other log sources)
```

**DHCP Log Sources**:
- Kea log file: `/opt/containerdata/ztpbootstrap/dhcp/logs/kea.log` (if configured)
- Journalctl: `journalctl -u ztpbootstrap-dhcp.service` (systemd logs)
- Podman logs: `podman logs ztpbootstrap-dhcp` (container stdout/stderr)

**Log Parsing**:
- Parse Kea log format (JSON or text)
- Extract: timestamp, level, message, client MAC, IP assigned, relay agent info
- Format for display similar to nginx logs
- Include relay agent information (giaddr, option 82) when present
- Show which relay agent forwarded the request (important for multi-subnet)

**Log Display**:
- Add "DHCP Logs" option to log source dropdown in UI
- Support search functionality (same as other logs)
- Support marking logs (same as other logs)
- Show relay agent IP and circuit-id/remote-id in log entries
- Format: `[RELAY: 10.0.1.1] Client MAC: aa:bb:cc:dd:ee:ff`

**File**: `webui/templates/index.html`

- Add "DHCP Logs" option to log source dropdown
- Display relay agent information in log entries
- Show giaddr and option 82 (circuit-id, remote-id) when present

### 4.3 DHCP Leases Endpoints

**File**: `webui/app.py`

```python
@app.route('/api/dhcp/leases', methods=['GET'])
@require_auth
def get_dhcp_leases():
    """Get current DHCP leases (IPv4 and IPv6)"""
    # Include relay agent information in lease data
    # Show which subnet/relay the lease came from

@app.route('/api/dhcp/leases/<mac>', methods=['GET'])
@require_auth
def get_dhcp_lease(mac):
    """Get specific lease by MAC address"""
    # Include relay agent information

@app.route('/api/dhcp/leases/<mac>', methods=['DELETE'])
@require_auth
def delete_dhcp_lease(mac):
    """Delete/release a lease"""
```

### 4.4 DHCP Reservations Endpoints

**File**: `webui/app.py`

```python
@app.route('/api/dhcp/reservations', methods=['GET'])
@require_auth
def get_dhcp_reservations():
    """Get static reservations"""

@app.route('/api/dhcp/reservations', methods=['POST'])
@require_auth
def add_dhcp_reservation():
    """Add static reservation"""

@app.route('/api/dhcp/reservations/<mac>', methods=['DELETE'])
@require_auth
def remove_dhcp_reservation(mac):
    """Remove static reservation"""
```

### 4.5 DHCP Statistics Endpoint

**File**: `webui/app.py`

```python
@app.route('/api/dhcp/statistics', methods=['GET'])
@require_auth
def get_dhcp_statistics():
    """Get DHCP server statistics"""
```

### 4.6 Kea Control Agent Integration

**File**: `webui/kea_client.py` (new)

Module to communicate with Kea Control Agent:
- `kea_request(command, service, arguments) -> dict`: Send JSON-RPC request
- `get_leases(service='dhcp4') -> list`: Get leases (include relay info)
- `get_statistics(service='dhcp4') -> dict`: Get statistics
- `add_reservation(reservation) -> bool`: Add reservation
- `delete_reservation(mac) -> bool`: Delete reservation
- `reload_config() -> bool`: Reload configuration

**Note**: Kea Control Agent runs on port 8000 inside container, accessible via pod network.

## Phase 5: Auto-Detection Implementation

### 5.1 Subnet Detection

**File**: `webui/dhcp_utils.py`

```python
def detect_subnet(ip_address):
    """
    Detect subnet from IP address.
    Assumes /24 for IPv4, /64 for IPv6 (common defaults).
    Returns CIDR notation.
    """
    # Parse IP address
    # For IPv4: assume /24 unless it's a /16 or /8 network
    # For IPv6: assume /64
    # Return CIDR string
```

### 5.2 Gateway Detection

**File**: `webui/dhcp_utils.py`

```python
def detect_gateway(ipv4_address=None, ipv6_address=None):
    """
    Detect gateway from host routes.
    Checks:
    1. Default route (ip route | grep default)
    2. Route for pod network
    3. Network interface configuration
    Returns dict with ipv4_gateway and ipv6_gateway
    """
    # Use subprocess to run 'ip route' or 'route -n'
    # Parse default route
    # Return gateway IPs
```

### 5.3 Range Validation

**File**: `webui/dhcp_utils.py`

```python
def validate_dhcp_range(subnet, range_start, range_end, gateway, pod_ip):
    """
    Validate DHCP range:
    - Range is within subnet
    - Gateway is excluded
    - Pod IP is excluded
    - Broadcast address is excluded
    - Range is valid (start < end)
    Returns (is_valid, conflicts_list, warnings_list)
    """
```

## Phase 6: OUI Filtering

### 6.1 OUI Database

**File**: `webui/oui_db.py` (new)

- Load Arista OUIs (known prefixes)
- Functions to check if MAC belongs to OUI
- Support for custom OUI lists

### 6.2 Client Classification

**File**: `webui/dhcp_config.py`

Generate Kea client classification:
- Arista-only mode: Classify by OUI, only serve Arista devices
- Per-OUI configuration: Different options per OUI
- Blocked OUIs: Explicitly block certain OUIs

## Phase 7: PXE Support

### 7.1 PXE Configuration

**File**: `webui/dhcp_config.py`

- Generate PXE boot options (66, 67)
- Support local storage (serve via nginx) or external server
- Different boot files per client class

### 7.2 PXE File Management

**File**: `webui/app.py`

```python
@app.route('/api/dhcp/pxe/files', methods=['GET'])
@require_auth
def get_pxe_files():
    """List PXE boot files"""

@app.route('/api/dhcp/pxe/files', methods=['POST'])
@require_auth
def upload_pxe_file():
    """Upload PXE boot file"""

@app.route('/api/dhcp/pxe/files/<filename>', methods=['DELETE'])
@require_auth
def delete_pxe_file(filename):
    """Delete PXE boot file"""
```

## Phase 8: DHCP Relay/Proxy Support

### 8.1 Relay Configuration

**File**: `webui/dhcp_config.py`

- Generate subnet configurations for each relay agent
- Use giaddr matching to route requests to correct subnet
- Configure shared networks if multiple subnets share same relay
- Support option 82 parsing and logging
- Store relay agent information in leases

### 8.2 Relay Implications

**Key Considerations**:
- DHCP server may not be on the same subnet as clients
- Relay agents forward requests with giaddr (gateway IP)
- Option 82 (Relay Agent Information) contains circuit-id and remote-id
- Multiple subnets can be served via different relay agents
- Each relay agent represents a different subnet/VLAN

**Configuration**:
- Support multiple subnets (one per relay agent)
- Configure subnet pools based on giaddr
- Store relay agent information in leases
- Log relay agent details (giaddr, circuit-id, remote-id)

**Lease Display**:
- Show relay agent IP (giaddr) in lease table
- Show circuit-id and remote-id if available
- Filter leases by relay agent/subnet

**Log Display**:
- Include relay agent information in log entries
- Show which subnet/relay the request came from
- Format: `[RELAY: 10.0.1.1] Client MAC: aa:bb:cc:dd:ee:ff`

## Phase 9: Testing

### 9.1 Unit Tests

**Files**: `tests/unit/test_dhcp_*.bats`

- Test configuration generation
- Test gateway detection
- Test subnet detection
- Test range validation
- Test OUI filtering logic
- Test relay configuration generation

### 9.2 Integration Tests

**Files**: `tests/integration/test_dhcp_*.bats`

- Test container creation
- Test Kea API communication
- Test lease management
- Test reservation management
- Test relay agent handling

### 9.3 E2E Tests

**Files**: `dev/tests/test-dhcp-e2e.sh`

- Full DHCP server deployment
- Client DHCP request simulation
- Lease verification
- Reservation verification
- Relay agent simulation

## Implementation Order

1. **Phase 1**: Configuration schema and utilities (foundation)
2. **Phase 2**: Container deployment (infrastructure)
3. **Phase 5**: Auto-detection (needed for UI)
4. **Phase 4**: API endpoints (backend)
5. **Phase 3**: Web UI (frontend)
6. **Phase 6**: OUI filtering (advanced feature)
7. **Phase 7**: PXE support (optional feature)
8. **Phase 8**: Relay/proxy support (multi-subnet)
9. **Phase 9**: Testing (throughout, but comprehensive at end)

## Key Files to Create/Modify

**New Files**:
- `webui/dhcp_config.py` - Kea configuration generator
- `webui/dhcp_utils.py` - Utility functions (detection, validation)
- `webui/dhcp_deploy.py` - Container deployment
- `webui/kea_client.py` - Kea Control Agent client
- `webui/oui_db.py` - OUI database
- `systemd/ztpbootstrap-dhcp.container` - Container definition

**Modified Files**:
- `config.yaml.template` - Add DHCP section
- `webui/app.py` - Add API endpoints, extend log system
- `webui/templates/index.html` - Add DHCP UI, extend log UI
- `setup.sh` - Handle optional DHCP container

## Dependencies

**Python**:
- `requests` (for Kea Control Agent API) - may already be in requirements.txt
- `ipaddress` (standard library) - for IP/subnet calculations
- `netifaces` (optional) - for better network interface detection

**Container**:
- Kea Docker image: `docker.io/iscorg/kea:latest`

## Host Networking Mode Support

### Overview
The DHCP server fully supports host networking mode (`host_network: true`), which is commonly used for VM testing and simple deployments. When host networking mode is enabled, the DHCP container inherits the host's network stack, allowing Kea to bind directly to host interfaces.

### Key Considerations

1. **Port Conflicts**:
   - In host networking mode, Kea binds to ports 67/68 (IPv4) and 547/548 (IPv6) on the host
   - Check for existing DHCP servers before enabling (e.g., systemd-networkd, dnsmasq, ISC DHCP)
   - Warn user if ports are already in use

2. **Interface Binding**:
   - Kea must be configured to bind to specific interfaces
   - In host networking mode, detect available interfaces and configure Kea accordingly
   - Use `interfaces-config` in Kea config to specify interfaces

3. **Container Configuration**:
   - No special container configuration needed - inherits from pod's `Network=host` setting
   - Container runs in the same pod as other services
   - All containers in pod share host network stack

4. **Detection**:
   - Read `container.host_network` from config.yaml
   - Check pod file for `Network=host` setting
   - Display networking mode in UI status

5. **UI Guidance**:
   - Show informational banner when host networking mode detected
   - Display port conflict warnings before enabling
   - Show detected interfaces in status section
   - Provide clear messaging about host networking mode implications

### Implementation Details

- **Kea Configuration**: When host networking mode is detected, configure Kea's `interfaces-config` section to bind to detected interfaces
- **Port Checking**: Use `netstat` or `ss` to check if ports 67/68/547/548 are in use before enabling
- **Interface Detection**: Use `ip link show` or `/proc/net/dev` to detect available interfaces
- **Validation**: Warn but don't block - user may intentionally want to replace existing DHCP server

## Notes

- All configuration changes require Kea config reload (via Control Agent)
- Container creation on-the-fly (4b) is preferred but fallback to 4a if complex
- Gateway detection may fail in some network setups - allow manual entry
- IPv6 support is required from day 0
- PXE UI is hidden until explicitly enabled
- All DHCP features are optional - service works without DHCP enabled
- **DHCP Logs**: Integrated into existing log viewing system with search and marking support
- **Relay Support**: Server can serve multiple subnets via DHCP relay agents (giaddr, option 82)
- **Relay Logging**: All relay agent information (giaddr, circuit-id, remote-id) is logged and displayed
- **Zero Setup Prompts**: All DHCP configuration done via Web UI, no setup script prompts
- **Host Networking Mode**: Fully supported - DHCP server works in both host networking and macvlan modes
