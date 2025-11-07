# Quick Start Guide

Get your Arista ZTP Bootstrap Service up and running in minutes!

## Prerequisites

- **Podman** installed ([installation instructions](#installing-podman))
- **Root/sudo access** for setup
- **Network access** to CVaaS (or your CVaaS instance)
- **Enrollment token** from CVaaS Device Registration page

## Installation

### Step 1: Install Podman

**Fedora / RHEL / Rocky Linux:**
```bash
sudo dnf install podman
```

**Ubuntu / Debian:**
```bash
sudo apt update && sudo apt install podman
```

### Step 2: Clone or Download Files

```bash
# Clone the repository
git clone <repository-url>
cd ztpbootstrap

# Or download and extract the files
```

### Step 3: Choose Your Setup Method

#### Option A: Interactive Setup (Recommended for First-Time Users)

```bash
# Run interactive setup
./setup-interactive.sh

# Follow the prompts to configure:
# - Directory paths
# - Network settings (domain, IPs, ports)
# - CVaaS configuration (address, enrollment token)
# - SSL certificate settings
# - Container and service settings

# The script will generate config.yaml and optionally apply it
```

#### Option B: Manual Setup

```bash
# 1. Create directories
sudo mkdir -p /opt/containerdata/ztpbootstrap
sudo mkdir -p /opt/containerdata/certs/wild

# 2. Copy files
sudo cp bootstrap.py nginx.conf setup.sh /opt/containerdata/ztpbootstrap/

# 3. Configure bootstrap.py
sudo vi /opt/containerdata/ztpbootstrap/bootstrap.py
# Edit cvAddr and enrollmentToken in the USER INPUT section

# 4. Set up SSL certificates (or use HTTP-only for testing)
# See SSL Certificates section below

# 5. Run setup
cd /opt/containerdata/ztpbootstrap
sudo ./setup.sh
```

## Common Scenarios

### Scenario 1: Quick Test with HTTP-Only Mode

Perfect for lab environments or initial testing:

```bash
# 1. Run interactive setup
./setup-interactive.sh
# Choose HTTP-only mode when prompted

# 2. Or manually set up
sudo mkdir -p /opt/containerdata/ztpbootstrap
sudo cp bootstrap.py nginx.conf setup.sh /opt/containerdata/ztpbootstrap/
sudo vi /opt/containerdata/ztpbootstrap/bootstrap.py  # Set enrollment token
cd /opt/containerdata/ztpbootstrap
sudo ./setup.sh --http-only
```

**Update your DHCP server:**
```dhcp
option bootfile-name "http://ztpboot.example.com/bootstrap.py";
```

### Scenario 2: Production Setup with HTTPS

For production deployments:

```bash
# 1. Set up SSL certificates first
sudo mkdir -p /opt/containerdata/certs/wild

# Option A: Let's Encrypt (recommended)
sudo certbot certonly --standalone -d ztpboot.example.com
sudo cp /etc/letsencrypt/live/ztpboot.example.com/fullchain.pem /opt/containerdata/certs/wild/
sudo cp /etc/letsencrypt/live/ztpboot.example.com/privkey.pem /opt/containerdata/certs/wild/

# Option B: Use your organization's certificates
sudo cp your-cert.pem /opt/containerdata/certs/wild/fullchain.pem
sudo cp your-key.pem /opt/containerdata/certs/wild/privkey.pem

# 2. Run interactive setup
./setup-interactive.sh
# Choose HTTPS mode and configure all settings

# 3. Or use manual setup
sudo ./setup.sh
```

**Update your DHCP server:**
```dhcp
option bootfile-name "https://ztpboot.example.com/bootstrap.py";
```

### Scenario 3: Custom Paths and Configuration

If you want to use different directories:

```bash
# 1. Run interactive setup
./setup-interactive.sh

# 2. When prompted, customize:
#    - Script directory: /custom/path/ztpbootstrap
#    - Certificate directory: /custom/path/certs
#    - All other paths as needed

# 3. Apply configuration
./update-config.sh config.yaml
```

### Scenario 4: Systemd Integration (Production)

For automatic startup and service management:

```bash
# 1. Complete setup (interactive or manual)
./setup-interactive.sh

# 2. Copy systemd quadlet file
sudo mkdir -p /etc/containers/systemd/ztpbootstrap
sudo cp systemd/ztpbootstrap.container /etc/containers/systemd/ztpbootstrap/

# 3. Update paths in quadlet file if needed
sudo vi /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container

# 4. Reload systemd and start service
sudo systemctl daemon-reload
sudo systemctl start ztpbootstrap
sudo systemctl enable ztpbootstrap  # Enable on boot
```

## SSL Certificates

### Option 1: Let's Encrypt (Recommended)

```bash
# Install certbot
sudo apt install certbot  # Debian/Ubuntu
sudo dnf install certbot  # Fedora/RHEL

# Obtain certificate
sudo certbot certonly --standalone -d ztpboot.example.com

# Copy to service directory
sudo cp /etc/letsencrypt/live/ztpboot.example.com/fullchain.pem /opt/containerdata/certs/wild/
sudo cp /etc/letsencrypt/live/ztpboot.example.com/privkey.pem /opt/containerdata/certs/wild/

# Set up auto-renewal (optional but recommended)
sudo systemctl enable certbot.timer
```

### Option 2: Self-Signed (Testing Only)

```bash
sudo mkdir -p /opt/containerdata/certs/wild
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /opt/containerdata/certs/wild/privkey.pem \
  -out /opt/containerdata/certs/wild/fullchain.pem \
  -subj "/CN=ztpboot.example.com" \
  -addext "subjectAltName=DNS:ztpboot.example.com"
```

### Option 3: Organization CA

```bash
# Copy your certificates
sudo cp your-cert.pem /opt/containerdata/certs/wild/fullchain.pem
sudo cp your-key.pem /opt/containerdata/certs/wild/privkey.pem
sudo chmod 600 /opt/containerdata/certs/wild/privkey.pem
```

## Network Configuration

### Assign IP Addresses

```bash
# Identify your network interface
ip addr show

# Assign IPv4 address
sudo ip addr add 10.0.0.10/24 dev eth0

# Assign IPv6 address (if needed)
sudo ip -6 addr add 2001:db8::10/64 dev eth0

# Make persistent (example for NetworkManager)
sudo nmcli connection modify <connection-name> ipv4.addresses 10.0.0.10/24
sudo nmcli connection up <connection-name>
```

### Configure DHCP Server

**ISC DHCP:**
```dhcp
subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.100 10.0.0.200;
    option routers 10.0.0.1;
    option bootfile-name "https://ztpboot.example.com/bootstrap.py";
}
```

**Kea DHCP:**
```json
{
  "option-data": [
    {
      "name": "boot-file-name",
      "data": "https://ztpboot.example.com/bootstrap.py"
    }
  ]
}
```

## Verification

### Test the Service

```bash
# Check container is running
podman ps | grep ztpbootstrap

# Test health endpoint
curl -k https://ztpboot.example.com/health
# Should return: healthy

# Test bootstrap script endpoint
curl -k https://ztpboot.example.com/bootstrap.py | head -20

# View logs
podman logs ztpbootstrap
# Or with systemd:
journalctl -u ztpbootstrap -f
```

### Run Test Scripts

```bash
# Quick validation
./ci-test.sh

# Full integration test
sudo ./integration-test.sh --http-only

# Service validation
sudo ./test-service.sh
```

## Next Steps

1. **Configure your DHCP server** to point devices to the bootstrap script
2. **Test with a device** - Boot an Arista switch and verify it enrolls
3. **Monitor logs** - Watch for enrollment activity
4. **Set up monitoring** - Configure health checks and alerts
5. **Review documentation** - See [README.md](README.md) for detailed information

## Common Issues

### Service Won't Start
- Check logs: `podman logs ztpbootstrap` or `journalctl -u ztpbootstrap`
- Verify SSL certificates exist and are readable
- Check port availability: `sudo ss -tlnp | grep 443`

### Devices Can't Reach Bootstrap Script
- Verify network connectivity
- Check firewall rules
- Verify DHCP configuration
- Test with curl: `curl -k https://ztpboot.example.com/bootstrap.py`

### SSL Certificate Issues
- Verify certificate files exist: `ls -la /opt/containerdata/certs/wild/`
- Check certificate validity: `openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout`
- Verify domain matches: Certificate must match your domain name

For more detailed troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Getting Help

- **Documentation**: See [README.md](README.md) for complete documentation
- **Troubleshooting**: See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues
- **Testing**: See [TESTING.md](TESTING.md) for test procedures
