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
- **Prompt for Web UI admin password** (required for write operations)
- Generate `config.yaml` with your settings
- Optionally apply configuration and start services

**Note:** The admin password is required for write operations in the Web UI (upload scripts, delete, rename, restore backups, mark logs, view configuration). If you're upgrading from a previous installation, the password will be loaded from your existing `config.yaml`. Read-only operations (viewing status, scripts, logs) don't require authentication.

### Step 4: Verify Installation

```bash
# Check service status
sudo systemctl status ztpbootstrap

# Test health endpoint
curl -k https://ztpboot.example.com/health

# Access Web UI
# Navigate to: https://ztpboot.example.com/ui/
# Note: Write operations require authentication (password set during setup)
```

## Upgrading Existing Installation

If you have an existing installation and want to upgrade to a newer version:

```bash
# Pull latest changes
cd ztpbootstrap
git pull origin main

# Run upgrade (non-interactive, preserves all values)
sudo ./setup-interactive.sh --upgrade
```

**What `--upgrade` does:**
- ✅ **Requires existing installation** - Errors if no previous install detected
- ✅ **Creates automatic backup** - Backs up before making changes (required)
- ✅ **Preserves all values** - Uses all previous configuration (domain, IPs, tokens, etc.)
- ✅ **Non-interactive** - No prompts, runs automatically
- ✅ **Stops services** - Gracefully stops running services before upgrade
- ✅ **Applies changes** - Updates all configuration files automatically
- ✅ **Starts services** - Restarts services after upgrade completes

**Upgrade process:**
1. Detects existing installation
2. Loads all previous values from `config.yaml`, `ztpbootstrap.env`, container files, and `nginx.conf`
3. Creates backup in `.ztpbootstrap-backups/` directory
4. Stops running services gracefully
5. Cleans installation directories
6. Applies configuration using previous values
7. Starts services automatically

**Note:** The admin password from your existing `config.yaml` will be preserved automatically.

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

## Web UI Authentication

The Web UI uses password-based authentication for write operations:

- **Read-only access**: No authentication required (viewing status, scripts, logs, device connections)
- **Write operations**: Authentication required (upload scripts, delete, rename, restore backups, mark logs, view configuration)

**Setting the admin password:**
- During `setup-interactive.sh`: You'll be prompted to set an admin password (required)
- Upgrading from existing installation: The password will be automatically loaded from your existing `config.yaml` or backup
- After installation: Run `setup-interactive.sh` again and set the password, or manually edit `config.yaml` (see [SECURITY.md](SECURITY.md) for details)

**Using the Web UI:**
1. Navigate to `https://ztpboot.example.com/ui/`
2. For write operations, click any action button (Upload, Delete, etc.)
3. Enter the admin password when prompted
4. Your session will remain active for the configured timeout period

**Changing the password:**
- Click your profile icon (top right) → "Change Password"
- Requires current password and new password (minimum 8 characters)

For more security details, see [SECURITY.md](SECURITY.md).

## Next Steps

1. **Configure DHCP server** to point devices to the bootstrap script
2. **Test with a device** - Boot an Arista switch and verify it enrolls
3. **Monitor logs** - Watch for enrollment activity

## Getting Help

- **Troubleshooting**: See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- **Testing**: See [TESTING.md](TESTING.md)
- **Full Documentation**: See [../README.md](../README.md)
