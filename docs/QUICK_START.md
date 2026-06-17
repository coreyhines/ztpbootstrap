# Quick Start Guide

Get your Arista ZTP Bootstrap Service up and running quickly.

## Lab Quickstart (5 minutes, no macvlan required)

The simplest way to try the service — uses the host's network stack and HTTP, so there is no need for a macvlan interface, a dedicated IP, or SSL certificates.

```bash
# 1. Install Podman
sudo dnf install podman          # Fedora
# sudo apt-get install podman    # Ubuntu 24.04

# 2. Clone and enter the repo
git clone https://github.com/coreyhines/ztpbootstrap.git
cd ztpbootstrap

# 3. Run setup — choose "host networking" and "HTTP-only" when prompted
./setup-interactive.sh
```

When the interactive setup asks:
- **Network mode**: choose **host** (no macvlan needed)
- **Protocol**: choose **HTTP-only** (no certs needed)
- **Domain / IP**: use your server's existing IP (e.g. `192.168.1.10`)

After setup, the bootstrap endpoint is available at `http://<host-ip>/bootstrap.py`.

> **Not for production.** HTTP exposes the bootstrap script without TLS encryption. Use the production path below for real deployments.

---

## Prerequisites

- **Podman ≥ 4.9** installed (tested with 4.9.3 on Ubuntu 24.04, 5.6.2 on Fedora 43)
- **Root/sudo access** for setup
- **Enrollment token** from CVaaS Device Registration page
- **SSL certificates** — or choose HTTP-only mode for lab/testing

**Tested distributions:**
- **Fedora 43** (ARM64) — Podman 5.6.2
- **Ubuntu 24.04** (ARM64) — Podman 4.9.3

**Preflight check** — run these before setup to catch common blockers:

```bash
# Podman installed and working?
podman --version

# systemd available (required for quadlet service management)?
systemctl --version

# For macvlan (production): network must exist before setup runs
podman network exists ztpbootstrap-net && echo "OK" || echo "Create it first: ./check-macvlan.sh"

# For host networking (lab): no macvlan check needed
```

## Installation

### Step 1: Install Podman

**Fedora 43 (RedHat/RPM-based):**
```bash
sudo dnf install podman
```

**Ubuntu 24.04 (Debian/APT-based):**
```bash
sudo apt update && sudo apt install podman
```

**Note:** These are tested configurations. Ubuntu 24.04 ships with Podman 4.9.3 by default. Fedora 43 ships with Podman 5.6.2 by default. Other distributions or Podman versions may work but have not been verified.

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

### Airgapped / Offline Install

For environments with no internet access on the target host, pre-pull images on an internet-connected machine and copy them over.

**On the internet-connected machine:**

```bash
# Pull all required images (versions from versions.env)
source versions.env
podman pull "$NGINX_IMAGE"
podman pull "$POSTGRES_IMAGE"
podman pull "$WEBUI_IMAGE"
podman pull "$KEA_IMAGE"

# Save to a single tarball
podman save \
    "$NGINX_IMAGE" \
    "$POSTGRES_IMAGE" \
    "$WEBUI_IMAGE" \
    "$KEA_IMAGE" \
    | gzip > ztpbootstrap-images.tar.gz

# Copy tarball + repo to the target host
scp ztpbootstrap-images.tar.gz user@target-host:/tmp/
rsync -a . user@target-host:/opt/ztpbootstrap-repo/
```

**On the target (airgapped) host:**

```bash
# Load all images
podman load < /tmp/ztpbootstrap-images.tar.gz

# Verify images are present
podman images | grep -E "nginx|postgres|fedora|kea"

# Run setup normally — it will use the local images
cd /opt/ztpbootstrap-repo
./setup-interactive.sh
```

The installer reads image tags from `versions.env` and Podman uses locally cached images when they match the expected tag. No registry access is needed after `podman load`.

> **Verify versions.env is committed** before copying the repo to the airgapped host so the image tags match what was saved.

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
