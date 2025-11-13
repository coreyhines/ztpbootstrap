# Contributing Guide

This document describes the development workflow for testing and iterating on the ZTP Bootstrap Service, particularly for testing the interactive setup script with upgrade scenarios.

## Overview

The development workflow uses a test VM to safely test changes to `setup-interactive.sh` and related scripts. The workflow simulates an upgrade scenario by:

1. Creating a fresh test VM
2. Restoring a production backup (simulating an existing installation)
3. Running the interactive setup script to test upgrade functionality

This ensures that new features and fixes work correctly with existing installations.

---

## Prerequisites

### Required Tools

- **QEMU** with Apple Hypervisor Framework (HVF) support (macOS) or KVM (Linux)
- **SSH** access to production server (your production server hostname)
- **Git** for cloning the repository
- **yq** for YAML processing (installed automatically by scripts)

### Required Access

- SSH access to production server to fetch backups
- Ability to create and manage VMs on your development machine
- Root/sudo access in the test VM (handled automatically)

### User Configuration

**Note:** Throughout this document, replace `user` with your actual logged-in username. The VM creation scripts automatically detect your current user and configure SSH access accordingly. For example, if you're logged in as `alice`, use `alice` instead of `user` in all commands.

---

## Development Workflow

### Standard Iteration Cycle

The standard development iteration follows these steps:

```
1. Create/Reset VM
   ↓
2. Restore Production Backup
   ↓
3. Test Interactive Setup (with your changes)
   ↓
4. Verify Services Running
   ↓
5. Test New Features/Fixes
   ↓
6. Iterate (make changes, repeat from step 1)
```

---

## Step-by-Step Workflow

### Step 1: Create Test VM

The `test-interactive-setup.sh` script automates VM creation, but you can also create it manually.

#### Automated VM Creation

```bash
# From your development machine
cd ~/path/to/ztpbootstrap

# Create a new VM and restore backup
./test-interactive-setup.sh

# Or skip VM creation if you already have one running
./test-interactive-setup.sh --skip-vm
```

**What happens:**
- Downloads Fedora 43 Cloud image (if not already present)
- Creates QEMU VM with port forwarding (2222→22, 8080→80, 8443→443)
- Configures cloud-init with SSH keys for your user
- Waits for SSH to become ready
- Clones repository to VM

**VM Details:**
- **Name:** `ztpbootstrap-test-vm`
- **SSH:** `ssh user@localhost -p 2222` (replace `user` with your username)
- **Port Forwarding:**
  - HTTP: `localhost:8080` → VM:80
  - HTTPS: `localhost:8443` → VM:443
  - SSH: `localhost:2222` → VM:22

#### Manual VM Creation

If you prefer to create the VM manually:

```bash
# Use vm-create-native.sh directly
./vm-create-native.sh --download fedora --type cloud --arch aarch64 --version 43 --headless
```

**Note:** The VM creation scripts (`vm-create-native.sh`, `test-interactive-setup.sh`) are in `.gitignore` and are development tools, not part of the standard deployment.

#### Supported Distributions and Architectures

The `vm-create-native.sh` script can download and create VMs for the following distributions:

| Distribution | Version | Architecture | Type | Tested | Notes |
|--------------|---------|--------------|------|--------|-------|
| Fedora | 43 | aarch64 | cloud | ✅ Yes | Fully tested, recommended for development |
| Ubuntu | 24.04 LTS | arm64 (aarch64) | cloud | ✅ Yes | Fully tested, use `--version 24.04` |

**Additional Distributions Available for Testing** (available on both x86_64 and aarch64, can be downloaded/created by `vm-create-native.sh`):

| Distribution | Cloud Image Availability | Architecture Support | Script Support | Notes |
|--------------|--------------------------|----------------------|----------------|-------|
| Rocky Linux | ✅ Yes | aarch64, x86_64 | ✅ Yes | RHEL-compatible, good for enterprise testing |
| AlmaLinux | ✅ Yes | aarch64, x86_64 | ✅ Yes | RHEL-compatible alternative |
| CentOS Stream | ✅ Yes | aarch64, x86_64 | ✅ Yes | Rolling RHEL preview |
| openSUSE Leap | ✅ Yes | aarch64, x86_64 | ✅ Yes | Stable SUSE release, LTS-like cycle, good for production testing |

