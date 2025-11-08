# Arista ZTP Bootstrap Service

A containerized service that provides a secure HTTPS endpoint for serving Arista Zero Touch Provisioning (ZTP) bootstrap scripts to network devices. The service runs an nginx container that serves the bootstrap script over HTTPS with proper security headers, enabling automated device provisioning and enrollment with Arista CloudVision (CVaaS).

---

## Tested Platforms

**Architecture:** ARM64 (aarch64) - ✅ Fully tested  
**OS:** Fedora 43 Cloud - ✅ Fully tested  
**Podman:** 5.6.2 - ✅ Fully tested  
**Systemd:** Full quadlet support - ✅ Fully tested

**Note:** x86_64 not tested on ARM64 macOS (would require emulation). See [ARCHITECTURE_COMPARISON.md](ARCHITECTURE_COMPARISON.md) for details.

---

## 🚀 START HERE - Choose Your Setup Method

**New to this project?** Follow this decision tree:

```
Do you want guided prompts for all configuration?
├─ YES → Use Interactive Setup (Recommended for first-time users)
│   └─ Run: ./setup-interactive.sh
│   └─ See: [Interactive Setup](#interactive-setup)
│
└─ NO → Use Automated Setup
    └─ Run: sudo ./setup.sh
    └─ See: [Automated Setup](#automated-setup)
```

### Quick Decision Guide

**Use Interactive Setup (`setup-interactive.sh`) if:**
- ✅ First time setting up this service
- ✅ Want to customize paths, IPs, or other settings
- ✅ Prefer guided prompts over manual file editing
- ✅ Want centralized YAML configuration

**Use Automated Setup (`setup.sh`) if:**
- ✅ You've already configured `ztpbootstrap.env`
- ✅ Using default paths and settings
- ✅ Want quick setup without prompts
- ✅ Already familiar with the service

### Setup Prerequisites Checklist

Before starting, ensure you have:
- [ ] **Podman** installed (`podman --version`)
- [ ] **Macvlan network** created (run `./check-macvlan.sh` to verify)
- [ ] **Enrollment token** from CVaaS Device Registration page
- [ ] **SSL certificates** ready (or plan to use HTTP-only mode for testing)
- [ ] **Root/sudo access** for setup

