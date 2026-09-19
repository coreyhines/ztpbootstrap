# network-host-apply — H1 worker contract

Status: **frozen for H2/H3**. Implements spec #13/#57 + `/api/network/restart`.
Single source of truth H2/H3 must not contradict. Runs no live infra, touches no
secrets, changes no code.

## 1. Threat model / boundary

- WebUI container is **untrusted**: may be stopped, restarted, or have its IP
  change. It must not run shell or choose unit names, executable paths, output
  paths, or arbitrary podman commands.
- A privileged **host worker** (root, outside the pod) performs every host
  mutation; its code is read-only from the WebUI's point of view.
- WebUI sends only: (a) a validated `network.ztp` profile dict, (b) a `restart`
  op, (c) `status`/`capabilities` queries. That is the entire surface.

## 2. Components

| Component | Lives in | Owns |
|---|---|---|
| `ztpbootstrap-network-worker.service` | host systemd, **no** `PartOf`/`BindsTo` to pod | socket, job state, host mutations |
| `scripts/network-host-worker.py` | installed to `/usr/local/lib/ztpbootstrap/worker.py` | protocol server |
| `webui/network_jobs.py` | shipped with webui **and** copied to `/usr/local/lib/ztpbootstrap/network_jobs.py` | protocol + client + worker entrypoint + `JobStore` |
| `/run/ztpbootstrap/network-worker.sock` | host runtime dir, bind-mounted into webui | the socket |
| `/opt/containerdata/ztpbootstrap/.network-jobs/` | on the rw bind, **root-only 0700** subdir | durable job records |

`/usr/local/lib/ztpbootstrap/` is the **immutable worker code path**: *outside*
`webui/` (the `rw` container bind), so a stopped/misbehaving WebUI cannot rewrite
worker logic. `install-network-worker.sh` copies `webui/network_*.py` +
`network_jobs.py` into that dir (0555 root) and installs the worker unit.

### Worker imports (no CONTAINER_HOST)

The worker runs on the **host**, not the container, and must import the
*installed* trusted modules, not the WebUI bind. `network-host-worker.py` does,
before any import:

```python
import sys
from pathlib import Path
sys.path.insert(0, "/usr/local/lib/ztpbootstrap")                       # wins
sys.path.insert(0, "/opt/containerdata/ztpbootstrap/webui")
```

`/usr/local/lib/ztpbootstrap` wins for `network_jobs`/`network_deploy`/
`network_config`/`network_utils`/`network_validation`. The worker uses the **host**
podman: `get_podman_cmd()` with no `CONTAINER_HOST`/`CONTAINER_SOCK`; it does
**not** use the `ro`-mounted `/run/podman/podman.sock` inside the container.
Config is read fresh through `ConfigManager(ZTP_CONFIG_DIR=".../ztpbootstrap")`,
same locking/atomic/backup as the WebUI (shared lock file serializes both).

