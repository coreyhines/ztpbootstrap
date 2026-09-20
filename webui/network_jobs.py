"""Bounded host-worker protocol, durable jobs, and container-side client.

Importing this module does not import deployment code or start host operations.
"""

from __future__ import annotations

import fcntl
import ipaddress
import json
import os
import re
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROTOCOL_VERSION = 1
SOCKET_PATH = "/run/ztpbootstrap/network-worker.sock"
STATE_DIR = Path("/var/lib/ztpbootstrap-network-worker")
JOB_TIMEOUT_SEC = 900
STALE_AFTER_SEC = 300
MAX_RETENTION = 50
MAX_MESSAGE_BYTES = 64 * 1024
JOB_STATES = ("queued", "running", "succeeded", "failed", "rollback_failed", "stale")
ERROR_CODES = frozenset(
    (
        "bad_protocol",
        "bad_request",
        "validation",
        "duplicate",
        "worker_busy",
        "timeout",
        "podman_failed",
        "rollback_failed",
        "stale",
        "worker_down",
    )
)
PROFILE_KEYS = frozenset(
    (
        "enabled",
        "vlan_id",
        "parent_interface",
        "podman_network",
        "macvlan_mode",
        "ipv4",
        "ipv6",
    )
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _response(*, error: str | None = None, **fields) -> dict:
    return {"v": PROTOCOL_VERSION, "ok": error is None, "error": error, **fields}


def encode(message: dict) -> bytes:
    """Encode one bounded length-prefixed JSON object."""
    if not isinstance(message, dict):
        raise ValueError("Expected object")
    body = json.dumps(message, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if not body or len(body) > MAX_MESSAGE_BYTES:
        raise ValueError("Message too large")
    return struct.pack("!I", len(body)) + body


def decode(buf: bytes) -> dict:
    """Decode one complete frame, rejecting trailing data and non-object JSON."""
    if len(buf) < 4:
        raise ValueError("Incomplete frame")
    length = struct.unpack("!I", buf[:4])[0]
    if not 0 < length <= MAX_MESSAGE_BYTES or len(buf) != length + 4:
        raise ValueError("Invalid frame length")
    value = json.loads(buf[4:].decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("Expected object")
    return value


def _receive(connection: socket.socket) -> dict:
    deadline = time.monotonic() + (connection.gettimeout() or 5.0)

    def read(size: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Frame deadline exceeded")
            connection.settimeout(remaining)
            data = connection.recv(size - len(chunks))
            if not data:
                raise ValueError("Incomplete frame")
            chunks.extend(data)
        return bytes(chunks)

    header = read(4)
    length = struct.unpack("!I", header)[0]
    if not 0 < length <= MAX_MESSAGE_BYTES:
        raise ValueError("Invalid frame length")
    return decode(header + read(length))


def build_apply_request(ztp_profile: dict) -> dict:
    """Drop display metadata, retaining only the editable profile schema."""
    if not isinstance(ztp_profile, dict):
        raise ValueError("Expected profile object")
    return {
        "v": PROTOCOL_VERSION,
        "op": "apply",
        "ztp": {key: value for key, value in ztp_profile.items() if key in PROFILE_KEYS},
    }


def build_restart_request() -> dict:
    return {"v": PROTOCOL_VERSION, "op": "restart"}


def build_status_request(job_id: str | None = None) -> dict:
    return {"v": PROTOCOL_VERSION, "op": "status", "job_id": job_id}


def build_capabilities_request() -> dict:
    return {"v": PROTOCOL_VERSION, "op": "capabilities"}


def validate_profile(profile: dict) -> bool:
    """Type-check every nested field before semantic validation or interpolation."""
    if not isinstance(profile, dict) or set(profile) - PROFILE_KEYS:
        return False
    if profile.get("enabled") is not True:
        return False
    vlan = profile.get("vlan_id")
    if vlan is not None and (type(vlan) is not int or not 1 <= vlan <= 4094):
        return False
    for key, pattern in (
        ("parent_interface", r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,14}"),
        ("podman_network", r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}"),
        ("macvlan_mode", r"bridge|private|vepa|passthru"),
    ):
        value = profile.get(key, "bridge" if key == "macvlan_mode" else "")
        if key == "podman_network" and value == "" and vlan is not None:
            continue
        if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
            return False
    for version in (4, 6):
        block = profile.get(f"ipv{version}", {})
        if not isinstance(block, dict) or set(block) - {"address", "subnet", "gateway"}:
            return False
        try:
            for key, value in block.items():
                if not isinstance(value, str) or len(value) > 80 or value != value.strip():
                    return False
                if value:
                    parsed = (
                        ipaddress.ip_network(value, strict=True)
                        if key == "subnet"
                        else ipaddress.ip_address(value)
                    )
                    if parsed.version != version or "%" in value:
                        return False
            if version == 4 and not all(block.get(key) for key in ("address", "subnet")):
                return False
            if any(block.values()):
                if not block.get("address") or not block.get("subnet"):
                    return False
                subnet = ipaddress.ip_network(block["subnet"])
                if ipaddress.ip_address(block["address"]) not in subnet:
                    return False
                if block.get("gateway") and ipaddress.ip_address(block["gateway"]) not in subnet:
                    return False
        except ValueError:
            return False
    return True


def _valid_id(job_id: str) -> bool:
    try:
        return isinstance(job_id, str) and str(uuid.UUID(job_id, version=4)) == job_id
    except (ValueError, TypeError, AttributeError):
        return False


def validate_request(req: dict) -> tuple[bool, str | None]:
    if not isinstance(req, dict) or type(req.get("v")) is not int or req["v"] != 1:
        return False, "bad_protocol"
    op = req.get("op")
    if not isinstance(op, str) or op not in (
        "apply",
        "restart",
        "status",
        "capabilities",
    ):
        return False, "bad_request"
    allowed = {"v", "op"} | ({"ztp"} if op == "apply" else {"job_id"} if op == "status" else set())
    if set(req) - allowed:
        return False, "bad_request"
    if op == "apply" and not validate_profile(req.get("ztp")):
        return False, "validation"
    if op == "status" and req.get("job_id") is not None and not _valid_id(req["job_id"]):
        return False, "bad_request"
    return True, None


@dataclass
class JobRecord:
    job_id: str
    op: str
    state: str
    created_at: str
    updated_at: str
    timeout_at: str
    error_code: str | None = None
    detail: str = "Accepted; awaiting host execution"
    changed_endpoint: dict | None = None
    podman_network: str = ""
    effective_applied: bool = False

    def to_dict(self) -> dict:
        return asdict(self)


class JobStore:
    """Host-only journal. The worker-instance flock serializes process ownership."""

    def __init__(self, state_dir: Path = STATE_DIR) -> None:
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.state_dir.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            raise PermissionError("Unsafe worker state directory")
        os.chmod(self.state_dir, 0o700)
        self._lock = threading.RLock()

    def _write_json(self, filename: str, payload: dict) -> None:
        fd, name = tempfile.mkstemp(prefix=".job-", dir=self.state_dir)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(payload, stream, allow_nan=False)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.state_dir / filename)
            directory = os.open(self.state_dir, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def _write(self, record: JobRecord) -> None:
        self._write_json(f"{record.job_id}.json", record.to_dict())

    def recovery_required(self) -> bool:
        """Only an operator can clear this host-only marker after remediation."""
        return os.path.lexists(self.state_dir / ".recovery-required")

    def recovery_job(self) -> JobRecord | None:
        try:
            fd = os.open(self.state_dir / ".recovery-required", os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd) as stream:
                data = json.loads(stream.read(1024))
            return self.get(data["job_id"])
        except (OSError, ValueError, KeyError, TypeError):
            # A malformed marker must still block mutations, without leaking data.
            return None

    def create(self, op: str, ztp: dict | None) -> JobRecord:
        with self._lock:
            if self.recovery_required() or self.active():
                raise BlockingIOError("Worker busy")
            now = _now()
            record = JobRecord(
                str(uuid.uuid4()),
                op,
                "queued",
                now,
                now,
                (datetime.now(timezone.utc) + timedelta(seconds=JOB_TIMEOUT_SEC)).isoformat(),
            )
            if ztp:
                record.podman_network = ztp.get("podman_network") or f"ztp-net-{ztp['vlan_id']}"
                address = ztp["ipv4"]["address"]
                record.changed_endpoint = {"before": "", "after": f"https://{address}"}
            self._write(record)
            return record

    def get(self, job_id: str) -> JobRecord | None:
        if not _valid_id(job_id):
            return None
        with self._lock:
            try:
                fd = os.open(self.state_dir / f"{job_id}.json", os.O_RDONLY | os.O_NOFOLLOW)
            except FileNotFoundError:
                return None
            with os.fdopen(fd) as stream:
                data = json.load(stream)
            return JobRecord(**data)

    def active(self) -> JobRecord | None:
        return next(
            (job for job in self.list_recent(limit=None) if job.state in ("queued", "running")),
            None,
        )

    def update(self, job_id: str, *, state: str, **fields) -> JobRecord:
        with self._lock:
            record = self.get(job_id)
            if record is None or state not in JOB_STATES:
                raise ValueError("Invalid job update")
            if fields.get("error_code") not in ERROR_CODES | {None}:
                raise ValueError("Invalid error code")
            for key, value in fields.items():
                if key not in {
                    "error_code",
                    "detail",
                    "changed_endpoint",
                    "podman_network",
                    "effective_applied",
                }:
                    raise ValueError("Immutable job field")
                setattr(record, key, value[:512] if key == "detail" else value)
            record.state, record.updated_at = state, _now()
            if state in ("stale", "rollback_failed"):
                # Persist the block before terminal state. A crash between these
                # writes still prevents a second mutation after worker restart.
                self._write_json(".recovery-required", {"job_id": job_id})
            self._write(record)
            return record

    def mark_stale_on_boot(self) -> list[JobRecord]:
        with self._lock:
            return [
                self.update(
                    job.job_id,
                    state="stale",
                    error_code="stale",
                    detail="Worker interrupted; inspect host and recovery snapshot before retrying",
                )
                for job in self.list_recent(limit=None)
                if job.state in ("queued", "running")
            ]

    def list_recent(self, limit: int | None = MAX_RETENTION) -> list[JobRecord]:
        with self._lock:
            jobs = [self.get(path.stem) for path in self.state_dir.glob("*.json")]
            jobs = sorted(
                (job for job in jobs if job),
                key=lambda job: job.created_at,
                reverse=True,
            )
            return jobs if limit is None else jobs[:limit]

    def prune(self) -> None:
        with self._lock:
            terminal = [
                job
                for job in self.list_recent(limit=None)
                if job.state not in ("queued", "running")
            ]
            blocked = self.recovery_job() if self.recovery_required() else None
            for job in terminal[MAX_RETENTION:]:
                if blocked is None or job.job_id != blocked.job_id:
                    (self.state_dir / f"{job.job_id}.json").unlink()


class NetworkJobClient:
    """One bounded exchange per connection; mutations are never automatically retried."""

    def __init__(self, socket_path: str = SOCKET_PATH, timeout: float = 5.0) -> None:
        self.socket_path, self.timeout = socket_path, timeout

    def request(self, message: dict) -> dict:
        valid, error = validate_request(message)
        if not valid:
            return _response(error=error)
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(self.socket_path)
                connection.sendall(encode(message))
                result = _receive(connection)
                if result.get("v") != PROTOCOL_VERSION or type(result.get("ok")) is not bool:
                    return _response(error="bad_protocol")
                return result
        except (OSError, ValueError, UnicodeError, RecursionError):
            return _response(error="worker_down")

    def enqueue_apply(self, ztp_profile: dict) -> dict:
        try:
            return self.request(build_apply_request(ztp_profile))
        except ValueError:
            return _response(error="validation")

    def enqueue_restart(self) -> dict:
        return self.request(build_restart_request())

    def status(self, job_id: str | None = None) -> dict:
        return self.request(build_status_request(job_id))

    def capabilities(self) -> dict:
        return self.request(build_capabilities_request())

    def is_available(self) -> bool:
        return self.capabilities().get("ok") is True

    def close(self) -> None:
        """No persistent connections are retained."""


def _peer_allowed(connection: socket.socket) -> bool:
    """Fail closed on systems without Linux credentials; initial support is rootful."""
    if not hasattr(socket, "SO_PEERCRED"):
        return False
    _pid, uid, _gid = struct.unpack(
        "3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    )
    return uid == 0


def run_worker(
    socket_path: str = SOCKET_PATH,
    state_dir: Path = STATE_DIR,
    *,
    config_manager=None,
    stop_event=None,
    podman_cmd_factory=None,
) -> None:
    """Serve status independently of a single, non-detached host mutation thread."""
    from network_deploy import HostConfigManager, execute_host_job, get_podman_cmd

    store = JobStore(state_dir)
    stop_event = stop_event or threading.Event()
    manager = config_manager or HostConfigManager(
        Path(os.environ.get("ZTP_CONFIG_DIR", "/opt/containerdata/ztpbootstrap")) / "config.yaml",
        backup_dir=store.state_dir / "config-backups",
    )
    instance_fd = os.open(
        store.state_dir / ".instance.lock",
        os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
        0o600,
    )
    worker_thread = None
    listener = None
    owns_socket = False
    try:
        fcntl.flock(instance_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        store.mark_stale_on_boot()
        runtime = Path(socket_path).parent
        runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        if runtime.is_symlink() or runtime.stat().st_uid != os.geteuid():
            raise PermissionError("Unsafe runtime directory")
        os.chmod(runtime, 0o700)
        if os.path.lexists(socket_path):
            if not stat.S_ISSOCK(os.lstat(socket_path).st_mode):
                raise PermissionError("Worker socket path is not a socket")
            os.unlink(socket_path)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(socket_path)
        owns_socket = True
        os.chmod(socket_path, 0o600)
        listener.listen(8)
        listener.settimeout(0.25)

        def perform(job: JobRecord, profile: dict | None) -> None:
            try:
                store.update(job.job_id, state="running", detail="Host operation in progress")
                result = execute_host_job(
                    manager,
                    job.op,
                    profile,
                    store.state_dir / job.job_id,
                    deadline=time.monotonic() + JOB_TIMEOUT_SEC,
                )
                store.update(job.job_id, **result)
            except Exception:
                # No raw command output or configuration goes into the public journal.
                store.update(
                    job.job_id,
                    state="failed",
                    error_code="podman_failed",
                    detail="Host operation failed; inspect worker journal and recovery snapshot",
                )
            finally:
                store.prune()

        while not stop_event.is_set():
            try:
                connection, _address = listener.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(2.0)
                try:
                    if not _peer_allowed(connection):
                        connection.sendall(encode(_response(error="bad_request")))
                        continue
                    req = _receive(connection)
                    valid, error = validate_request(req)
                    if not valid:
                        response = _response(error=error)
                    elif req["op"] == "capabilities":
                        try:
                            version = subprocess.run(
                                (podman_cmd_factory or get_podman_cmd)() + ["--version"],
                                capture_output=True,
                                text=True,
                                timeout=2,
                            )
                            podman_version = (
                                version.stdout.strip()[:80] if version.returncode == 0 else None
                            )
                        except (OSError, subprocess.TimeoutExpired):
                            podman_version = None
                        response = _response(
                            capabilities={
                                "version": 1,
                                "ops": ["apply", "restart", "status"],
                                "worker": "ztpbootstrap-network-worker@host",
                                "podman": podman_version,
                            }
                        )
                    elif req["op"] == "status":
                        job = store.get(req["job_id"]) if req.get("job_id") else store.active()
                        response = _response(
                            job=job.to_dict() if job else None,
                            recovery_required=store.recovery_required(),
                        )
                        if not req.get("job_id"):
                            response["jobs"] = [entry.to_dict() for entry in store.list_recent()]
                    else:
                        active = store.active()
                        blocked = store.recovery_required()
                        if (
                            blocked
                            or active
                            or (worker_thread is not None and worker_thread.is_alive())
                        ):
                            related_job = active or store.recovery_job()
                            response = _response(
                                error="worker_busy",
                                job=related_job.to_dict() if related_job else None,
                                recovery_required=blocked,
                            )
                        else:
                            profile = req.get("ztp")
                            job = store.create(req["op"], profile)
                            worker_thread = threading.Thread(
                                target=perform, args=(job, profile), daemon=False
                            )
                            worker_thread.start()
                            response = _response(job=job.to_dict())
                    connection.sendall(encode(response))
                except (OSError, ValueError, UnicodeError, RecursionError):
                    try:
                        connection.sendall(encode(_response(error="bad_protocol")))
                    except OSError:
                        pass
    finally:
        if listener:
            listener.close()
        # Never release the instance lock while a mutation or its rollback can run.
        if worker_thread:
            worker_thread.join()
        if owns_socket:
            os.unlink(socket_path)
        os.close(instance_fd)