**Notes:**
- **Tested**: Distribution/architecture combination has been verified to work with the ZTP Bootstrap Service. Only Fedora 43 and Ubuntu 24.04 have been tested.
- **Script Support**: The `vm-create-native.sh` script can download cloud images and create VMs for these distributions. However, they have **not been tested** with the ZTP Bootstrap Service. These are opportunities for contributors to expand testing coverage by following the testing workflow described in this document.
- **Type**: `cloud` = pre-built disk image (boots directly, cloud-init ready), `iso` = installer image (requires installation)
- **Architecture**: `aarch64` = ARM64 (native on Apple Silicon), `x86_64` = Intel/AMD (emulated on Apple Silicon)
- Cloud images are recommended for development/testing as they boot faster and have cloud-init pre-configured
- To add support for additional distributions in the script, modify `vm-create-native.sh`'s `download_iso()` function

---

### Step 2: Restore Production Backup

The test script automatically fetches and restores a backup from your production server.

#### Automated Restore (via test script)

The `test-interactive-setup.sh` script automatically:
1. Fetches the latest backup from your production server (configured in the script)
2. Copies it to the VM
3. Extracts and restores:
   - `/opt/containerdata/ztpbootstrap/`
   - `/etc/containers/systemd/ztpbootstrap/`
   - `/opt/containerdata/certs/wild/` (if present)

#### Manual Restore

If you need to restore manually:

```bash
# SSH into the VM (replace 'user' with your username)
ssh user@localhost -p 2222

# Run the restore script (it detects it's running inside the VM)
cd ~/ztpbootstrap
./restore-backup-from-fedora1.sh
```

**Note:** The restore script (`restore-backup-from-fedora1.sh`) references a production server hostname. Update the script or set environment variables to point to your production server.

**What gets restored:**
- All configuration files (`nginx.conf`, `ztpbootstrap.env`, etc.)
- Systemd quadlet files (`.pod`, `.container`)
- SSL certificates (if present)
- Any custom scripts or configurations

**Note:** The restore script (`restore-backup-from-fedora1.sh`) is in `.gitignore` and is a development tool.

---

### Step 3: Test Interactive Setup

After restoring the backup, test your changes to `setup-interactive.sh`:

```bash
# SSH into the VM (replace 'user' with your username)
ssh user@localhost -p 2222

# Navigate to repository
cd ~/ztpbootstrap

# Pull latest changes (if you've pushed them)
git pull

# Run interactive setup
./setup-interactive.sh
```

**What to test:**
- ✅ Previous installation detection
- ✅ Loading existing values as defaults
- ✅ Backup creation (if prompted)
- ✅ Service management (stopping old services)
- ✅ Directory cleanup
- ✅ Configuration updates
- ✅ Service startup

**Non-Interactive Testing:**

For automated testing or CI/CD, use non-interactive mode:

```bash
./setup-interactive.sh --non-interactive
```

This mode:
- Uses detected defaults automatically
- Auto-answers all prompts
- Creates backup automatically
- Starts services automatically

---

### Step 4: Verify Services

After running the interactive setup, verify everything works:

```bash
# Check service status
sudo systemctl status ztpbootstrap
sudo systemctl status ztpbootstrap-nginx
sudo systemctl status ztpbootstrap-webui

# Check containers
sudo podman ps --filter pod=ztpbootstrap

# Test endpoints
curl -k https://localhost/health
curl -k https://localhost/bootstrap.py

# Access Web UI
# Open browser to: https://localhost:8443/ui/
```

---

### Step 5: Iterate on Changes

After testing, make your changes and iterate:

```bash
# On your development machine
cd ~/path/to/ztpbootstrap

# Make your changes to setup-interactive.sh (or other files)
vim setup-interactive.sh

# Commit and push (if ready)
git add setup-interactive.sh
git commit -m "Your change description"
git push

# Or copy changes directly to VM for quick testing (replace 'user' with your username)
scp -P 2222 setup-interactive.sh user@localhost:~/ztpbootstrap/

# Then SSH in and test again (replace 'user' with your username)
ssh user@localhost -p 2222
cd ~/ztpbootstrap
./setup-interactive.sh
```

---

## Quick Reference Commands

### VM Management

```bash
# Create new VM (from scratch)
./test-interactive-setup.sh

# Use existing VM (skip creation)
./test-interactive-setup.sh --skip-vm

# Stop VM (kill QEMU process)
pkill -f qemu-system-aarch64

# SSH into VM (replace 'user' with your username)
ssh user@localhost -p 2222

# Check if VM is running
ps aux | grep qemu-system-aarch64
```

### Backup Management

