# DHCP Testing Setup Guide

This guide explains how to set up an isolated DHCP testing environment while maintaining web UI access.

## Problem Statement

When testing DHCP services, you need:
1. **Web UI Access**: Access the web UI at `http://localhost:8080/ui`
2. **DHCP Isolation**: Isolate DHCP client and server from existing DHCP infrastructure

## Solution Approaches

### Option 1: Macvlan Network with Port Forwarding (Recommended for Isolation)

This approach provides the best isolation for DHCP testing:

1. **Create the macvlan network** using the helper script:
   ```bash
   sudo ./setup-dhcp-testing.sh
   ```

   This script will:
   - Detect your network interface and subnet automatically
   - Create a macvlan network with the correct subnet
   - Update your `config.yaml` with the correct IP address

2. **Ensure port forwarding is configured** (if running in a VM):
   - If using QEMU: `hostfwd=tcp::8080-:80`
   - If using other virtualization: Forward host port 8080 to VM port 80

3. **Run setup**:
   ```bash
   ./setup-interactive.sh --non-interactive
   ```

4. **Start services**:
   ```bash
   sudo systemctl start ztpbootstrap-pod
   sudo systemctl start ztpbootstrap-nginx
   sudo systemctl start ztpbootstrap-webui
   ```

5. **Access web UI**: `http://localhost:8080/ui`

**Advantages**:
- Complete isolation from existing DHCP infrastructure
- DHCP server only serves clients on the macvlan network
- No conflicts with existing DHCP servers

**Disadvantages**:
- Requires port forwarding for web UI access
- More complex network setup

### Option 2: Host Networking Mode (Simpler, Less Isolation)

This approach is simpler but provides less isolation:

1. **Enable host networking** in `config.yaml`:
   ```yaml
   container:
     host_network: true
   ```

2. **Run setup**:
   ```bash
   ./setup-interactive.sh --non-interactive
   ```

3. **Start services**:
   ```bash
   sudo systemctl start ztpbootstrap-pod
   ```

4. **Access web UI**: `http://localhost:8080/ui` (if port forwarding is set up)

**Advantages**:
- Simpler setup
- Direct access to web UI
- Works without port forwarding (if accessing from VM directly)

**Disadvantages**:
- DHCP server binds to all host interfaces
- May conflict with existing DHCP servers
- Less isolation for testing

### Option 3: Hybrid Approach (Advanced)

For maximum flexibility, you can:
1. Use host networking for web UI access
2. Configure DHCP to bind to a specific isolated interface (veth pair or macvlan sub-interface)

This requires manual interface setup and DHCP configuration.

## Troubleshooting

### Network doesn't exist error

If you see:
```
[WARN] Network 'ztpbootstrap-net' does not exist
```

**Solution**: Run the setup script:
```bash
sudo ./setup-dhcp-testing.sh
```

### IP address mismatch

If your config has an IP that doesn't match your subnet:

**Solution**: The `setup-dhcp-testing.sh` script will automatically:
1. Detect the correct subnet from your interface
2. Update your config with a suitable IP in that subnet

### Web UI not accessible on localhost:8080

**Check 1**: Verify port forwarding is set up:
```bash
# On host, check if port 8080 is forwarded
netstat -tlnp | grep 8080
# Or check VM port forwarding configuration
```

**Check 2**: Verify nginx is listening on port 80:
```bash
# Inside VM
sudo netstat -tlnp | grep :80
# Or
sudo ss -tlnp | grep :80
```

**Check 3**: If using macvlan, verify pod has network access:
```bash
sudo podman exec ztpbootstrap-nginx curl -I http://localhost:5000
```

**Solution**: If port forwarding isn't available, enable host networking:
```yaml
container:
  host_network: true
```

### DHCP conflicts with existing server

**Symptom**: Clients receive IPs from the wrong DHCP server

**Solution**: Use macvlan network (Option 1) to isolate DHCP traffic

### Cannot create macvlan network

**Error**: `Failed to create macvlan network`

**Possible causes**:
1. Insufficient privileges (requires root)
2. Interface doesn't support macvlan
3. Network already exists with different configuration

**Solutions**:
1. Run with `sudo`
2. Check interface support: `ip link add test-macvlan link eth0 type macvlan` (then delete it)
3. Remove existing network: `sudo podman network rm ztpbootstrap-net`

## Quick Start for Your Current Situation

Based on your VM setup (eth0 on 172.16.0.0/24):

1. **Create the network**:
   ```bash
   sudo ./setup-dhcp-testing.sh
   ```

2. **Verify config was updated**:
   ```bash
   cat config.yaml | grep -A 5 "network:"
   # Should show network: ztpbootstrap-net and ipv4: 172.16.0.10 (or similar)
   ```

3. **Run setup**:
   ```bash
   ./setup-interactive.sh --non-interactive
   ```

4. **Start services**:
   ```bash
   sudo systemctl start ztpbootstrap-pod
   sudo systemctl start ztpbootstrap-nginx
   sudo systemctl start ztpbootstrap-webui
   ```

5. **Access web UI**: `http://localhost:8080/ui`

6. **For DHCP testing**: Configure DHCP in the web UI, then test with a client on the same subnet (172.16.0.0/24)

## Network Configuration Details

### Macvlan Network

The macvlan network creates a virtual interface that shares the physical interface's MAC address space. This allows:
- Complete isolation of network traffic
- Direct L2 connectivity to the physical network
- No NAT or bridging overhead

### Subnet Detection

The setup script automatically detects:
- **Interface**: Primary ethernet interface (eth0, ens*, etc.)
- **Subnet**: From interface IP configuration (e.g., 172.16.0.15/24 → 172.16.0.0/24)
- **Gateway**: From default route or first IP in subnet
- **Pod IP**: Automatically selected (usually .10, or .100 if .10 is gateway)

### IP Address Selection

The script selects a pod IP that:
- Is in the detected subnet
- Doesn't conflict with the gateway (avoids .1)
- Is suitable for a server (typically .10 or .100)

You can manually override this in `config.yaml` if needed.

## Additional Resources

- [DHCP Implementation Plan](./DHCP_IMPLEMENTATION_PLAN.md)
- [DHCP Testing Documentation](./DHCP_TESTING.md)
- [Troubleshooting Guide](./TROUBLESHOOTING.md)
