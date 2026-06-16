# ZTP Bootstrap Container Inventory

## Expected Containers When DHCP is Running

When the DHCP service is enabled and running, you should see exactly **4 containers**:

1. **ztpbootstrap-infra** - Pod infrastructure container (manages the pod network)
2. **ztpbootstrap-nginx** - Nginx web server (reverse proxy)
3. **ztpbootstrap-webui** - Web UI container (Flask application)
4. **ztpbootstrap-dhcp** - DHCP server container (Kea with IPv4 and IPv6 support)

All containers run within the `ztpbootstrap` pod.

## Container Naming Convention

All containers use the `ztpbootstrap-` prefix for clarity:
- `ztpbootstrap-infra` - Infrastructure
- `ztpbootstrap-nginx` - Web server
- `ztpbootstrap-webui` - Web UI
- `ztpbootstrap-dhcp` - DHCP server

## Cleanup

If you see containers with names like:
- `ztpbootstrap-dhcp-test` - Old test container (should be removed)
- `ztpbootstrap-*-old` - Old containers (should be removed)

These are leftovers from testing or previous deployments and should be cleaned up:

```bash
# Remove old test containers
sudo podman rm -f ztpbootstrap-dhcp-test

# Remove old systemd service files
sudo rm -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap-dhcp-test.container
sudo systemctl daemon-reload
sudo systemctl reset-failed ztpbootstrap-dhcp-test.service
```

## Verification

To verify the correct containers are running:

```bash
sudo podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep ztpbootstrap
```

Expected output:
```
NAMES               IMAGE                                     STATUS
ztpbootstrap-infra                                            Up X hours
ztpbootstrap-nginx  docker.io/library/nginx:alpine            Up X hours (healthy)
ztpbootstrap-webui  localhost/ztpbootstrap-webui:local        Up X minutes (healthy)
ztpbootstrap-dhcp   registry.fedoraproject.org/fedora:latest  Up X minutes
```
