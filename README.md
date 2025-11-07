# Arista ZTP Bootstrap Service

This service provides a secure HTTPS endpoint for serving Arista Zero Touch Provisioning (ZTP) bootstrap scripts to network devices. The service runs an nginx container that serves the bootstrap script over HTTPS with proper security headers.

## Overview

The ztpbootstrap service consists of:

- **Bootstrap Script**: Arista's ZTP bootstrap script (`bootstrap.py`) that devices download during initial boot
- **Nginx Container**: Serves the bootstrap script over HTTPS with security headers
- **Systemd Quadlet**: Manages the container lifecycle using Podman
- **Configuration Files**: Environment and nginx configuration files

## Architecture

```
┌─────────────────┐
│  Arista Switch  │
│   (DHCP Client) │
└────────┬────────┘
         │
         │ DHCP Option 67: https://ztpboot.example.com/bootstrap.py
         ▼
┌─────────────────┐
│  DHCP Server    │
└─────────────────┘
         │
         │ HTTPS GET /bootstrap.py
         ▼
┌─────────────────────────────────┐
│  ztpbootstrap Service           │
│  (Podman Container)             │
│  ┌───────────────────────────┐  │
│  │  Nginx                    │  │
│  │  - Serves bootstrap.py    │  │
│  │  - HTTPS on port 443      │  │
│  │  - Security headers       │  │
│  └───────────────────────────┘  │
└─────────────────────────────────┘
         │
         │ Executes bootstrap.py
         ▼
┌─────────────────┐
│  CVaaS          │
│  (CloudVision)  │
└─────────────────┘
```

## First Time Setup

If you're new to containers and Podman, this section will guide you through setting up the ztpbootstrap service from scratch.

### What is Podman?

Podman is a container engine that runs containers without requiring a daemon (unlike Docker). It's designed to be a drop-in replacement for Docker and is the recommended container tool for modern Linux distributions. Containers are lightweight, isolated environments that package applications with all their dependencies.

### Recommended Linux Distributions

For best results with Podman and systemd quadlets, we recommend:

**Best Supported:**
- **Fedora** (37+) - Excellent Podman support, systemd quadlets included by default
- **RHEL 9+ / Rocky Linux 9+ / AlmaLinux 9+** - Enterprise-grade, full Podman support
- **CentOS Stream 9+** - Good Podman integration

**Also Supported:**
- **Ubuntu 22.04+** - Requires additional setup for systemd quadlets
- **Debian 12+** - Podman available, may need manual quadlet configuration
- **openSUSE Tumbleweed / Leap 15.4+** - Good Podman support

**Not Recommended:**
- Older distributions (RHEL 8, Ubuntu 20.04, Debian 11) - May work but lack full quadlet support
- Non-systemd distributions (Gentoo, Alpine with OpenRC) - Require manual container management

### Installing Podman

#### Fedora / RHEL / Rocky Linux / AlmaLinux / CentOS Stream

```bash
# Install Podman (usually pre-installed on newer versions)
sudo dnf install podman

# Verify installation
podman --version
```

#### Ubuntu / Debian

```bash
# Update package list
sudo apt update

# Install Podman
sudo apt install podman

# Verify installation
podman --version
```

#### openSUSE

```bash
# Install Podman
sudo zypper install podman

# Verify installation
podman --version
```

### Basic Podman Concepts

Before proceeding, here are a few key concepts:

