# AGENTS.md

## Cursor Cloud specific instructions

### Overview

This is the **Arista ZTP Bootstrap Service** — a containerized service providing a secure HTTPS endpoint for serving bootstrap scripts to Arista network switches during initial boot. It consists of a Nginx web server and a Flask Web UI management dashboard, both running in a Podman pod. The DHCP feature branch adds an optional **Kea DHCP server** managed from the same dashboard.

### Key services

| Service | Description | Dev command |
|---------|-------------|-------------|
| Flask WebUI | Management dashboard (Flask/Python) | `cd webui && ZTP_CONFIG_DIR=/tmp/ztpbootstrap-dev python3 -m flask run --host=0.0.0.0 --port=5000` |
| Nginx | Serves bootstrap.py over HTTPS | Runs in Podman container (not started in dev) |
| Kea DHCP | Optional DHCPv4/v6 server | Deployed via WebUI toggle or `systemd/ztpbootstrap-dhcp.container` |

### Running the Flask WebUI locally

The WebUI expects a `ZTP_CONFIG_DIR` environment variable pointing to a directory with `config.yaml`, `bootstrap.py`, and `nginx.conf`. For local development:

```bash
mkdir -p /tmp/ztpbootstrap-dev/logs /tmp/ztpbootstrap-dev/scripts
cp bootstrap.py nginx.conf /tmp/ztpbootstrap-dev/
cp config.yaml.template /tmp/ztpbootstrap-dev/config.yaml
cd webui && ZTP_CONFIG_DIR=/tmp/ztpbootstrap-dev FLASK_DEBUG=1 python3 -m flask run --host=0.0.0.0 --port=5000
```

The dashboard will be available at `http://localhost:5000/`. Use the **DHCP Server** app in the multi-app dashboard to configure reservations, OUI filtering, and container lifecycle.

### DHCP development notes

- Kea configs live under `dhcp/`; runtime leases/logs are gitignored.
- Backend modules: `webui/dhcp_*.py`, `webui/kea_client.py`.
- Integration tests require Podman and are in `tests/integration/test_dhcp_api.bats`.
- See `docs/DHCP_TESTING.md` and `docs/DHCP_IMPLEMENTATION_PLAN.md` for full setup.

### Runtime ZTP network

Production deployments attach the pod to a ZTP VLAN via Podman macvlan from the **ZTP Network** Web UI tab. Feature design: `docs/RUNTIME_ZTP_NETWORK_SPEC.md`. Host VLAN, firewall, and migration steps (not automated by the UI): `docs/ZTP_NETWORK_HOST_SETUP.md`.

### Lint, test, format

Standard commands are in the `Makefile` — run `make help` for the full list. Key commands:

- **Lint:** `make lint` (runs shellcheck + yamllint)
- **Unit tests:** `make test-unit` (BATS + Python)
- **CI tests:** `make test-ci` (file existence, permissions, syntax)
- **Format:** `make format` (black for Python)
- **All checks:** `make check`

### Gotchas

- **BATS test helpers**: Unit tests require `bats-support` and `bats-assert` in `tests/unit/test_helper/`. These are cloned from GitHub and are gitignored. Install with:
  ```bash
  mkdir -p tests/unit/test_helper
  cd tests/unit/test_helper
  git clone --depth 1 https://github.com/bats-core/bats-support.git
  git clone --depth 1 https://github.com/bats-core/bats-assert.git
  ```
- **black config**: `pyproject.toml` uses `target-version = ['py3']` which is invalid for black >= 23.x. The CI allows black to fail gracefully (`|| echo`). Use `black==24.1.1` to match the `.pre-commit-config.yaml` version.
- **Podman, not Docker**: This project uses Podman exclusively. Do not use Docker commands.
- **Integration tests** require a running Podman pod (not available in typical cloud agent environments). Unit tests and CI tests work without Podman.
- **`~/.local/bin` must be on PATH** for pip-installed tools (black, isort, flask). The update script handles this.
