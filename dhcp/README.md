# DHCP Configuration Files

This directory contains the Kea DHCP server configuration files used by the ZTP Bootstrap service.

## Overview

The ZTP Bootstrap service uses ISC Kea DHCP server to provide DHCP services with support for ZTP (Zero Touch Provisioning) bootstrap script delivery via DHCP Option 67.

## Configuration Files

### kea-dhcp4.conf

DHCPv4 (IPv4) server configuration. This is the primary DHCP server configuration.

**Key settings:**
- **Subnet**: `192.168.100.0/24` (for CI testing)
- **IP Pool**: `192.168.100.100 - 192.168.100.200`
- **Gateway**: `192.168.100.1`
- **DNS Servers**: `8.8.8.8`, `8.8.4.4`
- **DHCP Option 67** (boot-file-name): `http://192.168.100.10/bootstrap.py`
- **Lease Database**: `/var/lib/kea/dhcp4.leases` (memfile, persistent)
- **Interface**: `eth0`

### kea-dhcp6.conf

DHCPv6 (IPv6) server configuration. This is a minimal stub configuration and is disabled for CI testing.

**Key settings:**
- **Interfaces**: Empty (disabled)
- **Subnets**: Empty (no IPv6 subnets configured)
- **Lease Database**: `/var/lib/kea/dhcp6.leases` (memfile, persistent)

### kea-ctrl-agent.conf

Kea Control Agent configuration for the management API.

**Key settings:**
- **HTTP Host**: `0.0.0.0` (listen on all interfaces)
- **HTTP Port**: `8000`
- **Control Sockets**: Unix sockets for dhcp4 and dhcp6 services

## Directory Structure

```
dhcp/
├── kea-dhcp4.conf        # DHCPv4 server configuration
├── kea-dhcp6.conf        # DHCPv6 server configuration (minimal stub)
├── kea-ctrl-agent.conf   # Control Agent configuration
├── leases/               # Lease database directory (runtime)
├── logs/                 # Log files directory (runtime)
└── README.md            # This file
```

## Customization

### Testing vs Production

The default configuration is optimized for CI testing with an isolated test network. For production deployments, you should customize the following:

#### Testing Configuration (Default)
```json
{
  "subnet4": [
    {
      "subnet": "192.168.100.0/24",
      "pools": [{"pool": "192.168.100.100 - 192.168.100.200"}],
      "option-data": [
        {"name": "routers", "data": "192.168.100.1"},
        {"name": "domain-name-servers", "data": "8.8.8.8, 8.8.4.4"},
        {"name": "boot-file-name", "code": 67, "data": "http://192.168.100.10/bootstrap.py"}
      ]
    }
  ]
}
```

#### Production Configuration Example
```json
{
  "subnet4": [
    {
      "subnet": "10.0.0.0/24",
      "pools": [{"pool": "10.0.0.100 - 10.0.0.200"}],
      "option-data": [
        {"name": "routers", "data": "10.0.0.1"},
        {"name": "domain-name-servers", "data": "10.0.0.1, 1.1.1.1"},
        {"name": "boot-file-name", "code": 67, "data": "https://ztpboot.example.com/bootstrap.py"}
      ]
    }
  ]
}
```

### Common Customizations

#### Change DHCP Subnet and IP Range

Edit `kea-dhcp4.conf`:
```json
{
  "subnet": "YOUR_SUBNET/24",
  "pools": [{"pool": "START_IP - END_IP"}]
}
```

#### Change Gateway (Router Option)

Edit the routers option in `kea-dhcp4.conf`:
```json
{"name": "routers", "data": "YOUR_GATEWAY_IP"}
```

#### Change DNS Servers

Edit the domain-name-servers option in `kea-dhcp4.conf`:
```json
{"name": "domain-name-servers", "data": "DNS1, DNS2"}
```

#### Change Bootstrap Script URL (DHCP Option 67)

Edit the boot-file-name option in `kea-dhcp4.conf`:
```json
{"name": "boot-file-name", "code": 67, "data": "http://YOUR_SERVER/bootstrap.py"}
```

Or for HTTPS:
```json
{"name": "boot-file-name", "code": 67, "data": "https://YOUR_SERVER/bootstrap.py"}
```

#### Change Network Interface

Edit the interfaces-config section in `kea-dhcp4.conf`:
```json
{
  "interfaces-config": {
    "interfaces": ["YOUR_INTERFACE_NAME"]
  }
}
```

To listen on all interfaces:
```json
{
  "interfaces-config": {
    "interfaces": ["*"]
  }
}
```

#### Adjust Lease Times

Edit the timer values in `kea-dhcp4.conf`:
```json
{
  "renew-timer": 900,      // 15 minutes (default)
  "rebind-timer": 1800,    // 30 minutes (default)
  "valid-lifetime": 3600   // 1 hour (default)
}
```

For longer lease times (production):
```json
{
  "renew-timer": 43200,     // 12 hours
  "rebind-timer": 75600,    // 21 hours
  "valid-lifetime": 86400   // 24 hours
}
```

