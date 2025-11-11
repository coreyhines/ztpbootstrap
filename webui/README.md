# Web UI for ZTP Bootstrap Service

A lightweight, modern web interface for managing and monitoring the ZTP Bootstrap Service.

## Features

- **Dashboard** - Real-time status monitoring
- **Bootstrap Script Management** - View and manage bootstrap scripts
- **Configuration View** - View current configuration
- **Logs** - View service logs in real-time

## Architecture

- **Backend**: Flask (Python) - lightweight and simple
- **Frontend**: Alpine.js + Tailwind CSS - minimal JavaScript, modern design
- **Integration**: Runs in a Podman pod alongside nginx container
- **Networking**: Uses macvlan network with dedicated IP addresses
- **Communication**: nginx proxies `/ui/` and `/api/` to Flask container

## Content Security Policy (CSP)

The Web UI requires specific CSP settings to function properly:

- **Alpine.js**: Requires `'unsafe-eval'` in `script-src` for its reactivity system
- **Prism.js**: Works with current CSP settings (no additional requirements)
- **Tailwind CSS**: CSS-only, no CSP restrictions
- **CDN Resources**: Allowed from `cdn.jsdelivr.net`, `cdn.tailwindcss.com`, and `cdnjs.cloudflare.com`

**Note**: For enhanced security in the future, consider migrating to Alpine.js CSP-compliant build (`@alpinejs/csp`) which doesn't require `'unsafe-eval'`, but requires refactoring inline expressions to use `Alpine.data()`.

## Setup

### Prerequisites

1. **Macvlan Network**: The macvlan network must already exist. Check if it exists:
   ```bash
   ./check-macvlan.sh
   ```
   
   If the network doesn't exist, you must create it manually. The check script will provide instructions and links to authoritative documentation.

2. **Systemd Files**: Copy pod and container configurations:
   ```bash
   sudo mkdir -p /etc/containers/systemd/ztpbootstrap
   sudo cp systemd/ztpbootstrap.pod /etc/containers/systemd/ztpbootstrap/
   sudo cp systemd/ztpbootstrap-nginx.container /etc/containers/systemd/ztpbootstrap/
   sudo cp systemd/ztpbootstrap-webui.container /etc/containers/systemd/ztpbootstrap/
   ```

3. **Update IP Addresses**: Edit `/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod`:
   ```ini
   IP=10.0.0.10        # Your desired IPv4
   IP6=2001:db8::10    # Your desired IPv6 (optional)
   ```

### Automatic Setup

The setup script will automatically configure the pod:

```bash
sudo ./setup.sh
```

This will:
1. Copy systemd pod and container files
2. Reload systemd daemon
3. Start the pod with both nginx and Web UI containers

### Manual Setup

```bash
# 1. Check macvlan network (must be created manually)
./check-macvlan.sh

# 2. Copy systemd files
sudo mkdir -p /etc/containers/systemd/ztpbootstrap
sudo cp systemd/*.pod systemd/*.container /etc/containers/systemd/ztpbootstrap/

# 3. Update IP addresses in ztpbootstrap.pod

# 4. Reload and start
sudo systemctl daemon-reload
sudo systemctl start ztpbootstrap
sudo systemctl enable ztpbootstrap
```

## Access

Once running, access the Web UI at:
- **HTTPS**: `https://ztpboot.example.com/ui/`
- **HTTP** (if HTTP-only mode): `http://ztpboot.example.com/ui/`

## Container Details

### Pod Structure

- **Pod**: `ztpbootstrap` - Uses macvlan network with dedicated IPs
- **Nginx Container**: `ztpbootstrap-nginx` - Serves bootstrap scripts and proxies to Web UI
- **Web UI Container**: `ztpbootstrap-webui` - Flask application

### Networking

- Containers communicate via pod network (container names as hostnames)
- nginx proxies to `http://ztpbootstrap-webui:5000`
- Ports are directly exposed from containers (not host network)

## Service Management

```bash
# Check pod status
sudo systemctl status ztpbootstrap

# View pod logs
sudo journalctl -u ztpbootstrap -f

# View container logs
podman logs ztpbootstrap-nginx
podman logs ztpbootstrap-webui

# Restart pod
sudo systemctl restart ztpbootstrap

# Stop pod
sudo systemctl stop ztpbootstrap

# Check container status
podman pod ps
podman ps --filter pod=ztpbootstrap
```

## Troubleshooting

### Pod won't start

```bash
# Check if macvlan network exists
./check-macvlan.sh

# If missing, you must create it manually
# See check-macvlan.sh for instructions and authoritative documentation

# Check systemd logs
sudo journalctl -u ztpbootstrap -n 50
```

### Web UI not accessible

```bash
# Check if Web UI container is running
podman ps --filter name=ztpbootstrap-webui

# Check Web UI logs
podman logs ztpbootstrap-webui

# Test from nginx container
podman exec ztpbootstrap-nginx wget -O- http://ztpbootstrap-webui:5000/api/status
```

### Network issues

```bash
# Verify macvlan network
podman network inspect ztpbootstrap-net

# Check pod IP addresses
podman pod inspect ztpbootstrap | grep -A 10 IP

# Test connectivity between containers
podman exec ztpbootstrap-nginx ping -c 2 ztpbootstrap-webui
```

## Security Considerations

- Web UI should only be accessible on internal networks
- Consider adding authentication for production use
- API endpoints are read-only by default (no write operations)
- Containers run in isolated pod network

## Future Enhancements

- Configuration editing via UI
- Upload new bootstrap scripts
- Multiple script management
- Device enrollment tracking
- Real-time metrics and charts
