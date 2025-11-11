# Quick Start Guide

Get your Arista ZTP Bootstrap Service up and running quickly.

## Prerequisites

- **Podman** installed
- **Root/sudo access** for setup
- **Enrollment token** from CVaaS Device Registration page
- **SSL certificates** (or use HTTP-only mode for testing)

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

### Step 2: Clone Repository

```bash
git clone https://github.com/coreyhines/ztpbootstrap.git
cd ztpbootstrap
```

### Step 3: Run Interactive Setup

**Recommended for first-time users:**

```bash
# Install yq if needed
# macOS: brew install yq
# Linux: sudo dnf install yq  # or apt-get install yq

# Run interactive setup
./setup-interactive.sh
```

The interactive setup will:
- Prompt for all configuration (paths, network, CVaaS, certificates)
- Generate `config.yaml` with your settings
- Optionally apply configuration and start services

### Step 4: Verify Installation

```bash
# Check service status
sudo systemctl status ztpbootstrap

# Test health endpoint
curl -k https://ztpboot.example.com/health

# Access Web UI
# Navigate to: https://ztpboot.example.com/ui/
```

## Common Scenarios

### HTTP-Only Mode (Testing)

```bash
# Run interactive setup and choose HTTP-only mode
./setup-interactive.sh
# Select HTTP-only when prompted

# Or use automated setup
sudo ./setup.sh --http-only
```

**Update DHCP server:**
```dhcp
option bootfile-name "http://ztpboot.example.com/bootstrap.py";
```

### Production Setup with HTTPS

```bash
# 1. Set up SSL certificates
sudo mkdir -p /opt/containerdata/certs/wild

# Option A: Let's Encrypt
sudo certbot certonly --standalone -d ztpboot.example.com
sudo cp /etc/letsencrypt/live/ztpboot.example.com/fullchain.pem /opt/containerdata/certs/wild/
sudo cp /etc/letsencrypt/live/ztpboot.example.com/privkey.pem /opt/containerdata/certs/wild/

# Option B: Use your certificates
sudo cp your-cert.pem /opt/containerdata/certs/wild/fullchain.pem
sudo cp your-key.pem /opt/containerdata/certs/wild/privkey.pem

# 2. Run interactive setup
./setup-interactive.sh
```

**Update DHCP server:**
```dhcp
option bootfile-name "https://ztpboot.example.com/bootstrap.py";
```

## DHCP Configuration

Configure your DHCP server to provide the bootstrap script URL via DHCP Option 67:

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

## Next Steps

1. **Configure DHCP server** to point devices to the bootstrap script
2. **Test with a device** - Boot an Arista switch and verify it enrolls
3. **Monitor logs** - Watch for enrollment activity

## Getting Help

- **Troubleshooting**: See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- **Testing**: See [TESTING.md](TESTING.md)
- **Full Documentation**: See [../README.md](../README.md)
