# Building the WebUI Container Image

The WebUI image (`registry.fedoraproject.org/fedora:41`) is built from `webui/Containerfile`
and has all dependencies baked in — no packages are installed at container start.

## Build

```bash
# Build from the repo root
podman build -t ztpbootstrap-webui:local -f webui/Containerfile .
```

## Use the Local Build

Update `versions.env` to point at your local tag:

```bash
# In versions.env, change:
WEBUI_IMAGE=ztpbootstrap-webui:local
```

Then re-run the installer (`./setup.sh` or `./setup-interactive.sh`) so the quadlet
is updated and the service restarted.

## Update Dependencies

To pick up new Python packages:

1. Edit `webui/requirements.txt`
2. Rebuild: `podman build -t ztpbootstrap-webui:local -f webui/Containerfile .`
3. Update `WEBUI_IMAGE` in `versions.env` and redeploy

## Runtime Installs Are Removed

The default image has everything pre-installed. `start-webui.sh` does not run
`dnf install` or `pip install` at startup. If you see install commands running, the
wrong image tag is in use.

> **Do not use `:latest`** — all `Image=` lines in quadlets must be pinned tags.
> See `versions.env` for the single source of truth.
