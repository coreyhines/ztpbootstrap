# Building a Custom WebUI Container Image

To avoid installing packages on every container start, you can build a local image with all dependencies pre-installed.

## Quick Start

1. Build the image locally:
   ```bash
   podman build -t ztpbootstrap-webui:local -f webui/Containerfile .
   ```

2. Update the container file to use your local image:
   ```bash
   sudo sed -i 's|Image=registry.fedoraproject.org/fedora:latest|Image=ztpbootstrap-webui:local|' /etc/containers/systemd/ztpbootstrap/ztpbootstrap-webui.container
   ```

3. Reload and restart:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart ztpbootstrap-webui
   ```

## Benefits

- **Faster startup**: No package installation on every container start
- **Local only**: No need for a public registry or version control
- **One-time build**: Build once, use many times
- **Easy updates**: Rebuild when you need to update packages

## Using the Pre-built Image

The container will start much faster since all packages are already installed. The application files are still mounted at runtime, so you can update the code without rebuilding the image.

## Reverting to Runtime Installation

If you want to go back to installing packages at runtime, simply change the image back:
```bash
sudo sed -i 's|Image=ztpbootstrap-webui:local|Image=registry.fedoraproject.org/fedora:latest|' /etc/containers/systemd/ztpbootstrap/ztpbootstrap-webui.container
sudo systemctl daemon-reload
sudo systemctl restart ztpbootstrap-webui
```