```bash
# Create backup on production server (replace 'user' and 'production-server' with your values)
ssh user@production-server
sudo bash -c 'BACKUP_DIR="/tmp/ztpbootstrap-backup-$(date +%Y%m%d_%H%M%S)"; mkdir -p "$BACKUP_DIR"; cp -r /opt/containerdata/ztpbootstrap "$BACKUP_DIR/containerdata_ztpbootstrap" && cp -r /etc/containers/systemd/ztpbootstrap "$BACKUP_DIR/etc_containers_systemd_ztpbootstrap" && cp -r /opt/containerdata/certs/wild "$BACKUP_DIR/certs_wild" && cd /tmp && tar -czf ~user/ztpbootstrap-backup-$(date +%Y%m%d_%H%M%S).tar.gz -C "$BACKUP_DIR" . && rm -rf "$BACKUP_DIR" && echo "Backup: ~user/ztpbootstrap-backup-$(date +%Y%m%d_%H%M%S).tar.gz"'

# Restore backup in VM (from inside VM)
./restore-backup-from-fedora1.sh

# Restore backup in VM (from host, replace 'user' with your username)
ssh -p 2222 user@localhost './restore-backup-from-fedora1.sh'
```

### Testing Commands

```bash
# Run interactive setup (interactive mode)
./setup-interactive.sh

# Run interactive setup (non-interactive mode)
./setup-interactive.sh --non-interactive

# Run upgrade mode (requires existing installation, non-interactive)
./setup-interactive.sh --upgrade

# Check service status
sudo systemctl status ztpbootstrap
sudo systemctl status ztpbootstrap-nginx
sudo systemctl status ztpbootstrap-webui

# View service logs
sudo journalctl -u ztpbootstrap -f
sudo journalctl -u ztpbootstrap-nginx -f
sudo journalctl -u ztpbootstrap-webui -f

# Test endpoints
curl -k https://localhost/health
curl -k https://localhost/bootstrap.py
curl -k https://localhost:8443/ui/
```

---

## Common Development Scenarios

### Scenario 1: Testing New Feature in Interactive Setup

**Goal:** Test a new feature in `setup-interactive.sh` with a real production backup.

```bash
# 1. Create fresh VM
./test-interactive-setup.sh

# 2. Wait for VM to be ready (script does this automatically)

# 3. SSH into VM (replace 'user' with your username)
ssh user@localhost -p 2222

# 4. Pull your changes (or copy them manually)
cd ~/ztpbootstrap
git pull  # or scp your changes from host

# 5. Run interactive setup
./setup-interactive.sh

# 6. Test your new feature
# ... interact with prompts, verify behavior ...

# 7. Verify services started correctly
sudo systemctl status ztpbootstrap

# 8. Test the feature end-to-end
curl -k https://localhost/health
```

### Scenario 2: Quick Iteration (Reusing VM)

**Goal:** Quickly test changes without recreating the VM.

```bash
# 1. Use existing VM
./test-interactive-setup.sh --skip-vm

# 2. Copy your changes to VM (replace 'user' with your username)
scp -P 2222 setup-interactive.sh user@localhost:~/ztpbootstrap/

# 3. SSH in and test (replace 'user' with your username)
ssh user@localhost -p 2222
cd ~/ztpbootstrap
./setup-interactive.sh
```

### Scenario 3: Testing Upgrade Path

**Goal:** Verify that the interactive setup correctly upgrades an existing installation.

```bash
# 1. Create VM and restore backup (simulates existing installation)
./test-interactive-setup.sh

# 2. SSH into VM (replace 'user' with your username)
ssh user@localhost -p 2222

# 3. Verify backup was restored
ls -la /opt/containerdata/ztpbootstrap/
cat /opt/containerdata/ztpbootstrap/ztpbootstrap.env

# 4. Run interactive setup (should detect previous installation)
cd ~/ztpbootstrap
./setup-interactive.sh

# Or use upgrade mode (non-interactive, preserves all values)
./setup-interactive.sh --upgrade

# 5. Verify it detected existing values
# Check that prompts show existing values as defaults (interactive mode)
# Or verify all values were preserved automatically (upgrade mode)

# 6. Complete the upgrade
# Accept defaults or modify as needed (interactive mode)
# Or verify automatic upgrade completed (upgrade mode)
# Verify backup was created
# Verify services were stopped and restarted

# 7. Verify upgrade succeeded
sudo systemctl status ztpbootstrap
curl -k https://localhost/health
```

### Scenario 4: Testing Non-Interactive Mode

**Goal:** Test automated/CI scenarios with non-interactive mode.

```bash
# 1. Create VM and restore backup
./test-interactive-setup.sh

# 2. SSH into VM (replace 'user' with your username)
ssh user@localhost -p 2222

# 3. Run in non-interactive mode
cd ~/ztpbootstrap
./setup-interactive.sh --non-interactive

# 4. Verify it completed without prompts
# Should use detected defaults automatically
# Should create backup automatically
# Should start services automatically

# 5. Verify services are running
sudo systemctl status ztpbootstrap
```