**For Interactive Setup, also need:**
- [ ] **yq** installed (`yq --version`) - See [Interactive Setup](#interactive-setup) for installation

---

## What This Does

When an Arista switch boots for the first time, it requests network configuration from a DHCP server. The DHCP server responds with network settings and a URL to a bootstrap script (via DHCP Option 67). This service provides that bootstrap script endpoint, allowing switches to:

1. Download the bootstrap script (`bootstrap.py`) over HTTPS
2. Execute the script automatically
3. Enroll with Arista CloudVision (CVaaS) using an enrollment token
4. Receive their configuration from CVaaS

**Key Features:**
- ✅ Secure HTTPS serving with TLS 1.2/1.3
- ✅ Security headers (HSTS, CSP, X-Frame-Options, etc.)
- ✅ Containerized with Podman for easy deployment
- ✅ Systemd integration for automatic startup
- ✅ Health check endpoint for monitoring
- ✅ Support for HTTP-only mode (lab/testing only)

## Architecture

The service runs as a **Podman pod** with multiple containers sharing a macvlan network:

```
┌─────────────────┐
│  Arista Switch  │
│   (DHCP Client) │
└────────┬────────┘
         │
         │ 1. DHCP Request
         ▼
┌─────────────────┐
│  DHCP Server    │
│  (Provides URL) │
└────────┬────────┘
         │
         │ 2. DHCP Response
         │    DHCP Option 67: https://ztpboot.example.com/bootstrap.py
         ▼
┌─────────────────┐
│  Arista Switch  │
│   (DHCP Client) │
└────────┬────────┘
         │
         │ 3. HTTPS GET /bootstrap.py
         │    HTTP GET /ui/ (Web UI)
         ▼
┌─────────────────────────────────────────────────────────┐
│  ztpbootstrap-pod (Podman Pod)                         │
│  Network: ztpbootstrap-net (macvlan)                   │
│  IP: 10.0.0.10/24                                      │
│                                                        │
│  ┌──────────────────────────┐  ┌───────────────────┐  │
│  │  Nginx Container         │  │  Web UI Container │  │
│  │  (Port 80, 443)          │  │  (Port 5000)      │  │
│  │                          │  │                   │  │
│  │  - Serves bootstrap.py   │  │  - Flask app      │  │
│  │  - HTTPS on port 443     │  │  - Status/config  │  │
│  │  - Security headers      │  │  - Runtime mgmt   │  │
│  │  - Proxies /ui/ → Web UI │  │                   │  │
│  └──────────────────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │
         │ 4. Executes bootstrap.py
         ▼
┌─────────────────┐
│  CVaaS          │
│  (CloudVision)  │
└─────────────────┘
```

**Key Components:**
- **Pod**: `ztpbootstrap-pod` - Groups containers, provides shared network
- **Nginx Container**: Serves bootstrap script, handles HTTPS, proxies Web UI
- **Web UI Container**: Flask-based management interface (optional)
- **Macvlan Network**: `ztpbootstrap-net` - Direct network access with dedicated IP
- **Systemd Integration**: Quadlet files for automatic service management

## Quick Start

**Recommended:** Start with [Interactive Setup](#interactive-setup) for first-time users, or [Automated Setup](#automated-setup) if you've used this before.

### Prerequisites

Before starting, verify prerequisites:

```bash
# 1. Check Podman is installed
podman --version

# 2. Check macvlan network exists (required for pod-based deployment)
./check-macvlan.sh

# 3. Have your CVaaS enrollment token ready
#    Get it from: CVaaS Device Registration page
```

### Option 1: Interactive Setup (Recommended for First-Time Users)

Guided setup with prompts for all configuration:

```bash
# 1. Install yq if needed (required for interactive setup)
# macOS: brew install yq
# Linux: sudo apt-get install yq  # or dnf/yum

# 2. Run interactive setup
./setup-interactive.sh

# 3. Follow prompts to configure everything
# 4. Script will generate config.yaml and optionally apply it
# 5. Run setup.sh to start the service
sudo ./setup.sh
```

**Why use interactive?** No manual file editing, guided configuration, centralized YAML config.

### Option 2: Automated Setup (Quick Setup)

For users who want to use default settings or have already configured files:

```bash
# 1. Create environment file
cp ztpbootstrap.env.template ztpbootstrap.env
# Edit ztpbootstrap.env and set ENROLLMENT_TOKEN

# 2. Ensure macvlan network exists
./check-macvlan.sh

# 3. Run automated setup
sudo ./setup.sh

# For HTTP-only mode (testing only):
sudo ./setup.sh --http-only
```

**Why use automated?** Faster, no prompts, good for repeat deployments.

### What Happens During Setup

Both methods will:
1. ✅ Check prerequisites (macvlan network, files)
2. ✅ Configure bootstrap script with your settings
3. ✅ Set up Podman pod with nginx and Web UI containers
4. ✅ Start the service
5. ✅ Verify it's running

### Verify Installation

```bash
# Check pod status
sudo systemctl status ztpbootstrap-pod

# Check individual container status
sudo podman ps --filter pod=ztpbootstrap-pod

# Test health endpoint
curl -k https://ztpboot.example.com/health

# Access Web UI (if enabled)
# Navigate to: https://ztpboot.example.com/ui/
# Features:
#   - Service status and health
#   - Current configuration view
#   - Bootstrap script management
#   - Service logs
```

**Need more details?** See:
- [Interactive Setup](#interactive-setup) - Complete interactive setup guide
- [Automated Setup](#automated-setup) - Automated setup details
- [Detailed Setup Guide](#detailed-setup) - Step-by-step manual instructions
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
- [Quick Start Guide](QUICK_START.md) - Common deployment scenarios

---

## Setup Scripts Overview

Understanding the relationship between setup scripts:

```
setup-interactive.sh
    │
    ├─→ Generates config.yaml
    │
    └─→ update-config.sh (optional)
            │
            └─→ Updates all files from config.yaml
                    │
                    ├─→ bootstrap.py
                    ├─→ nginx.conf
                    ├─→ ztpbootstrap.env
                    └─→ systemd/*.container files

setup.sh
    │
    ├─→ Checks prerequisites (Podman, macvlan network)
    ├─→ Reads ztpbootstrap.env
    ├─→ Generates configured bootstrap.py
    ├─→ Sets up Podman pod
    └─→ Starts systemd service
```

**Script Purposes:**
- **`setup-interactive.sh`**: Interactive configuration wizard → generates `config.yaml`
- **`update-config.sh`**: Applies `config.yaml` to all service files
- **`setup.sh`**: Automated setup and service deployment
- **`check-macvlan.sh`**: Verifies macvlan network exists (called by `setup.sh`)

---

## Interactive Setup

The interactive setup mode provides a guided configuration experience that prompts you for all paths and variables, then stores them in a YAML configuration file. This makes it easy to customize the deployment for your environment.

### Prerequisites

- **yq** installed (for YAML parsing):
  ```bash
  # macOS
  brew install yq
  
  # Debian/Ubuntu
  sudo apt-get install yq
  
  # Or download from: https://github.com/mikefarah/yq
  ```

### Quick Start with Interactive Setup

```bash
# 1. Run the interactive setup
./setup-interactive.sh

# 2. Answer the prompts to configure:
#    - Directory paths
#    - Network settings (domain, IPs, ports)
#    - CVaaS configuration (address, enrollment token, etc.)
#    - SSL certificate settings
#    - Container and service configuration

# 3. The script will:
#    - Generate config.yaml with your settings
#    - Optionally apply the configuration to all files
#    - Update bootstrap.py, nginx.conf, systemd quadlet, etc.
```

### What Gets Configured

The interactive setup configures:

- **Directory Paths**: All file locations (script directory, cert directory, etc.)
- **Network Settings**: Domain name, IPv4/IPv6 addresses, ports
- **CVaaS Configuration**: Address, enrollment token, proxy, EOS URL, NTP server
- **SSL Certificates**: Certificate paths, Let's Encrypt settings
- **Container Settings**: Image, timezone, network mode, DNS
- **Service Settings**: Health checks, restart policies

### Manual Configuration Update

If you've already created `config.yaml`, you can update all files manually:

```bash
# Update all files from config.yaml
./update-config.sh config.yaml
```

This will update:
- `bootstrap.py` - CVaaS configuration
- `nginx.conf` - Network and domain settings
- `ztpbootstrap.env` - Environment variables
- `systemd/ztpbootstrap.pod` - Pod definition
- `systemd/ztpbootstrap-nginx.container` - Nginx container configuration
- `systemd/ztpbootstrap-webui.container` - Web UI container configuration (optional)
- `setup.sh` - Path variables

### Configuration File Format

The configuration is stored in YAML format (`config.yaml`):

```yaml
paths:
  script_dir: "/opt/containerdata/ztpbootstrap"
  cert_dir: "/opt/containerdata/certs/wild"
  # ... more paths

network:
  domain: "ztpboot.example.com"
  ipv4: "10.0.0.10"
  # ... more network settings

cvaas:
  address: "www.arista.io"
  enrollment_token: "your_token_here"
  # ... more CVaaS settings
```

See `config.yaml.template` for the complete structure and all available options.

### Benefits of Interactive Setup

- ✅ **No manual file editing** - All configuration through prompts
- ✅ **Centralized configuration** - Single YAML file for all settings
- ✅ **Easy updates** - Change config.yaml and re-run update script
- ✅ **Validation** - Prompts guide you through valid options
- ✅ **Documentation** - Config file serves as documentation

---

## Detailed Setup

### Prerequisites

- **Podman** installed ([installation instructions](#installing-podman))
- **SSL certificates** for HTTPS (or use [HTTP-only mode](#http-only-setup) for testing)
- **Network access** to CVaaS (or your CVaaS instance)
- **Enrollment token** from CVaaS Device Registration page

### Step 1: Install Podman

<details>
<summary><b>Fedora / RHEL / Rocky Linux / AlmaLinux / CentOS Stream</b></summary>

```bash
sudo dnf install podman
podman --version
```
</details>

<details>
<summary><b>Ubuntu / Debian</b></summary>

```bash
sudo apt update
sudo apt install podman
podman --version
```
</details>

<details>
<summary><b>openSUSE</b></summary>

```bash
sudo zypper install podman
podman --version
```
</details>

**Recommended Distributions:**
- **Best:** Fedora 37+, RHEL 9+, Rocky Linux 9+, AlmaLinux 9+, CentOS Stream 9+
- **Good:** Ubuntu 22.04+, Debian 12+, openSUSE Tumbleweed/Leap 15.4+
- **Not Recommended:** Older distributions (RHEL 8, Ubuntu 20.04) - may lack full systemd quadlet support

### Step 2: Prepare Directories

```bash
# Create service directory
sudo mkdir -p /opt/containerdata/ztpbootstrap

# Create certificate directory
sudo mkdir -p /opt/containerdata/certs/wild

# Set permissions
sudo chown -R $USER:$USER /opt/containerdata/ztpbootstrap
```

### Step 3: Copy Service Files

Copy all service files to `/opt/containerdata/ztpbootstrap/`:
- `bootstrap.py` - Arista bootstrap script
- `nginx.conf` - Nginx configuration
- `ztpbootstrap.env` - Environment configuration (optional)
- `setup.sh` - Automated setup script (optional)
- `systemd/ztpbootstrap.pod` - Pod definition
- `systemd/ztpbootstrap-nginx.container` - Nginx container definition
- `systemd/ztpbootstrap-webui.container` - Web UI container definition (optional)
- `webui/` - Web UI application files (optional)

### Step 4: Configure Bootstrap Script

Edit `bootstrap.py` and update the `USER INPUT` section (around lines 34-57):

```python
# CVaaS address
cvAddr = "www.arista.io"  # or your specific regional URL

# Enrollment token from CVaaS Device Registration page
enrollmentToken = "your_enrollment_token_here"

# Optional: Proxy URL if behind a proxy
cvproxy = ""

# Optional: EOS image URL for upgrades
eosUrl = ""

# Optional: NTP server for time synchronization
ntpServer = "10.0.0.11"  # or "ntp1.aristanetworks.com"
```

**Regional CVaaS URLs:**
- United States 1a: `www.arista.io` (recommended, redirects automatically)
- United States 1b: `www.cv-prod-us-central1-b.arista.io`
- United States 1c: `www.cv-prod-us-central1-c.arista.io`
- Canada: `www.cv-prod-na-northeast1-b.arista.io`
- Europe West 2: `www.cv-prod-euwest-2.arista.io`
- Japan: `www.cv-prod-apnortheast-1.arista.io`
- Australia: `www.cv-prod-ausoutheast-1.arista.io`
- United Kingdom: `www.cv-prod-uk-1.arista.io`

See [Configuration](#configuration) for detailed options.

### Step 5: Set Up Macvlan Network

The service requires a macvlan network for direct network access. Check if it exists:

```bash
./check-macvlan.sh
```

If the network doesn't exist, the script will provide instructions for manual creation. The network must be created before running `setup.sh`.

### Step 6: Set Up SSL Certificates

You need SSL certificates for HTTPS. Place them in `/opt/containerdata/certs/wild/`:

```bash
# Required files:
# - /opt/containerdata/certs/wild/fullchain.pem
# - /opt/containerdata/certs/wild/privkey.pem

# Verify they exist
ls -la /opt/containerdata/certs/wild/
```

**Certificate Options:**
- **Let's Encrypt with certbot** (recommended - can be automated) - See [SSL Certificates](#ssl-certificates)
- **Organization's certificate authority** - Use your existing CA
- **Self-signed certificate** (testing only) - See [SSL Certificates](#ssl-certificates)
- **HTTP-only mode** (lab/testing only) - See [HTTP-Only Setup](#http-only-setup)

### Step 7: Start the Service

**Recommended: Use the automated setup script**

```bash
# For HTTPS (production)
sudo ./setup.sh

# For HTTP-only (testing only)
sudo ./setup.sh --http-only
```

The setup script will:
1. Check prerequisites (Podman, macvlan network)
2. Configure the bootstrap script with your settings
3. Set up the Podman pod with nginx and Web UI containers
4. Install systemd quadlet files
5. Start the service
6. Verify it's running

**Manual setup (advanced users)**

If you prefer manual setup, see [Systemd Integration](#systemd-integration) section for quadlet file configuration.

### Step 8: Verify Service

```bash
# Check container is running
podman ps | grep ztpbootstrap

# Test health endpoint
curl -k https://ztpboot.example.com/health
# Should return: healthy

# Test bootstrap script endpoint
curl -k https://ztpboot.example.com/bootstrap.py | head -20

# View logs
sudo podman logs ztpbootstrap-nginx
sudo podman logs ztpbootstrap-webui
```

### Step 9: Configure DHCP Server

Configure your DHCP server to point devices to the bootstrap script using DHCP Option 67 (bootfile-name):

**ISC DHCP Server:**
```dhcp
subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.100 10.0.0.200;
    option routers 10.0.0.1;
    option domain-name-servers 8.8.8.8;
    option bootfile-name "https://ztpboot.example.com/bootstrap.py";
}
```

**Kea DHCP Server:**
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

See [DHCP Configuration](#dhcp-configuration) for more examples.

---

## Configuration

### Bootstrap Script Configuration

The bootstrap script (`bootstrap.py`) contains hardcoded configuration values that must be edited directly:

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `cvAddr` | CVaaS address | Yes | `www.arista.io` |
| `enrollmentToken` | Token from CVaaS Device Registration | Yes | JWT token string |
| `cvproxy` | Proxy URL (if behind proxy) | No | `http://proxy.example.com:8080` |
| `eosUrl` | EOS image URL for upgrades | No | `http://server/eos.swi` |
| `ntpServer` | NTP server for time sync | No | `10.0.0.11` |

### Network Configuration

Default network configuration:
- **IPv4**: `10.0.0.10`
- **IPv6**: `2001:db8::10`
- **Hostname**: `ztpboot.example.com`
- **Port**: `443` (HTTPS) or `80` (HTTP-only mode)

Update these in `nginx.conf` and your network configuration as needed.

### SSL Certificates

The service uses wildcard certificates from `/opt/containerdata/certs/wild/`:
- Certificate: `fullchain.pem`
- Private Key: `privkey.pem`
- Domain: `*.example.com` (covers `ztpboot.example.com`)

**Certificate Setup Options:**

1. **Let's Encrypt with certbot** (Recommended)
   ```bash
   sudo certbot certonly --standalone -d ztpboot.example.com
   # Copy certificates to /opt/containerdata/certs/wild/
   ```

2. **Organization CA** - Use your existing certificate authority

3. **Self-signed (Testing Only)**
   ```bash
   sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout /opt/containerdata/certs/wild/privkey.pem \
     -out /opt/containerdata/certs/wild/fullchain.pem \
     -subj "/CN=ztpboot.example.com"
   ```

4. **HTTP-Only Mode** - See [HTTP-Only Setup](#http-only-setup) below

### Nginx Configuration

The nginx configuration (`nginx.conf`) provides:
- HTTPS on port 443 with TLS 1.2/1.3
- Security headers (HSTS, CSP, X-Frame-Options, etc.)
- No-cache headers for bootstrap script
- Health check endpoint at `/health`
- HTTP to HTTPS redirect

See `nginx.conf` for the complete configuration.

### HTTP-Only Setup {#http-only-setup}

**⚠️ Warning: HTTP-only setup is strongly discouraged for production use.** All traffic will be unencrypted, making it vulnerable to interception and tampering. This should only be used for testing in isolated lab environments. **Let's Encrypt certificates can be fully automated** with certbot and systemd timers, making HTTPS setup nearly as simple as HTTP while providing proper security.

If you absolutely must use HTTP-only (e.g., for a completely isolated lab network with no internet access):

1. **Use the setup script with --http-only flag:**
   ```bash
   sudo /opt/containerdata/ztpbootstrap/setup.sh --http-only
   ```

2. **Or manually modify nginx.conf** to serve HTTP on port 80 (see [HTTP-Only Setup Details](#http-only-setup-details) for full instructions)

3. **Update DHCP configuration** to use HTTP:
   ```dhcp
   option bootfile-name "http://ztpboot.example.com/bootstrap.py";
   ```

4. **Test the service:**
   ```bash
   curl http://ztpboot.example.com/health
   curl http://ztpboot.example.com/bootstrap.py
   ```

**Remember:** This configuration is insecure and should never be used in production or on networks with internet access. Consider using Let's Encrypt with automated renewal instead.

<details>
<summary><b>HTTP-Only Setup Details</b></summary>

To manually configure HTTP-only mode:

1. **Modify nginx.conf** - Replace the HTTPS server block with an HTTP-only configuration (see README for full nginx config)

2. **Update container command** - Remove certificate volume mounts and change port:
   ```bash
   # Note: For pod-based setup, use setup.sh instead
   # Manual pod creation is not recommended - use systemd quadlet files
   ```

3. **The setup script handles this automatically** - When using `--http-only`, the script configures nginx and updates quadlet files accordingly

</details>

---

## Service Management

### Start/Stop/Restart

**Using Podman directly (for pod):**
```bash
# Start pod
sudo podman pod start ztpbootstrap-pod

# Stop pod
sudo podman pod stop ztpbootstrap-pod

# Restart pod
sudo podman pod restart ztpbootstrap-pod

# Check pod status
sudo podman pod ps
```

**Using systemd (if using quadlet):**
```bash
# Start
sudo systemctl start ztpbootstrap-pod

# Stop
sudo systemctl stop ztpbootstrap-pod

# Restart
sudo systemctl restart ztpbootstrap-pod

# Enable on boot
sudo systemctl enable ztpbootstrap-pod
```

### View Logs

**Podman logs:**
```bash
# Follow logs for nginx container
sudo podman logs -f ztpbootstrap-nginx

# Follow logs for Web UI container
sudo podman logs -f ztpbootstrap-webui

# View recent logs
sudo podman logs --tail 100 ztpbootstrap-nginx
```

**Systemd logs (if using quadlet):**
```bash
# Follow logs in real-time
sudo journalctl -u ztpbootstrap-pod -f

# View recent logs
sudo journalctl -u ztpbootstrap-pod --since "1 hour ago"
```

### Check Status

```bash
# Pod and container status
sudo podman pod ps
sudo podman ps --filter pod=ztpbootstrap-pod

# Systemd service status
sudo systemctl status ztpbootstrap-pod
```

### Systemd Integration {#systemd-integration}

The service uses systemd quadlets for automatic startup and service management. The setup script automatically installs the quadlet files, but you can also install them manually:

**Quadlet files are automatically installed by `setup.sh`:**

The setup script copies these files to `/etc/containers/systemd/ztpbootstrap/`:
- `ztpbootstrap.pod` - Pod definition with macvlan network
- `ztpbootstrap-nginx.container` - Nginx container configuration
- `ztpbootstrap-webui.container` - Web UI container configuration (optional)

**Manual installation (if needed):**

```bash
# 1. Create quadlet directory
sudo mkdir -p /etc/containers/systemd/ztpbootstrap

# 2. Copy pod and container files
sudo cp systemd/ztpbootstrap.pod /etc/containers/systemd/ztpbootstrap/
sudo cp systemd/ztpbootstrap-nginx.container /etc/containers/systemd/ztpbootstrap/
sudo cp systemd/ztpbootstrap-webui.container /etc/containers/systemd/ztpbootstrap/

# 3. Reload systemd and start
sudo systemctl daemon-reload
sudo systemctl start ztpbootstrap-pod
sudo systemctl enable ztpbootstrap-pod
```

**Note:** The pod-based setup requires a macvlan network (`ztpbootstrap-net`). Run `./check-macvlan.sh` to verify it exists before starting the service.

---

## Endpoints

- **Bootstrap Script**: `https://ztpboot.example.com/bootstrap.py`
- **Health Check**: `https://ztpboot.example.com/health` (returns "healthy")

---

## DHCP Configuration

Configure your DHCP server to provide the bootstrap script URL via DHCP Option 67 (bootfile-name).

### ISC DHCP Server Example

```dhcp
subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.100 10.0.0.200;
    option routers 10.0.0.1;
    option domain-name-servers 8.8.8.8;
    option bootfile-name "https://ztpboot.example.com/bootstrap.py";
}
```

### Kea DHCP Server Example

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

**For HTTP-only mode:**
```dhcp
option bootfile-name "http://ztpboot.example.com/bootstrap.py";
```

---

## Security Features

- **HTTPS Only** (default): All traffic encrypted with TLS 1.2/1.3
- **Security Headers**: 
  - Strict-Transport-Security (HSTS)
  - Content-Security-Policy
  - X-Frame-Options: DENY
  - X-Content-Type-Options: nosniff
  - X-XSS-Protection
- **No Cache**: Bootstrap script served with no-cache headers
- **Access Control**: Hidden files and backup files blocked
- **Resource Limits**: Memory and CPU limits configured in container

---

## Testing

The repository includes comprehensive test scripts to validate the service setup and functionality.

### Quick Validation

```bash
sudo /opt/containerdata/ztpbootstrap/test-service.sh
```

### Integration Testing

For end-to-end testing that creates a test container and validates it works:

```bash
# Test HTTPS mode (requires SSL certificates)
sudo /opt/containerdata/ztpbootstrap/integration-test.sh

# Test HTTP-only mode
sudo /opt/containerdata/ztpbootstrap/integration-test.sh --http-only
```

The integration test validates:
- ✅ Container starts successfully
- ✅ Health endpoint responds correctly
- ✅ Bootstrap.py endpoint returns 200 OK
- ✅ Response headers are correct
- ✅ Bootstrap.py content is valid Python
- ✅ Downloaded file matches original
- ✅ EOS device simulation works

### CI/CD Testing

For automated testing in CI/CD pipelines:

```bash
/opt/containerdata/ztpbootstrap/ci-test.sh
```

See [Testing Guide](TESTING.md) for complete testing documentation.

---

## Troubleshooting

### Service Won't Start

1. **Check logs:**
   ```bash
   sudo podman logs ztpbootstrap
   # or
   sudo journalctl -u ztpbootstrap-pod
   ```

2. **Verify certificates:**
   ```bash
   ls -la /opt/containerdata/certs/wild/
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout
   ```

3. **Check network:**
   ```bash
   ip addr show  # Ensure IPs are assigned
   ```

4. **Verify nginx configuration:**
   ```bash
   sudo podman run --rm -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t
   ```

### Bootstrap Script Issues

1. **Verify script is accessible:**
   ```bash
   curl -k https://ztpboot.example.com/bootstrap.py
   ```

2. **Check script configuration:**
   ```bash
   grep -A 5 "cvAddr\|enrollmentToken" /opt/containerdata/ztpbootstrap/bootstrap.py
   ```

3. **Test script manually** (on an Arista switch):
   ```bash
   python3 /tmp/bootstrap.py
   ```

### SSL Certificate Issues

1. **Check certificate validity:**
   ```bash
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout
   ```

2. **Verify domain coverage:**
   ```bash
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout | grep -A 1 "Subject Alternative Name"
   ```

3. **Check certificate expiration:**
   ```bash
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -noout -dates
   ```

### Device Cannot Download Script

1. **Verify DNS resolution:**
   ```bash
   nslookup ztpboot.example.com
   ```

2. **Test HTTPS connectivity:**
   ```bash
   curl -v https://ztpboot.example.com/health
   ```

3. **Check firewall rules:**
   ```bash
   sudo firewall-cmd --list-all  # or iptables -L
   ```

4. **Verify DHCP configuration:**
   - Ensure Option 67 (bootfile-name) is set correctly
   - Verify the URL matches exactly: `https://ztpboot.example.com/bootstrap.py`

---

## How It Works

1. **Device Boot**: Arista switch boots and requests DHCP configuration
2. **DHCP Response**: DHCP server provides network config and bootstrap script URL
3. **Script Download**: Switch downloads `bootstrap.py` from the HTTPS endpoint
4. **Script Execution**: Switch executes the bootstrap script
5. **CVaaS Enrollment**: Script enrolls device with CVaaS using the enrollment token
6. **Configuration**: CVaaS pushes device configuration

---

## Files Structure

```
/opt/containerdata/ztpbootstrap/
├── bootstrap.py              # Arista ZTP bootstrap script (edit this)
├── bootstrap_configured.py   # Generated script (if using setup.sh)
├── bootstrap.py.backup       # Backup of original script
├── nginx.conf               # Nginx configuration
├── ztpbootstrap.env         # Environment variables (for reference)
├── ztpbootstrap.env.template # Environment template
├── setup.sh                 # Setup script
├── test-service.sh          # Basic service validation script
├── integration-test.sh      # Comprehensive end-to-end integration test
├── ci-test.sh               # CI/CD validation test script
└── README.md               # This file

/etc/containers/systemd/ztpbootstrap/
├── ztpbootstrap.pod              # Pod definition
├── ztpbootstrap-nginx.container  # Nginx container configuration
└── ztpbootstrap-webui.container  # Web UI container configuration (optional)

/opt/containerdata/certs/wild/
├── fullchain.pem           # SSL certificate
└── privkey.pem             # SSL private key
```

---

## Support

For issues related to:

- **Arista ZTP**: Check [Arista Documentation](https://www.arista.com/en/support/documentation)
- **CVaaS**: Contact Arista Support or check [CVaaS Documentation](https://www.arista.com/en/products/eos/eos-cloudvision)
- **This Service**: Check logs and configuration files, see [Troubleshooting](#troubleshooting)

---

## License

This service uses the Arista bootstrap script which is governed by the Apache License 2.0.

---

## Notes

- The bootstrap script contains hardcoded configuration values that must be edited directly
- The `setup.sh` script can automate some configuration using environment variables
- Ensure the enrollment token is valid and not expired
- The service requires valid SSL certificates to function properly (or use HTTP-only mode for testing)
- Devices must be able to reach the service over HTTPS on port 443 (or HTTP on port 80 for HTTP-only mode)
