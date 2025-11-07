# Arista ZTP Bootstrap Service

A containerized service that provides a secure HTTPS endpoint for serving Arista Zero Touch Provisioning (ZTP) bootstrap scripts to network devices. The service runs an nginx container that serves the bootstrap script over HTTPS with proper security headers, enabling automated device provisioning and enrollment with Arista CloudVision (CVaaS).

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

## Quick Start

**Prerequisites:** Podman installed, SSL certificates ready (or use [HTTP-only mode](#http-only-setup) for testing)

```bash
# 1. Prepare directories
sudo mkdir -p /opt/containerdata/ztpbootstrap
sudo mkdir -p /opt/containerdata/certs/wild

# 2. Copy service files to /opt/containerdata/ztpbootstrap/
#    - bootstrap.py (configure with your CVaaS settings)
#    - nginx.conf
#    - ztpbootstrap.env (optional)

# 3. Configure bootstrap.py with your enrollment token
#    Edit cvAddr and enrollmentToken in the USER INPUT section

# 4. Place SSL certificates
#    - /opt/containerdata/certs/wild/fullchain.pem
#    - /opt/containerdata/certs/wild/privkey.pem

# 5. Configure network IPs (if needed)
sudo ip addr add 10.0.0.10/24 dev <interface>

# 6. Start the service
sudo podman run -d \
  --name ztpbootstrap \
  --network host \
  -v /opt/containerdata/ztpbootstrap:/usr/share/nginx/html:ro \
  -v /opt/containerdata/certs/wild:/etc/nginx/ssl:ro \
  -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine

# 7. Verify it's working
curl -k https://ztpboot.example.com/health
```

**For automated setup:** Use the [setup script](#automated-setup) or [systemd quadlet](#systemd-integration) for production deployments.

**Need more details?** See:
- [Detailed Setup Guide](#detailed-setup) - Step-by-step instructions for beginners
- [Configuration](#configuration) - All configuration options
- [SSL Certificates](#ssl-certificates) - Certificate setup options including [HTTP-only mode](#http-only-setup)
- [Network Configuration](#network-configuration) - IP addresses and DHCP setup
- [Service Management](#service-management) - Starting, stopping, monitoring

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

### Step 5: Set Up SSL Certificates

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

### Step 6: Configure Network

Assign IP addresses to your network interface:

```bash
# Identify your interface
ip addr show

# Assign IPv4 address
sudo ip addr add 10.0.0.10/24 dev <interface>

# Assign IPv6 address (if needed)
sudo ip -6 addr add 2001:db8::10/64 dev <interface>

# Verify
ip addr show <interface>
```

**Important:** To make IP assignments persistent across reboots, configure them in your network manager (NetworkManager, netplan, etc.) or add them to `/etc/network/interfaces` (Debian/Ubuntu) or network-scripts (RHEL/CentOS).

See [Network Configuration](#network-configuration) for details.

### Step 7: Start the Service

**Option A: Manual Podman Command**

```bash
sudo podman run -d \
  --name ztpbootstrap \
  --network host \
  -v /opt/containerdata/ztpbootstrap:/usr/share/nginx/html:ro \
  -v /opt/containerdata/certs/wild:/etc/nginx/ssl:ro \
  -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:alpine
```

**Option B: Automated Setup Script**

```bash
# Configure environment file first
sudo vi /opt/containerdata/ztpbootstrap/ztpbootstrap.env

# Run setup script
sudo /opt/containerdata/ztpbootstrap/setup.sh

# For HTTP-only mode (testing only)
sudo /opt/containerdata/ztpbootstrap/setup.sh --http-only
```

**Option C: Systemd Quadlet (Recommended for Production)**

See [Systemd Integration](#systemd-integration) for automatic startup and service management.

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
podman logs ztpbootstrap
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
   sudo podman run -d \
     --name ztpbootstrap \
     --network host \
     -v /opt/containerdata/ztpbootstrap:/usr/share/nginx/html:ro \
     -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro \
     nginx:alpine
   ```

3. **Update systemd quadlet** (if using) - Change `PublishPort=443:443` to `PublishPort=80:80` and remove certificate volume mount

</details>

---

## Service Management

### Start/Stop/Restart

**Using Podman directly:**
```bash
# Start
sudo podman start ztpbootstrap

# Stop
sudo podman stop ztpbootstrap

# Restart
sudo podman restart ztpbootstrap
```

**Using systemd (if using quadlet):**
```bash
# Start
sudo systemctl start ztpbootstrap.container

# Stop
sudo systemctl stop ztpbootstrap.container

# Restart
sudo systemctl restart ztpbootstrap.container

# Enable on boot
sudo systemctl enable ztpbootstrap.container
```

### View Logs

**Podman logs:**
```bash
# Follow logs in real-time
sudo podman logs -f ztpbootstrap

# View recent logs
sudo podman logs --tail 100 ztpbootstrap
```

**Systemd logs (if using quadlet):**
```bash
# Follow logs in real-time
sudo journalctl -u ztpbootstrap.container -f

# View recent logs
sudo journalctl -u ztpbootstrap.container --since "1 hour ago"
```

### Check Status

```bash
# Container status
sudo podman ps | grep ztpbootstrap

# Systemd service status (if using quadlet)
sudo systemctl status ztpbootstrap.container
```

### Systemd Integration {#systemd-integration}

For automatic startup and service management, use systemd quadlets:

**Create quadlet file:**
```bash
sudo mkdir -p /etc/containers/systemd/ztpbootstrap

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

# Start and enable
sudo systemctl start ztpbootstrap.container
sudo systemctl enable ztpbootstrap.container
```

**Note:** For Ubuntu/Debian, quadlet support may require additional setup. See [Detailed Setup](#detailed-setup) for alternatives.

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
   sudo journalctl -u ztpbootstrap.container
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
└── ztpbootstrap.container   # Systemd quadlet configuration (if present)

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
