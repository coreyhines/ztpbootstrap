# macOS Firewall Rules to Block QEMU's DHCP Server

## Overview

QEMU's user-mode networking includes a built-in DHCP server that runs on `10.0.2.2:67`. To allow only Kea DHCP server to respond to DHCP requests, you can block QEMU's DHCP server using macOS's packet filter (`pfctl`).

## Method 1: Using the Script

```bash
# Enable blocking
sudo ./dev/scripts/macos-block-qemu-dhcp.sh enable

# Check status
sudo ./dev/scripts/macos-block-qemu-dhcp.sh status

# Disable blocking
sudo ./dev/scripts/macos-block-qemu-dhcp.sh disable
```

## Method 2: Manual pfctl Rules

### Step 1: Enable pfctl (if not already enabled)

```bash
sudo pfctl -e
```

### Step 2: Create a rules file

Create `/tmp/qemu-dhcp-block.pf.conf`:

```
# Block QEMU's DHCP server (10.0.2.2:67)
block drop in quick proto udp from 10.0.2.2 to any port 67

# Allow everything else
pass
```

### Step 3: Load the rules

```bash
sudo pfctl -f /tmp/qemu-dhcp-block.pf.conf
```

### Step 4: Verify rules are active

```bash
sudo pfctl -s rules | grep 10.0.2.2
```

### Step 5: Disable when done

```bash
# Create a pass-all rules file
echo "pass" | sudo pfctl -f -

# Or disable pfctl entirely
sudo pfctl -d
```

## Method 3: Using QEMU Options (Alternative)

Instead of blocking with firewall rules, you can disable QEMU's DHCP server entirely by modifying the QEMU command:

```bash
# Disable DHCP in QEMU's user network
-netdev user,id=net0,dhcpstart=10.0.2.50,net=10.0.2.0/24,hostfwd=tcp::2222-:22

# Or use a different network mode that doesn't include DHCP
-netdev tap,id=net0,ifname=tap0,script=no,downscript=no
```

## Method 4: Application Firewall (GUI)

1. Open **System Settings** > **Network** > **Firewall**
2. Click **Options...**
3. Add a rule to block UDP port 67 from IP `10.0.2.2`

**Note:** The Application Firewall may not be as effective as `pfctl` for this use case.

## Verification

After enabling the firewall rules, test that QEMU's DHCP is blocked:

```bash
# From inside the VM, try to get a DHCP lease
# It should only receive offers from Kea (10.0.2.50-10.0.2.55 range)
# and not from QEMU (10.0.2.15)
```

## Important Notes

1. **pfctl rules are not persistent** - They will be lost after reboot unless you configure them to load at startup
2. **QEMU's DHCP runs in userspace** - The firewall rules block the network traffic, but QEMU's DHCP process may still be running
3. **VM network isolation** - QEMU's user-mode networking creates a NAT'd network, so the firewall rules on the macOS host will affect traffic to/from the VM
4. **Alternative approach** - Consider using QEMU's `-netdev tap` mode with a bridge for more control over the network

## Making Rules Persistent

To make the rules persistent across reboots:

1. Create `/etc/pf.anchors/qemu-dhcp-block` with your rules
2. Add to `/etc/pf.conf`:
   ```
   anchor "qemu-dhcp-block"
   load anchor "qemu-dhcp-block" from "/etc/pf.anchors/qemu-dhcp-block"
   ```
3. Enable pfctl at boot (requires launchd configuration)