---

## Troubleshooting

### VM Won't Start

```bash
# Check if QEMU is running
ps aux | grep qemu-system-aarch64

# Check for port conflicts
lsof -i :2222
lsof -i :8080
lsof -i :8443

# Kill existing QEMU processes
pkill -f qemu-system-aarch64

# Check disk space
df -h
```

### SSH Connection Fails

```bash
# Check if VM is running
ps aux | grep qemu-system-aarch64

# Check if port 2222 is listening
nc -zv localhost 2222

# Check VM logs (if available)
tail -f /tmp/qemu-ztpbootstrap-test-vm.log

# Try connecting with verbose SSH (replace 'user' with your username)
ssh -vvv user@localhost -p 2222
```

### Backup Restore Fails

```bash
# Check SSH access to production server (replace 'user' and 'production-server' with your values)
ssh user@production-server "ls -la ~user/ztpbootstrap-backup-*.tar.gz"

# Check if backup file exists
ssh user@production-server "ls -t ~user/ztpbootstrap-backup-*.tar.gz | head -1"

# Manually copy backup (replace 'user' with your username)
scp user@production-server:~user/ztpbootstrap-backup-*.tar.gz /tmp/
scp -P 2222 /tmp/ztpbootstrap-backup-*.tar.gz user@localhost:~/
```

### Interactive Setup Fails

```bash
# Check for syntax errors
bash -n setup-interactive.sh

# Run with debug output
bash -x setup-interactive.sh

# Check for missing dependencies
which yq
yq --version

# Check file permissions
ls -la setup-interactive.sh
chmod +x setup-interactive.sh
```

### Services Won't Start

```bash
# Check service status
sudo systemctl status ztpbootstrap
sudo systemctl status ztpbootstrap-nginx
sudo systemctl status ztpbootstrap-webui

# Check service logs
sudo journalctl -u ztpbootstrap -n 50
sudo journalctl -u ztpbootstrap-nginx -n 50
sudo journalctl -u ztpbootstrap-webui -n 50

# Check container logs
sudo podman logs ztpbootstrap-nginx
sudo podman logs ztpbootstrap-webui

# Check systemd quadlet files
ls -la /etc/containers/systemd/ztpbootstrap/
cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod

# Reload systemd and restart
sudo systemctl daemon-reload
sudo systemctl restart ztpbootstrap
```

---

## Development Tools

### Scripts in `.gitignore`

The following scripts are development tools and are not part of the standard deployment:

- `test-interactive-setup.sh` - Automated VM creation and backup restore
- `restore-backup-from-fedora1.sh` - Backup restore utility
- `vm-create-native.sh` - VM creation script
- `wait-for-ssh.sh` - SSH readiness checker
- `run-full-e2e-test.sh` - End-to-end test runner

These scripts are available locally but not tracked in git, allowing each developer to customize them for their environment.

### Makefile

The `Makefile` provides convenience commands for development tasks:

```bash
# Show available commands
make help

# Install development dependencies
make install-deps

# Run linting checks
make lint

# Run tests
make test

# Run linting and tests
make check

# Format code
make format

# Validate config.yaml
make validate-config

# Clean test artifacts
make clean
```

**Note:** The Makefile is optional. All commands can be run directly without it. The CI pipeline runs commands directly without using the Makefile.

---

## Best Practices

1. **Always test with a production backup** - This ensures your changes work with real-world configurations
2. **Test both interactive and non-interactive modes** - Both workflows should work correctly
3. **Verify services start correctly** - After running interactive setup, always verify services are running
4. **Test upgrade scenarios** - The primary use case is upgrading existing installations
5. **Clean up VMs when done** - Stop VMs when not in use to free resources
6. **Commit and push frequently** - Keep your changes in version control
7. **Test on fresh VMs** - Periodically test on completely fresh VMs to catch issues

---

## Next Steps

After completing development and testing:

1. **Run full test suite** - Use `ci-test.sh` and `integration-test.sh`
2. **Update documentation** - Update README.md if user-facing behavior changed
3. **Create pull request** - Submit changes for review
4. **Test in CI** - Verify CI pipeline passes with your changes

---

## Additional Resources

- [Testing Guide](TESTING.md) - General testing documentation
- [Known Issues](KNOWN_ISSUES.md) - Known issues and workarounds
- [Troubleshooting](TROUBLESHOOTING.md) - Common troubleshooting steps
- [README](../README.md) - Main project documentation
