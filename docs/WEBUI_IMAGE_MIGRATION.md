# WebUI Container Image

## Current Image

The WebUI container uses a **pinned Fedora-based image** with all dependencies baked in at build time:

```
registry.fedoraproject.org/fedora:41
```

The base image and all pinned versions are tracked in `versions.env` at the repo root.

## What's in the Image

The `webui/Containerfile` builds from `fedora:41` and installs at build time:
- Python 3 + pip
- Podman (for container management from inside the webui)
- systemd tools (for journalctl log access)
- All Python dependencies from `webui/requirements.txt`

At runtime, `start-webui.sh` only does environment configuration and starts the Flask
app — **no package installation happens at container start**.

## Why Fedora (not python:slim or Alpine)

The WebUI manages Podman containers and reads systemd journal logs via mounted host
binaries. These binaries are compiled for glibc, which is incompatible with Alpine
(musl libc). Fedora is the same base as the host deployment targets, providing native
binary compatibility.

## Updating the WebUI Image

The webui base image tag is defined in `versions.env`:

```bash
WEBUI_IMAGE=registry.fedoraproject.org/fedora:41
```

To update:
1. Change `WEBUI_IMAGE` in `versions.env`
2. Update `FROM` in `webui/Containerfile` to match
3. Rebuild: `podman build -t <registry>/ztpbootstrap-webui:<tag> -f webui/Containerfile .`
4. Push to your registry, then run the installer to redeploy

## Building Locally

```bash
# Build from the repo root
podman build -t ztpbootstrap-webui:local -f webui/Containerfile .
```

Then update `WEBUI_IMAGE` in `versions.env` to point at your local tag and re-run
the installer.

## Rollback

To roll back to a previous tag, change `WEBUI_IMAGE` in `versions.env` and redeploy.
There is no `:latest` fallback — all tags must be pinned.

## Verify Running Image

```bash
# Check which image is running
sudo podman inspect ztpbootstrap-webui | grep Image

# Check container is healthy
sudo podman ps | grep ztpbootstrap-webui
sudo podman logs ztpbootstrap-webui
```