### DHCP Reservations

To add static DHCP reservations, add a `reservations` section to the subnet configuration:

```json
{
  "subnet": "10.0.0.0/24",
  "reservations": [
    {
      "hw-address": "aa:bb:cc:dd:ee:ff",
      "ip-address": "10.0.0.50",
      "hostname": "device1"
    },
    {
      "hw-address": "11:22:33:44:55:66",
      "ip-address": "10.0.0.51",
      "hostname": "device2"
    }
  ]
}
```

## Container Deployment

The DHCP server runs in a Podman/Docker container with the following mounts:

- **Configuration**: `/opt/containerdata/ztpbootstrap/dhcp:/etc/kea:ro`
- **Lease Database**: `/opt/containerdata/ztpbootstrap/dhcp/leases:/var/lib/kea:rw`
- **Logs**: `/opt/containerdata/ztpbootstrap/dhcp/logs:/var/log/kea:rw`

The container requires these capabilities:
- `CAP_NET_RAW` - For raw socket access (DHCP protocol)
- `CAP_NET_BIND_SERVICE` - For binding to privileged ports

## Integration Testing

The CI workflow `.github/workflows/dhcp-integration-test.yml` performs automated integration testing:

1. **Creates isolated test network** - Podman bridge network on `192.168.100.0/24`
2. **Deploys full service** - Starts all containers (nginx, webui, postgresql, dhcp)
3. **Runs DHCP client tests** - Alpine container with dhclient
4. **Verifies lease assignment** - Checks IP is in expected range
5. **Verifies Option 67** - Confirms boot-file-name is delivered
6. **Tests bootstrap download** - Downloads and validates bootstrap.py
7. **Tests lease renewal** - Verifies DHCP renewal works

### Running Integration Tests Locally

To run the integration tests locally:

```bash
# The test workflow runs automatically on push to feature/dhcp-implementation branch
git push origin feature/dhcp-implementation

# Or run manually in GitHub Actions UI
```

For local testing without CI:

```bash
# 1. Create test network
sudo podman network create \
  --driver bridge \
  --subnet 192.168.100.0/24 \
  --gateway 192.168.100.1 \
  dhcp-test-net

# 2. Copy configuration files
sudo mkdir -p /opt/containerdata/ztpbootstrap/dhcp
sudo cp dhcp/*.conf /opt/containerdata/ztpbootstrap/dhcp/

# 3. Start the service with DHCP
./setup.sh --http-only

# 4. Test with a DHCP client
sudo podman run -it --rm \
  --network dhcp-test-net \
  --cap-add NET_RAW \
  alpine sh -c 'apk add dhclient && dhclient -v eth0'
```

## Troubleshooting

### Check DHCP Server Logs

```bash
# View real-time logs
sudo podman logs -f ztpbootstrap-dhcp

# Check Kea log files
sudo cat /opt/containerdata/ztpbootstrap/dhcp/logs/kea-dhcp4.log
```

### Check Lease Database

```bash
# View active leases
sudo podman exec ztpbootstrap-dhcp cat /var/lib/kea/dhcp4.leases
```

### Verify Configuration

```bash
# Validate JSON syntax
python3 -m json.tool dhcp/kea-dhcp4.conf

# Check configuration in running container
sudo podman exec ztpbootstrap-dhcp cat /etc/kea/kea-dhcp4.conf
```

### Common Issues

#### DHCP Server Not Responding

1. Check container is running: `sudo podman ps | grep dhcp`
2. Check container has network capabilities: `sudo podman inspect ztpbootstrap-dhcp | grep -A5 Cap`
3. Check interface binding in logs: `sudo podman logs ztpbootstrap-dhcp | grep interface`

#### Wrong IP Range Assigned

1. Verify subnet configuration in `kea-dhcp4.conf`
2. Check network configuration: `sudo podman network inspect <network-name>`
3. Clear lease database: `sudo rm /opt/containerdata/ztpbootstrap/dhcp/leases/*`

#### Bootstrap Script Not Accessible

1. Verify Option 67 in configuration: `grep boot-file-name dhcp/kea-dhcp4.conf`
2. Test nginx: `curl http://<server-ip>/bootstrap.py`
3. Check nginx container logs: `sudo podman logs ztpbootstrap-nginx`

## References

- [Kea DHCP Documentation](https://kea.readthedocs.io/)
- [Kea DHCPv4 Configuration](https://kea.readthedocs.io/en/latest/arm/dhcp4-srv.html)
- [DHCP Options Reference](https://www.iana.org/assignments/bootp-dhcp-parameters/bootp-dhcp-parameters.xhtml)
- [ZTP Bootstrap Documentation](../README.md)

## See Also

- [DHCP Implementation Plan](../docs/DHCP_IMPLEMENTATION_PLAN.md)
- [DHCP Testing Setup](../docs/DHCP_TESTING_SETUP.md)
- [DHCP Automated Testing](../docs/DHCP_AUTOMATED_TESTING.md)