- **Container**: A running instance of an application (in this case, nginx serving files)
- **Image**: The template used to create containers (we'll use `nginx:alpine`)
- **Volume**: A way to share files/directories between your host system and the container
- **Port**: How network traffic reaches the container (we use port 443 for HTTPS)
- **Systemd Quadlet**: A systemd unit file that manages containers automatically

### Complete First-Time Setup Guide

Follow these steps in order:

#### Step 1: Install Podman

Install Podman using the commands above for your distribution.

#### Step 2: Verify Podman Works

Test that Podman is working correctly:

```bash
# Pull a test image (this may take a minute)
podman pull alpine:latest

# Run a test container
podman run --rm alpine:latest echo "Podman is working!"

# Clean up
podman rmi alpine:latest
```

If you see "Podman is working!" without errors, you're ready to continue.

#### Step 3: Prepare Your System

Create the necessary directories:

```bash
# Create the service directory
sudo mkdir -p /opt/containerdata/ztpbootstrap

# Create certificate directory (if not already present)
sudo mkdir -p /opt/containerdata/certs/wild

# Set proper permissions
sudo chown -R $USER:$USER /opt/containerdata/ztpbootstrap
```

#### Step 4: Copy Service Files

Copy all the service files to `/opt/containerdata/ztpbootstrap/`. Ensure you have:
- `bootstrap.py` - The Arista bootstrap script
- `nginx.conf` - Nginx configuration
- `ztpbootstrap.env` - Environment configuration (optional)

#### Step 5: Configure the Bootstrap Script

Edit the bootstrap script with your CVaaS settings (see [Configuration](#configuration) section for details):

```bash
sudo vi /opt/containerdata/ztpbootstrap/bootstrap.py
```

Update the `cvAddr` and `enrollmentToken` variables in the `USER INPUT` section.

#### Step 6: Set Up SSL Certificates

You need SSL certificates for HTTPS. Place them in `/opt/containerdata/certs/wild/`:

```bash
# Your certificate files should be:
# - /opt/containerdata/certs/wild/fullchain.pem
# - /opt/containerdata/certs/wild/privkey.pem

# Verify they exist
ls -la /opt/containerdata/certs/wild/
```

**Note**: If you don't have certificates yet, you can:
- Use Let's Encrypt with certbot
- Use your organization's certificate authority
- Create a self-signed certificate for testing (not recommended for production)

#### Step 7: Configure Network

Assign the required IP addresses to your network interface. First, identify your interface:

```bash
# List network interfaces
ip addr show

# Find the interface you want to use (usually eth0, enp1s0, ens33, etc.)
```

Then assign the IPs:

```bash
# Replace <interface> with your actual interface name
INTERFACE="enp1s0"  # Change this!

# IPv4
sudo ip addr add 10.0.0.10/24 dev $INTERFACE

# IPv6 (if needed)
sudo ip -6 addr add 2001:db8::10/64 dev $INTERFACE

# Verify
ip addr show $INTERFACE
```

**Important**: To make these IP assignments persistent across reboots, configure them in your network manager (NetworkManager, netplan, etc.) or add them to `/etc/network/interfaces` (Debian/Ubuntu) or network-scripts (RHEL/CentOS).

#### Step 8: Test the Container Manually

Before setting up systemd, test that the container works:

```bash
# Stop any existing container
podman stop ztpbootstrap 2>/dev/null || true
podman rm ztpbootstrap 2>/dev/null || true

# Run the container manually
sudo podman run -d   --name ztpbootstrap   --network host   -v /opt/containerdata/ztpbootstrap:/usr/share/nginx/html:ro   -v /opt/containerdata/certs/wild:/etc/nginx/ssl:ro   -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro   nginx:alpine

# Check if it's running
podman ps

# Test the health endpoint
curl -k https://ztpboot.example.com/health

# View logs if there are issues
podman logs ztpbootstrap
```

If you see "healthy" from the curl command, the container is working!

#### Step 9: Set Up Systemd Quadlet (Optional but Recommended)

Systemd quadlets allow the container to start automatically on boot and be managed like a regular system service.

**For Fedora / RHEL 9+ / Rocky Linux 9+ / AlmaLinux 9+ / CentOS Stream 9+:**

```bash
# Create quadlet directory
sudo mkdir -p /etc/containers/systemd/ztpbootstrap

# Create the quadlet file
sudo tee /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container > /dev/null <<'EOF'
[Unit]
Description=ZTP Bootstrap Service
After=network-online.target
Wants=network-online.target

[Container]
Image=nginx:alpine
ContainerName=ztpbootstrap
Network=host
PublishPort=443:443
Volume=/opt/containerdata/ztpbootstrap:/usr/share/nginx/html:ro
Volume=/opt/containerdata/certs/wild:/etc/nginx/ssl:ro
Volume=/opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro
Restart=always
RestartSec=10

[Service]
Restart=always
RestartSec=10
EOF

# Reload systemd
sudo systemctl daemon-reload

# Start the service
sudo systemctl start ztpbootstrap.container

# Enable it to start on boot
sudo systemctl enable ztpbootstrap.container

# Check status
sudo systemctl status ztpbootstrap.container
```

**For Ubuntu / Debian:**

Quadlet support may require additional setup. You can either:
1. Use the manual Podman approach (Step 8) and create a systemd service file manually
2. Upgrade to a newer version with quadlet support
3. Use Podman's systemd integration with `podman generate systemd`

#### Step 10: Verify Everything Works

```bash
# Check service status
sudo systemctl status ztpbootstrap.container

# Test endpoints
curl -k https://ztpboot.example.com/health
curl -k https://ztpboot.example.com/bootstrap.py | head -20

# View logs
sudo journalctl -u ztpbootstrap.container -f
```

### Alternative: Using Docker Compose (Advanced)

If you're familiar with Docker Compose, you can convert the quadlet configuration to a `docker-compose.yml` file. However, we recommend using Podman with systemd quadlets for better integration with Linux system management. Podman also supports `podman-compose` which can read Docker Compose files directly.

### Troubleshooting for Beginners

**Container won't start:**
```bash
# Check what went wrong
podman logs ztpbootstrap

# Verify files exist
ls -la /opt/containerdata/ztpbootstrap/
ls -la /opt/containerdata/certs/wild/
```

**Can't access the service:**
```bash
# Check if container is running
podman ps

# Check if port 443 is in use
sudo ss -tlnp | grep 443

# Test locally
curl -k https://localhost/health
```

**Permission errors:**
```bash
# Ensure you're using sudo for system-level operations
# Check file permissions
ls -la /opt/containerdata/ztpbootstrap/
```

### Next Steps

Once your service is running, proceed to:
- [Configuration](#configuration) - Detailed configuration options
- [DHCP Configuration](#dhcp-configuration) - Set up your DHCP server
- [Troubleshooting](#troubleshooting) - Advanced troubleshooting

## Quick Start


### 1. Configure the Bootstrap Script

Edit the bootstrap script to set your CVaaS configuration:

```bash
sudo vi /opt/containerdata/ztpbootstrap/bootstrap.py
```

Update these variables in the `USER INPUT` section (around lines 34-57):

```python
# CVaaS address
cvAddr = "www.arista.io"  # or your specific regional URL

# Enrollment token from CVaaS Device Registration page
enrollmentToken = "your_enrollment_token_here"

# Optional: Proxy URL if behind a proxy
cvproxy = ""

# Optional: EOS image URL for upgrades (if needed)
eosUrl = ""

# Optional: NTP server for time synchronization
ntpServer = "10.0.0.11"  # or "ntp1.aristanetworks.com"
```

### 2. Verify SSL Certificates

Ensure SSL certificates are available:

```bash
ls -la /opt/containerdata/certs/wild/
# Should show: fullchain.pem and privkey.pem
```

### 3. Configure Network IPs

Assign the required IP addresses to your network interface:

```bash
# IPv4
sudo ip addr add 10.0.0.10/24 dev <interface>

# IPv6
sudo ip -6 addr add 2001:db8::10/64 dev <interface>
```

### 4. Start the Service

```bash
# If using systemd quadlet
sudo systemctl daemon-reload
sudo systemctl start ztpbootstrap.container

# Or if using Podman directly
sudo podman run -d \
  --name ztpbootstrap \
  --network host \
  -v /opt/containerdata/ztpbootstrap:/usr/share/nginx/html:ro \
  -v /opt/containerdata/certs/wild:/etc/nginx/ssl:ro \
  -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine
```

### 5. Verify the Service

```bash
# Check service status
sudo systemctl status ztpbootstrap.container

# Test health endpoint
curl -k https://ztpboot.example.com/health

# Test bootstrap script endpoint
curl -k https://ztpboot.example.com/bootstrap.py
```

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

**Regional CVaaS URLs:**
- United States 1a: `www.arista.io` (recommended, redirects automatically)
- United States 1b: `www.cv-prod-us-central1-b.arista.io`
- United States 1c: `www.cv-prod-us-central1-c.arista.io`
- Canada: `www.cv-prod-na-northeast1-b.arista.io`
- Europe West 2: `www.cv-prod-euwest-2.arista.io`
- Japan: `www.cv-prod-apnortheast-1.arista.io`
- Australia: `www.cv-prod-ausoutheast-1.arista.io`
- United Kingdom: `www.cv-prod-uk-1.arista.io`

### Network Configuration

The service is configured with:

- **IPv4**: `10.0.0.10`
- **IPv6**: `2001:db8::10`
- **Hostname**: `ztpboot.example.com`
- **Port**: `443` (HTTPS only)

### SSL Certificates

The service uses wildcard certificates from `/opt/containerdata/certs/wild/`:

- Certificate: `fullchain.pem`
- Private Key: `privkey.pem`
- Domain: `*.example.com` (covers `ztpboot.example.com`)

### Nginx Configuration

The nginx configuration (`nginx.conf`) provides:

- HTTPS on port 443 with TLS 1.2/1.3
- Security headers (HSTS, CSP, X-Frame-Options, etc.)
- No-cache headers for bootstrap script
- Health check endpoint at `/health`
- HTTP to HTTPS redirect

## Service Management

### Start/Stop/Restart

```bash
# Start service
sudo systemctl start ztpbootstrap.container

# Stop service
sudo systemctl stop ztpbootstrap.container

# Restart service
sudo systemctl restart ztpbootstrap.container

# Enable on boot (if using systemd)
sudo systemctl enable ztpbootstrap.container
```

### View Logs

```bash
# Follow logs in real-time
sudo journalctl -u ztpbootstrap.container -f

# View recent logs
sudo journalctl -u ztpbootstrap.container --since "1 hour ago"

# View container logs (if using Podman directly)
sudo podman logs -f ztpbootstrap
```

### Check Status

```bash
# Systemd service status
sudo systemctl status ztpbootstrap.container

# Container status (if using Podman directly)
sudo podman ps | grep ztpbootstrap
```

## Endpoints

- **Bootstrap Script**: `https://ztpboot.example.com/bootstrap.py`
- **Health Check**: `https://ztpboot.example.com/health`

## DHCP Configuration

Configure your DHCP server to point devices to the bootstrap script using DHCP Option 67 (bootfile-name):

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

## Security Features

- **HTTPS Only**: All traffic encrypted with TLS 1.2/1.3
- **Security Headers**: 
  - Strict-Transport-Security (HSTS)
  - Content-Security-Policy
  - X-Frame-Options: DENY
  - X-Content-Type-Options: nosniff
  - X-XSS-Protection
- **No Cache**: Bootstrap script served with no-cache headers
- **Access Control**: Hidden files and backup files blocked
- **Resource Limits**: Memory and CPU limits configured in container

## How It Works

1. **Device Boot**: Arista switch boots and requests DHCP configuration
2. **DHCP Response**: DHCP server provides network config and bootstrap script URL
3. **Script Download**: Switch downloads `bootstrap.py` from the HTTPS endpoint
4. **Script Execution**: Switch executes the bootstrap script
5. **CVaaS Enrollment**: Script enrolls device with CVaaS using the enrollment token
6. **Configuration**: CVaaS pushes device configuration

## Troubleshooting

### Service Won't Start

1. Check logs:
   ```bash
   sudo journalctl -u ztpbootstrap.container
   ```

2. Verify certificates:
   ```bash
   ls -la /opt/containerdata/certs/wild/
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout
   ```

3. Check network:
   ```bash
   ip addr show  # Ensure IPs are assigned
   ```

4. Verify nginx configuration:
   ```bash
   sudo podman run --rm -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t
   ```

### Bootstrap Script Issues

1. Verify script is accessible:
   ```bash
   curl -k https://ztpboot.example.com/bootstrap.py
   ```

2. Check script configuration:
   ```bash
   grep -A 5 "cvAddr\|enrollmentToken" /opt/containerdata/ztpbootstrap/bootstrap.py
   ```

3. Test script manually (on an Arista switch):
   ```bash
   python3 /tmp/bootstrap.py
   ```

### SSL Certificate Issues

1. Check certificate validity:
   ```bash
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout
   ```

2. Verify domain coverage:
   ```bash
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout | grep -A 1 "Subject Alternative Name"
   ```

3. Check certificate expiration:
   ```bash
   openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -noout -dates
   ```

### Device Cannot Download Script

1. Verify DNS resolution:
   ```bash
   nslookup ztpboot.example.com
   ```

2. Test HTTPS connectivity:
   ```bash
   curl -v https://ztpboot.example.com/health
   ```

3. Check firewall rules:
   ```bash
   sudo firewall-cmd --list-all  # or iptables -L
   ```

4. Verify DHCP configuration:
   - Ensure Option 67 (bootfile-name) is set correctly
   - Verify the URL matches exactly: `https://ztpboot.example.com/bootstrap.py`

## Files Structure

```
/opt/containerdata/ztpbootstrap/
├── bootstrap.py              # Arista ZTP bootstrap script (edit this)
├── bootstrap_configured.py   # Generated script (if using setup.sh)
├── bootstrap.py.backup       # Backup of original script
├── nginx.conf               # Nginx configuration
├── ztpbootstrap.env         # Environment variables (for reference)
├── ztpbootstrap.env.template # Environment template
├── setup.sh                 # Setup script (may not work as expected)
├── test-service.sh          # Service testing script
└── README.md               # This file

/etc/containers/systemd/ztpbootstrap/
└── ztpbootstrap.container   # Systemd quadlet configuration (if present)

/opt/containerdata/certs/wild/
├── fullchain.pem           # SSL certificate
└── privkey.pem             # SSL private key
```

## Testing

Run the test script to verify service configuration:

```bash
sudo /opt/containerdata/ztpbootstrap/test-service.sh
```

This will check:
- Network configuration
- SSL certificates
- Container configuration
- Nginx configuration
- DNS resolution
- Service status

## Support

For issues related to:

- **Arista ZTP**: Check [Arista Documentation](https://www.arista.com/en/support/documentation)
- **CVaaS**: Contact Arista Support or check [CVaaS Documentation](https://www.arista.com/en/products/eos/eos-cloudvision)
- **This Service**: Check logs and configuration files

## License

This service uses the Arista bootstrap script which is governed by the Apache License 2.0.

## Notes

- The bootstrap script contains hardcoded configuration values that must be edited directly
- The `setup.sh` script attempts to use environment variables, but the bootstrap script doesn't currently support this
- Ensure the enrollment token is valid and not expired
- The service requires valid SSL certificates to function properly
- Devices must be able to reach the service over HTTPS on port 443