Existing Podman socket users (the `ro,z` webui mount, DHCP path) are
**unchanged**, pending live-host diagnosis (#57). This contract adds a separate
host-side socket only.

## 3. Transport

Single `AF_UNIX`/`SOCK_STREAM`. The webui quadlet gains one mount so the
container reaches it:

```
Volume=/run/ztpbootstrap:/run/ztpbootstrap:ro,z
```

`ro` is fine for connect(): the client only opens the fd, never writes the
filesystem. Worker owns the dir `0700 root`; the socket file is
`0660 root:ztpbootstrap-jobs`, and the container's mapped uid must be in group
`ztpbootstrap-jobs` (created by install) to connect.

**SELinux (honest; no `permissive`, no `unconfined`):** connecting to a host
worker socket from a `container_t`-ish domain needs an allow rule. Install writes
`systemd/ztpbootstrap-network-worker.te` + a `.if` interface and loads them via
`semodule` **only in Enforcing** mode, scoped to `container_connect_ztpbootstrap_sock`
(webui→worker socket) and `ztpbootstrap_worker_connect_systemd`/`podman`
(worker→units). If the live host is not SELinux-managed, install detects
`getenforce != Enforcing`, skips module load, and logs that the socket relies on
that posture **only there**. No `setenforce 0` anywhere, no blanket privileges.

## 4. Protocol (fixed, bounded JSON)

Frame: 4-byte big-endian length prefix + UTF-8 JSON body, max
`MAX_MESSAGE_BYTES = 64 * 1024`. One request per connection, one response.
`PROTOCOL_VERSION = 1`. Requests are a dict with `op` in an allowlist; unknown
`op` → error. No field may carry shell, command, unit, path, or exec input.

### Requests

```python
{"v": 1, "op": "capabilities"}                                  # no side effect
{"v": 1, "op": "restart"}                                       # no payload
{"v": 1, "op": "apply",
 "ztp": {"enabled": True, "parent_interface": "enp7s0.5", "vlan_id": 5,
         "podman_network": "ztp-net-5", "macvlan_mode": "bridge",
         "ipv4": {"address": "10.0.5.10", "subnet": "10.0.5.0/24", "gateway": "10.0.5.1"},
         "ipv6": {"address": "", "subnet": "", "gateway": ""}}}   # ztp schema keys only
{"v": 1, "op": "status", "job_id": "<uuid4 or null>"}            # omit id -> active+recent
```

### Response / job record (no secrets)

```python
{
  "v": 1, "ok": True,                  # false for protocol/validation error
  "error": None,                      # short code from ERROR_CODES, never a traceback
  "capabilities": {"version": 1, "ops": ["apply","restart","status"],
                   "worker": "ztpbootstrap-network-worker@host", "podman": "podman 5.8.4"},
   "job": {                            # present on apply/restart/status
      "job_id": "<uuid4>", "op": "apply|restart",
      "state": "queued|running|succeeded|failed|rollback_failed|stale",
      "created_at": "<iso z>", "updated_at": "<iso z>", "timeout_at": "<iso z>",
      "error_code": None,             # ERROR_CODES only
      "detail": "short human text",   # no secrets, <=512 chars
      "changed_endpoint": None,        # apply: {"before": "...", "after": "https://10.0.5.10"}
      "podman_network": "ztp-net-5",
      "effective_applied": False},     # True only after post-check verifies pod+network
}
```

`ERROR_CODES = {bad_protocol, bad_request, validation, duplicate, worker_busy, timeout, podman_failed, rollback_failed, stale, worker_down}`. Status never carries credentials, tokens, or raw podman error blobs.

### Semantics

- **Single active job:** at most one non-terminal job; `apply`/`restart` while a job is `queued`/`running` returns the **existing** job with `error="duplicate"` (idempotent) and the caller polls that id — no 2nd mutation.
- **Durable acceptance:** the worker writes the record atomically (tmp + `os.replace`, 0600) and flushes **before** the response, so a post-acceptance crash leaves a recoverable on-disk job.
- **Effective success:** `succeeded` only after a post-check confirms the pod runs and the target `podman_network` exists with the expected parent (`inspect_running_pod` + `inspect_podman_network`); a transport timeout or a queued job is **never** success.
- **Rollback:** on any post-backup failure the worker restores the captured backup (quadlet + config + network), regenerates Kea, and restarts the stack if stopped, reusing `network_deploy` `create_network_backup`/`restore_network_backup`/`_rollback_network_apply`; if rollback fails -> `rollback_failed` (a half-applied state is never hidden as success).
- **Concurrency preservation:** the worker mutates via `ConfigManager.update(mutator, validate)` under the exclusive lock against *fresh* state, touching only `network.ztp` + legacy mirror fields (same as `_save_ztp`); unrelated sections (dhcp, auth, cvaas) are never overwritten.
- **Timeout:** `JOB_TIMEOUT_SEC = 180`; past `timeout_at` the worker marks the job `failed` (`error_code="timeout"`) and does not claim success.
- **Stale / reboot:** on startup any `running` job is marked `stale` (`STALE_AFTER_SEC = 300`); a reboot or pod stop may leave host state indeterminate, so stale jobs never auto-report success — the operator re-runs.
- **Retention:** keep newest `MAX_RETENTION = 50` terminal jobs; prune oldest.

## 5. Shared module: `webui/network_jobs.py`

H2 implements it; H3 imports the client side. Signatures H2/H3 share:

```python
# --- constants (importable by H2 worker and H3 flask) ---
PROTOCOL_VERSION = 1
SOCKET_PATH = "/run/ztpbootstrap/network-worker.sock"
STATE_DIR = Path("/opt/containerdata/ztpbootstrap/.network-jobs")
JOB_TIMEOUT_SEC = 180
STALE_AFTER_SEC = 300
MAX_RETENTION = 50
MAX_MESSAGE_BYTES = 64 * 1024
JOB_STATES = ("queued","running","succeeded","failed","rollback_failed","stale")

# --- protocol (H2 writes; tests mock the socket) ---
def encode(message: dict) -> bytes: ...
def decode(buf: bytes) -> dict: ...                        # raises on >MAX / bad JSON
def build_apply_request(ztp_profile: dict) -> dict: ...     # whitelist keys only
def build_restart_request() -> dict: ...
def build_status_request(job_id: str | None = None) -> dict: ...
def build_capabilities_request() -> dict: ...
def validate_request(req: dict) -> tuple[bool, str | None]: ...   # allowlist ops+keys

# --- durable job store (host-only state, H2) ---
class JobStore:
    def __init__(self, state_dir: Path = STATE_DIR) -> None: ...
    def create(self, op: str, ztp: dict | None) -> "JobRecord": ...   # atomic write
    def get(self, job_id: str) -> "JobRecord | None": ...
    def active(self) -> "JobRecord | None": ...                   # single active job
    def update(self, job_id: str, *, state: str, **fields) -> "JobRecord": ...
    def mark_stale_on_boot(self) -> list["JobRecord"]: ...
    def list_recent(self, limit: int = MAX_RETENTION) -> list["JobRecord"]: ...
    def prune(self) -> None: ...

# --- client (H3 calls; talks to worker over the socket) ---
class NetworkJobClient:
    def __init__(self, socket_path: str = SOCKET_PATH, timeout: float = 5.0) -> None: ...
    def request(self, message: dict) -> dict: ...                # one round trip
    def enqueue_apply(self, ztp_profile: dict) -> dict: ...       # -> {ok, job} or error
    def enqueue_restart(self) -> dict: ...
    def status(self, job_id: str | None = None) -> dict: ...
    def capabilities(self) -> dict: ...
    def is_available(self) -> bool: ...                          # worker_down vs live
    def close(self) -> None: ...

# --- worker entrypoint (H2, runs on host) ---
def run_worker(socket_path: str = SOCKET_PATH,
               state_dir: Path = STATE_DIR,
                *, config_manager=None, stop_event=None,
               podman_cmd_factory=None) -> None: ...
```

`JobRecord` is a dataclass mirroring the §4 record. The client never blocks on a
running apply: `enqueue_*` returns after durable acceptance; H3 polls
`status(job_id)`.

### Mockability

All socket I/O sits behind `NetworkJobClient.request` and `run_worker`'s accept
loop. Tests substitute `podman_cmd_factory` and `JobStore(tmp_path)`; no real
podman/systemctl. `run_worker` accepts `stop_event` for in-process test servers.

## 6. Worker systemd unit (`systemd/ztpbootstrap-network-worker.service`)

```ini
[Unit]
Description=ZTP network host worker
After=network-online.target
# Deliberately NO PartOf=/BindsTo=ztpbootstrap-pod.service: stopping the whole
# pod must NOT stop this worker or lose in-flight job state.
WantedBy=multi-user.target default.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/network-host-worker   # thin wrapper adding LIBDIR to sys.path
Restart=on-failure
RestartSec=3
# no new caps beyond what podman/systemctl already need

[Install]
WantedBy=multi-user.target default.target
```

## 7. H3 API / UI contract (names H3 must keep)

- `POST /api/network/apply` → on durable enqueue returns **HTTP 202** with
  `{"job_id": ..., "state": "queued"}`, **not** 200; 503 only if worker down.
- `POST /api/network/restart` → same 202 pattern.
- `GET /api/network/jobs/<job_id>` (new, `@require_auth`) → authenticated status
   poll returning the §4 `job` record; 404 if unknown.
- `GET /api/network/jobs` → recent terminal + active job list.
- UI: after 202 it polls `GET /api/network/jobs/<id>`. On connect loss or IP
   change it shows `changed_endpoint.after` and a **reconnect** affordance; it
   renders `timeout`/`stale`/`rollback_failed` explicitly and **never** says
   "applied" for them. Success shown only on `state=="succeeded"` with
   `effective_applied==true`.

## 8. H2 deliverables (not written by this bucket)

`webui/network_jobs.py` + `tests/unit/test_network_jobs.py`;
`scripts/network-host-worker.py`, `scripts/install-network-worker.sh`;
`systemd/ztpbootstrap-network-worker.service`, the `.container` mount in
`ztpbootstrap-webui.container`, SELinux `.te`/`.if` (Enforcing-scoped); and
transaction/rollback tests added to `tests/unit/test_network_deploy.py`.

## 9. Open / honest items

Live-host SELinux label confirmation and the #57 root cause are read-only
diagnostics captured when the deployment host is confirmed — not inferred here.
If they change the transport/permission model, **revise this doc first** (spec
H1 stop-and-revise) before H2. This bucket performs no code, infra, secret, or
publish action.
