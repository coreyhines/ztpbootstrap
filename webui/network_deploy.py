#!/usr/bin/env python3
"""
ZTP network deployment — Podman macvlan lifecycle, quadlet sync, stack restart.
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import shutil
import signal
import stat
import subprocess
import time
import uuid
from contextlib import contextmanager
from contextvars import ContextVar
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

from config_manager import ConfigManager
from network_config import (
    get_ztp_profile,
    resolve_effective_network,
    sync_legacy_network_fields,
    utc_now_iso,
)
from network_utils import (
    POD_FILE,
    SYSTEMD_DIR,
    get_podman_cmd,
    inspect_podman_network,
    inspect_running_pod,
    parse_pod_quadlet,
    resolve_ipv6_for_network,
)
from network_validation import plan_network_changes, validate_ztp_profile

logger = logging.getLogger(__name__)

LOCK_FILE = Path("/opt/containerdata/ztpbootstrap/.network-apply.lock")
BACKUP_DIR = Path("/opt/containerdata/ztpbootstrap/.ztpbootstrap-backups/network")
CONFIG_PATH = Path("/opt/containerdata/ztpbootstrap/config.yaml")
SYSTEMCTL_UNIT_NOT_LOADED = 5

SERVICES_STOP_ORDER = [
    "ztpbootstrap-dhcp.service",
    "ztpbootstrap-webui.service",
    "ztpbootstrap-nginx.service",
    "ztpbootstrap-pod.service",
]
SERVICES_START_ORDER = [
    "ztpbootstrap-pod.service",
    "ztpbootstrap-nginx.service",
    "ztpbootstrap-webui.service",
    "ztpbootstrap-dhcp.service",
]


@contextmanager
def network_apply_lock(timeout: int = 5) -> Iterator[None]:
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "a+") as lock_fp:
        deadline = time.time() + timeout
        while True:
            try:
                fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    raise TimeoutError("Another network apply is in progress")
                time.sleep(0.2)
        try:
            yield
        finally:
            fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)


def _run_systemctl(args: List[str], timeout: int = 60) -> subprocess.CompletedProcess:
    base = ["systemctl"] if os.geteuid() == 0 else ["sudo", "systemctl"]
    if args[0] not in ("start", "stop"):
        return _bounded_run(base + args, timeout)
    unit = args[1]
    if unit not in SERVICES_START_ORDER:
        raise ValueError("Unit is outside the network-worker allowlist")
    finish = time.monotonic() + _remaining(timeout)
    try:
        result = _bounded_run(base + [args[0], "--no-block", unit], timeout)
        if result.returncode:
            return result
        while time.monotonic() < finish:
            state = _bounded_run(
                base + ["show", unit, "--property=ActiveState", "--value"],
                min(10, finish - time.monotonic()),
            )
            value = state.stdout.strip()
            if state.returncode:
                return state
            if (args[0] == "start" and value == "active") or (
                args[0] == "stop" and value in ("inactive", "failed")
            ):
                return result
            if args[0] == "start" and value == "failed":
                return subprocess.CompletedProcess(base + args, 1, "", "Service failed")
            time.sleep(min(0.2, max(0, finish - time.monotonic())))
        raise TimeoutError("Service transition timed out")
    except (TimeoutError, subprocess.TimeoutExpired):
        # A killed systemctl client does not cancel the daemon's job. Cancel
        # that exact fixed unit's job before starting any recovery commands.
        token = _OPERATION_DEADLINE.set(time.monotonic() + 15)
        try:
            pending = _bounded_run(base + ["show", unit, "--property=Job", "--value"], 5)
            job = pending.stdout.strip().split(" ", 1)[0]
            if pending.returncode:
                raise RuntimeError("Cannot determine pending service job")
            if job.isdigit() and int(job):
                cancelled = _bounded_run(base + ["cancel", job], 5)
                if cancelled.returncode:
                    raise RuntimeError("Cannot cancel pending service job")
        finally:
            _OPERATION_DEADLINE.reset(token)
        raise


def _run_podman(args: List[str], timeout: int = 60) -> subprocess.CompletedProcess:
    return _bounded_run(_PODMAN_FACTORY.get()() + args, timeout)


def create_network_backup(tag: Optional[str] = None) -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = tag or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = BACKUP_DIR / stamp
    dest.mkdir(parents=True, exist_ok=True)
    if POD_FILE.exists():
        shutil.copy2(POD_FILE, dest / "ztpbootstrap.pod")
    if CONFIG_PATH.exists():
        shutil.copy2(CONFIG_PATH, dest / "config.yaml")
    return dest


def restore_network_backup(backup_path: Path) -> bool:
    """Restore the pod quadlet and managed config leaves, retaining unrelated edits."""
    restored = False
    pod_backup = backup_path / "ztpbootstrap.pod"
    if pod_backup.exists() and POD_FILE.parent.exists():
        shutil.copy2(pod_backup, POD_FILE)
        restored = True
    config_backup = backup_path / "config.yaml"
    if config_backup.exists() and CONFIG_PATH.parent.exists():
        import yaml

        snapshot = yaml.safe_load(config_backup.read_text())
        manager = ConfigManager(CONFIG_PATH)
        ok, error = manager.update(lambda fresh: _merge_managed(fresh, _managed(snapshot)))
        if not ok:
            raise RuntimeError(error or "Could not restore managed network fields")
        restored = True
    return restored


def _load_config_from_backup(backup_path: Path) -> Optional[Dict[str, Any]]:
    config_backup = backup_path / "config.yaml"
    if not config_backup.exists():
        return None
    try:
        import yaml

        data = yaml.safe_load(config_backup.read_text())
        return data if isinstance(data, dict) else None
    except Exception as exc:
        logger.warning(f"Failed to load restored config.yaml: {exc}")
        return None


def _ensure_network_from_backup(backup_path: Path, restored_config: Dict[str, Any]) -> None:
    """Recreate a podman network referenced by the backup pod file if it is missing."""
    pod_backup = backup_path / "ztpbootstrap.pod"
    if not pod_backup.exists():
        return
    network_name = parse_pod_quadlet(pod_backup).get("network")
    if not network_name or network_name == "host":
        return
    if inspect_podman_network(network_name):
        return
    profile = dict(get_ztp_profile(restored_config))
    profile["podman_network"] = network_name
    ok, err = ensure_podman_network(profile)
    if not ok:
        raise RuntimeError(err or f"Failed to restore podman network {network_name}")


def _rollback_network_apply(
    backup_path: Path, fallback_config: Dict[str, Any], stopped: bool
) -> Dict[str, Any]:
    """Restore quadlet + config, recreate network, regen Kea, restart if stopped.

    Returns the restored config so the caller persists it rather than the
    failed candidate config it was trying to apply.
    """
    restore_network_backup(backup_path)
    restored_config = _load_config_from_backup(backup_path) or fallback_config
    _ensure_network_from_backup(backup_path, restored_config)
    _regenerate_kea_configs(restored_config)
    if stopped:
        ok, err = restart_ztp_stack(restored_config)
        if not ok:
            raise RuntimeError(err or "Stack restart during rollback failed")
    return restored_config


def ensure_podman_network(profile: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
    effective = resolve_effective_network(
        {"network": {"ztp": profile}, "container": {"host_network": False}}
    )
    if not effective.get("podman_network"):
        return False, "podman_network name is required"

    name = effective["podman_network"]
    parent = effective.get("parent_interface") or ""
    ipv4_subnet = effective.get("ipv4_subnet") or ""
    ipv4_gateway = effective.get("ipv4_gateway") or ""
    ipv6_subnet = effective.get("ipv6_subnet") or ""
    ipv6_gateway = effective.get("ipv6_gateway") or ""
    mode = effective.get("macvlan_mode") or "bridge"

    existing = inspect_podman_network(name)
    if existing:
        existing_gateways = {
            entry.get("subnet"): entry.get("gateway") or ""
            for entry in existing.get("subnets") or []
        }
        sig_current = (
            existing.get("parent"),
            [(s.get("subnet"), s.get("gateway") or "") for s in existing.get("subnets") or []],
            existing.get("mode") or "bridge",
        )
        sig_desired = (
            parent,
            [
                (ipv4_subnet, ipv4_gateway or existing_gateways.get(ipv4_subnet, "")),
            ]
            + (
                [(ipv6_subnet, ipv6_gateway or existing_gateways.get(ipv6_subnet, ""))]
                if ipv6_subnet
                else []
            ),
            mode,
        )
        if sig_current == sig_desired:
            return True, None
        removed, err = remove_stale_network(name, ztp_only=True)
        if not removed:
            return False, err or f"Could not remove existing network {name}"

    cmd = [
        "network",
        "create",
        "-d",
        "macvlan",
        "--subnet",
        ipv4_subnet,
        "-o",
        f"parent={parent}",
        "-o",
        f"mode={mode}",
    ]
    if ipv4_gateway:
        cmd.extend(["--gateway", ipv4_gateway])
    if ipv6_subnet:
        if ipv6_gateway:
            cmd.extend(["--subnet", ipv6_subnet, "--gateway", ipv6_gateway])
        else:
            cmd.extend(["--subnet", ipv6_subnet])
    cmd.append(name)

    result = _run_podman(cmd, timeout=90)
    if result.returncode != 0:
        return (
            False,
            result.stderr.strip() or result.stdout.strip() or "podman network create failed",
        )
    return True, None


def remove_stale_network(name: str, ztp_only: bool = True) -> Tuple[bool, Optional[str]]:
    if not name or name == "host":
        return True, None
    info = inspect_podman_network(name)
    if not info:
        return True, None
    containers = info.get("containers") or []
    if ztp_only:
        foreign = [c for c in containers if not str(c).startswith("ztpbootstrap")]
        if foreign:
            return (
                False,
                f"Network {name} is shared with foreign containers: {', '.join(foreign)}",
            )
    result = _run_podman(["network", "rm", name], timeout=30)
    if result.returncode != 0 and "no such network" not in (result.stderr or "").lower():
        return False, result.stderr.strip() or "podman network rm failed"
    return True, None


def render_pod_quadlet_content(profile: Dict[str, Any]) -> str:
    effective = resolve_effective_network(
        {"network": {"ztp": profile}, "container": {"host_network": False}}
    )
    if profile.get("enabled") is False:
        lines = [
            "[Unit]",
            "Description=ZTP Bootstrap Service Pod",
            "",
            "[Pod]",
            "PodName=ztpbootstrap",
            "Network=host",
            "",
            "[Service]",
            "Restart=always",
            "",
            "[Install]",
            "WantedBy=multi-user.target default.target",
            "",
        ]
        return "\n".join(lines)

    network_name = effective.get("podman_network") or "ztpbootstrap-net"
    ipv4 = effective.get("ipv4_address") or ""
    ipv6 = effective.get("ipv6_address") or ""
    if ipv6 and network_name:
        resolved = resolve_ipv6_for_network(ipv6, network_name)
        if resolved:
            ipv6 = resolved

    lines = [
        "[Unit]",
        "Description=ZTP Bootstrap Service Pod",
        "",
        "[Pod]",
        "PodName=ztpbootstrap",
        f"Network={network_name}",
    ]
    if ipv4:
        lines.append(f"IP={ipv4}")
    if ipv6:
        lines.append(f"IP6={ipv6}")
    lines.extend(
        [
            "",
            "[Service]",
            "Restart=always",
            "",
            "[Install]",
            "WantedBy=multi-user.target default.target",
            "",
        ]
    )
    return "\n".join(lines)


def sync_pod_quadlet(profile: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
    content = render_pod_quadlet_content(profile)
    tmp_path = POD_FILE.with_name(POD_FILE.name + ".tmp")
    try:
        SYSTEMD_DIR.mkdir(parents=True, exist_ok=True)
        tmp_path.write_text(content)
        os.replace(tmp_path, POD_FILE)
        return True, None
    except OSError as exc:
        try:
            tmp_path.unlink()
        except OSError:
            pass
        return False, str(exc)


def stop_ztp_stack() -> None:
    for service in SERVICES_STOP_ORDER:
        try:
            result = _run_systemctl(["stop", service], timeout=90)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"Timeout stopping {service}") from exc
        # systemctl exits 5 when the unit is not loaded (e.g. no DHCP quadlet
        # installed); a unit that does not exist is already stopped.
        if result.returncode == SYSTEMCTL_UNIT_NOT_LOADED:
            logger.info(f"{service} not loaded; nothing to stop")
            continue
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "stop failed"
            raise RuntimeError(f"Failed to stop {service}: {detail}")


def start_ztp_stack(dhcp_enabled: bool = False) -> None:
    result = _run_systemctl(["daemon-reload"], timeout=30)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "daemon-reload failed"
        raise RuntimeError(f"Failed daemon-reload: {detail}")
    for service in SERVICES_START_ORDER:
        if service.startswith("ztpbootstrap-dhcp") and not dhcp_enabled:
            continue
        try:
            result = _run_systemctl(["start", service], timeout=120)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"Timeout starting {service}") from exc
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "start failed"
            raise RuntimeError(f"Failed to start {service}: {detail}")


def restart_ztp_stack(config: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
    dhcp_enabled = bool((config.get("dhcp") or {}).get("enabled"))
    try:
        stop_ztp_stack()
        start_ztp_stack(dhcp_enabled=dhcp_enabled)
        return True, None
    except Exception as exc:
        return False, str(exc)


def _regenerate_kea_configs(config: Dict[str, Any], config_dir: Optional[Path] = None) -> None:
    """Generate fixed Kea files atomically; any failure aborts the transaction."""
    if not (config.get("dhcp") or {}).get("enabled"):
        return
    from dhcp_config import generate_kea_config

    kea_config = generate_kea_config(config)
    parent = config_dir or CONFIG_PATH.parent
    parent_fd = _open_directory(parent)
    try:
        try:
            os.mkdir("dhcp", mode=0o755, dir_fd=parent_fd)
        except FileExistsError:
            pass
        directory = os.open("dhcp", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    try:
        for key, filename in (
            ("Dhcp4", "kea-dhcp4.conf"),
            ("Dhcp6", "kea-dhcp6.conf"),
            ("Control-agent", "kea-ctrl-agent.conf"),
        ):
            if key in kea_config:
                _atomic_at(
                    directory,
                    filename,
                    json.dumps({key: kea_config[key]}, indent=2).encode(),
                )
    finally:
        os.close(directory)


def _auto_fill_dhcp_subnet(config: Dict[str, Any]) -> Dict[str, Any]:
    ztp = get_ztp_profile(config)
    if not ztp.get("enabled"):
        return config
    dhcp = config.setdefault("dhcp", {})
    ipv4 = dhcp.setdefault("ipv4", {})
    ztp_ipv4 = ztp.get("ipv4") or {}
    if not (ipv4.get("subnet") or "").strip():
        if ztp_ipv4.get("subnet"):
            ipv4["subnet"] = ztp_ipv4["subnet"]
    if not (ipv4.get("gateway") or "").strip():
        if ztp_ipv4.get("gateway"):
            ipv4["gateway"] = ztp_ipv4["gateway"]
    return config


def apply_ztp_network(
    config: Dict[str, Any],
    restart: bool = True,
    current_config: Optional[Dict[str, Any]] = None,
) -> Tuple[bool, Optional[str], Dict[str, Any]]:
    """
    Apply ZTP network profile: validate, network, quadlet, optional restart.

    Returns:
        (success, error_message, updated_config)
    """
    config = sync_legacy_network_fields(config)
    config = _auto_fill_dhcp_subnet(config)
    errors, warnings = validate_ztp_profile(config)
    if errors:
        return False, "; ".join(errors), config
    for warning in warnings:
        logger.warning(warning)

    ztp = get_ztp_profile(config)
    if not ztp.get("enabled"):
        return False, "network.ztp.enabled must be true to apply", config

    current = current_config or config
    plan = plan_network_changes(current, config)

    backup_path: Optional[Path] = None
    stopped = False
    try:
        with network_apply_lock():
            backup_path = create_network_backup()
            if plan.get("restart_required") and restart:
                # Mark stopped before stop so partial failures still trigger rollback restart.
                stopped = True
                stop_ztp_stack()

            for old_network in plan.get("remove_networks") or []:
                ok, err = remove_stale_network(old_network, ztp_only=True)
                if not ok:
                    raise RuntimeError(err or f"Failed to remove {old_network}")

            if plan.get("create_network") or plan.get("replace_network"):
                ok, err = ensure_podman_network(ztp)
                if not ok:
                    raise RuntimeError(err or "Failed to create podman network")

            if (
                plan.get("update_quadlet")
                or plan.get("create_network")
                or plan.get("replace_network")
            ):
                ok, err = sync_pod_quadlet(ztp)
                if not ok:
                    raise RuntimeError(err or "Failed to sync pod quadlet")

            _regenerate_kea_configs(config)

            if restart and plan.get("restart_required"):
                ok, err = restart_ztp_stack(config)
                if not ok:
                    raise RuntimeError(err or "Failed to restart stack")

            network = config.setdefault("network", {})
            ztp = network.setdefault("ztp", {})
            ztp["status"] = "applied"
            ztp["applied_at"] = utc_now_iso()
            ztp["applied_parent"] = ztp.get("parent_interface") or ""
            ztp["applied_network"] = resolve_effective_network(config).get("podman_network") or ""
            ztp["last_error"] = ""
            config = sync_legacy_network_fields(config)
            return True, None, config
    except Exception as exc:
        logger.error(f"Network apply failed: {exc}")
        if backup_path is not None:
            # app.py saves whatever config we return, so hand back the
            # restored one; returning the failed candidate would overwrite
            # the config.yaml the rollback just put back.
            config = _rollback_network_apply(backup_path, current, stopped)
        network = config.setdefault("network", {})
        ztp = network.setdefault("ztp", {})
        ztp["status"] = "error"
        ztp["last_error"] = str(exc)
        return False, str(exc), config


def get_network_status(config: Dict[str, Any]) -> Dict[str, Any]:
    """Build status payload for API including drift detection."""
    ztp = get_ztp_profile(config)
    effective = resolve_effective_network(config)
    quadlet = parse_pod_quadlet()
    pod = inspect_running_pod()
    podman_info = None
    if effective.get("podman_network") and effective.get("podman_network") != "host":
        podman_info = inspect_podman_network(effective["podman_network"])

    drift_items: List[str] = []
    if ztp.get("enabled"):
        desired_network = effective.get("podman_network")
        if quadlet.get("network") and desired_network and quadlet.get("network") != desired_network:
            drift_items.append(
                f"quadlet Network={quadlet.get('network')} expected {desired_network}"
            )
        if (
            quadlet.get("ipv4")
            and effective.get("ipv4_address")
            and quadlet.get("ipv4") != effective.get("ipv4_address")
        ):
            drift_items.append("quadlet IP differs from config")
        if podman_info is None and desired_network:
            drift_items.append(f"podman network {desired_network} does not exist")
        elif podman_info and effective.get("parent_interface"):
            if podman_info.get("parent") != effective.get("parent_interface"):
                drift_items.append("podman network parent differs from config")

    dhcp_subnet = ((config.get("dhcp") or {}).get("ipv4") or {}).get("subnet") or ""
    ztp_subnet = (ztp.get("ipv4") or {}).get("subnet") or ""
    subnet_mismatch = bool(
        dhcp_subnet
        and ztp_subnet
        and dhcp_subnet != ztp_subnet
        and (config.get("dhcp") or {}).get("enabled")
    )

    status = ztp.get("status") or "pending"
    if drift_items and status == "applied":
        status = "drift"

    return {
        "ztp": ztp,
        "effective": {
            "mode": effective.get("mode"),
            "podman_network": effective.get("podman_network"),
            "ipv4_address": effective.get("ipv4_address"),
            "ipv6_address": effective.get("ipv6_address"),
            "parent_interface": effective.get("parent_interface"),
        },
        "quadlet": quadlet,
        "podman": podman_info,
        "pod": pod,
        "drift": bool(drift_items),
        "drift_items": drift_items,
        "subnet_mismatch": subnet_mismatch,
        "status": status,
    }


def auto_detect_from_parent(parent_interface: str) -> Dict[str, Any]:
    """Suggest subnet/gateway from parent interface IPv4."""
    from network_utils import _find_ip_cmd, _interface_ipv4

    ip_cmd = _find_ip_cmd()
    if not ip_cmd or not parent_interface:
        return {}
    ipv4 = _interface_ipv4(ip_cmd, parent_interface)
    if not ipv4:
        return {}
    try:
        import ipaddress

        addr = ipaddress.ip_address(ipv4)
        # Assume /24 for suggestion
        network = ipaddress.ip_network(f"{ipv4}/24", strict=False)
        gateway = str(network.network_address + 1)
        return {
            "ipv4": {
                "subnet": str(network),
                "gateway": gateway,
                "address": str(addr),
            }
        }
    except ValueError:
        return {}


# The host path below is separate from the historical synchronous API. It commits
# only managed leaves against fresh configuration and never restores config.yaml.

_OPERATION_DEADLINE = ContextVar("network_operation_deadline", default=None)
_PODMAN_FACTORY = ContextVar("network_podman_factory", default=get_podman_cmd)
MANAGED_PATHS = (
    ("network", "ztp"),
    ("network", "ipv4"),
    ("network", "ipv6"),
    ("network", "network"),
    ("container", "host_network"),
)


def _open_directory(path: Path) -> int:
    """Pin the deployment directory; subsequent opens cannot follow replaced children."""
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def _read_regular(name: str, directory: int, limit: int = 4 * 1024 * 1024) -> bytes:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError("Unsafe deployment file")
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("Deployment file too large")
        return data


def _atomic_at(directory: int, name: str, data: bytes, mode: int = 0o600) -> None:
    """Atomic replacement relative to an already-pinned directory (never a symlink)."""
    temporary = f".network-{uuid.uuid4().hex}"
    fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        mode,
        dir_fd=directory,
    )
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


class HostConfigManager(ConfigManager):
    """ConfigManager's update API with no-follow reads and host-only backups.

    The container-writable directory is pinned once. Files, including the shared
    lock, must be regular, single-link files; swaps cannot redirect privileged I/O.
    """

    def __init__(self, config_path: Path, backup_dir: Path):
        super().__init__(config_path)
        self._directory = _open_directory(self.config_path.parent)
        self.backup_dir = Path(backup_dir)
        self.backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    @contextmanager
    def _locked(self, exclusive: bool, timeout: Optional[float]) -> Iterator[None]:
        wait = 5 if timeout is None else max(timeout, 0)
        deadline = time.monotonic() + wait
        if not self._lock.acquire(timeout=wait):
            raise TimeoutError("Configuration thread lock busy")
        try:
            fd = os.open(
                self.lock_path.name,
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                0o600,
                dir_fd=self._directory,
            )
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("Unsafe configuration lock")
                while True:
                    try:
                        fcntl.flock(
                            fd,
                            (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB,
                        )
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Configuration lock busy")
                        time.sleep(0.05)
                yield
            finally:
                os.close(fd)
        finally:
            self._lock.release()

    def _read_unlocked(self) -> Dict:
        import yaml

        data = yaml.safe_load(_read_regular(self.config_path.name, self._directory))
        if not isinstance(data, dict):
            raise ValueError("Configuration must be an object")
        return data

    def _write_unlocked(self, config: Dict) -> None:
        import yaml

        try:
            old = _read_regular(self.config_path.name, self._directory)
        except FileNotFoundError:
            old = None
        if old is not None:
            backup_fd = _open_directory(self.backup_dir)
            try:
                _atomic_at(backup_fd, f"config-{uuid.uuid4().hex}.yaml", old)
            finally:
                os.close(backup_fd)
        _atomic_at(
            self._directory,
            self.config_path.name,
            yaml.safe_dump(config, sort_keys=False).encode(),
        )

    def close(self) -> None:
        if self._directory is not None:
            os.close(self._directory)
            self._directory = None


def _remaining(timeout: float) -> float:
    deadline = _OPERATION_DEADLINE.get()
    remaining = timeout if deadline is None else min(timeout, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("Host operation deadline exceeded")
    return remaining


def _bounded_run(command: List[str], timeout: float) -> subprocess.CompletedProcess:
    """Kill and reap the entire command group before returning a timeout."""
    timeout = _remaining(timeout)
    with subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The child exited between the timeout and kill.
            process.communicate()
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def _managed(config: dict) -> list[dict]:
    result = []
    for section, key in MANAGED_PATHS:
        source = config.get(section) or {}
        result.append(
            {
                "path": [section, key],
                "present": key in source,
                "value": deepcopy(source.get(key)),
            }
        )
    return result


def _merge_managed(config: dict, snapshot: list[dict]) -> None:
    for entry in snapshot:
        section, key = entry["path"]
        if entry["present"]:
            config.setdefault(section, {})[key] = deepcopy(entry["value"])
        else:
            config.setdefault(section, {}).pop(key, None)


def _cas_managed(manager: ConfigManager, expected: list[dict], desired: list[dict]) -> dict:
    result = {}

    def mutate(fresh):
        if _managed(fresh) != expected:
            raise RuntimeError("Managed network fields changed concurrently")
        _merge_managed(fresh, desired)
        result.update(deepcopy(fresh))

    ok, error = manager.update(mutate)
    if not ok:
        raise RuntimeError(error or "Network configuration commit failed")
    return result


def verify_effective_stack(config: dict) -> None:
    """Require active units, a running pod and actual infra-container addresses."""
    for service in SERVICES_START_ORDER:
        if service == "ztpbootstrap-dhcp.service" and not (config.get("dhcp") or {}).get("enabled"):
            continue
        result = _run_systemctl(["is-active", "--quiet", service], timeout=10)
        if result.returncode != 0:
            raise RuntimeError(f"Service did not become active: {service}")
    pod = inspect_running_pod()
    if not pod.get("running"):
        raise RuntimeError("ZTP pod is not running")
    effective = resolve_effective_network(config)
    # Pod inspect does not reliably expose addresses across Podman versions.
    # Inspect the pod's infra container, which owns its network namespace.
    result = _run_podman(
        ["pod", "inspect", "ztpbootstrap", "--format", "{{.InfraContainerID}}"],
        timeout=15,
    )
    infra = result.stdout.strip()
    if result.returncode or not infra or not all(c in "0123456789abcdef" for c in infra):
        raise RuntimeError("Could not identify pod network namespace")
    result = _run_podman(["inspect", infra, "--format", "{{json .NetworkSettings}}"], timeout=15)
    if result.returncode:
        raise RuntimeError("Could not inspect pod network namespace")
    settings = json.loads(result.stdout)
    if effective["host_network"]:
        result = _run_podman(
            ["inspect", infra, "--format", "{{.HostConfig.NetworkMode}}"], timeout=15
        )
        if result.returncode or result.stdout.strip() != "host":
            raise RuntimeError("Expected host network mode")
        return
    name = effective["podman_network"]
    attached = (settings.get("Networks") or {}).get(name)
    if attached is None:
        raise RuntimeError("Pod is not attached to the requested network")
    import ipaddress

    for field, actual in (
        ("ipv4_address", "IPAddress"),
        ("ipv6_address", "GlobalIPv6Address"),
    ):
        expected = effective.get(field)
        if expected and (
            not attached.get(actual)
            or ipaddress.ip_address(expected) != ipaddress.ip_address(attached[actual])
        ):
            raise RuntimeError("Pod address differs from requested address")
    network = inspect_podman_network(name)
    if not network or (
        get_ztp_profile(config).get("enabled") and network.get("driver") != "macvlan"
    ):
        raise RuntimeError("Requested network is missing or has the wrong driver")
    if effective.get("parent_interface") and network.get("parent") != effective["parent_interface"]:
        raise RuntimeError("Network parent differs from requested interface")
    if get_ztp_profile(config).get("enabled"):
        expected_subnets = {effective["ipv4_subnet"]: effective["ipv4_gateway"]}
        if effective.get("ipv6_subnet"):
            expected_subnets[effective["ipv6_subnet"]] = effective["ipv6_gateway"]
        actual_subnets = {
            entry.get("subnet"): entry.get("gateway") or ""
            for entry in network.get("subnets") or []
        }
        if (
            set(actual_subnets) != set(expected_subnets)
            or any(
                gateway and actual_subnets[subnet] != gateway
                for subnet, gateway in expected_subnets.items()
            )
            or (network.get("mode") or "bridge") != effective["macvlan_mode"]
        ):
            raise RuntimeError("Network parameters differ from requested profile")
    _remaining(1)


def _snapshot_network(name: str) -> dict | None:
    if not name or name == "host":
        return None
    info = inspect_podman_network(name)
    return deepcopy(info) if info else None


def _restore_network_info(info: dict | None) -> None:
    if not info:
        return
    profile = {
        "enabled": True,
        "podman_network": info["name"],
        "parent_interface": info["parent"],
        "macvlan_mode": info.get("mode") or "bridge",
        "ipv4": {},
        "ipv6": {},
    }
    if info.get("driver") != "macvlan":
        # A previous non-macvlan network is never deleted by this transaction.
        if inspect_podman_network(info["name"]) != info:
            raise RuntimeError("Previous non-macvlan network changed; manual recovery required")
        return
    for entry in info.get("subnets") or []:
        key = "ipv6" if ":" in entry["subnet"] else "ipv4"
        profile[key] = {
            "subnet": entry["subnet"],
            "gateway": entry.get("gateway") or "",
        }
    ok, error = ensure_podman_network(profile)
    if not ok:
        raise RuntimeError(error or "Could not restore previous network")


def execute_host_job(
    manager: ConfigManager,
    op: str,
    profile: dict | None,
    snapshot_dir: Path,
    *,
    deadline: float,
) -> dict:
    """Apply/restart as one serialized transaction owned entirely by the host.

    Recovery has its own bounded allowance and runs before the worker releases its
    single-job lock. Snapshots remain host-only for recovery after a host crash.
    """
    from network_config import merge_ztp_update
    from network_jobs import validate_profile

    token = _OPERATION_DEADLINE.set(deadline)
    before = candidate = None
    committed = None
    quadlet_fd = None
    quadlet_bytes = None
    intended_quadlet = None
    old_network = target_network = None
    stopped = False
    snapshot_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    try:
        before = manager.read_config()
        if op not in ("apply", "restart") or (op == "apply" and not validate_profile(profile)):
            return {
                "state": "failed",
                "error_code": "validation",
                "detail": "Invalid host operation",
            }
        # Revalidate any persisted profile too: the container may edit config.yaml.
        persisted = get_ztp_profile(before)
        if persisted.get("enabled"):
            from network_jobs import build_apply_request

            if not validate_profile(build_apply_request(persisted)["ztp"]):
                raise ValueError("Persisted network profile is invalid")
        candidate = merge_ztp_update(before, profile) if op == "apply" else deepcopy(before)
        errors, _warnings = validate_ztp_profile(candidate)
        if errors:
            return {
                "state": "failed",
                "error_code": "validation",
                "detail": "Host profile validation failed",
            }
        quadlet_fd = _open_directory(POD_FILE.parent)
        quadlet_bytes = _read_regular(POD_FILE.name, quadlet_fd, 65536)
        current_effective = resolve_effective_network(before)
        effective = resolve_effective_network(candidate)
        # Capture actual runtime network, not a draft profile previously saved by UI.
        actual_quadlet = {"network": None, "ipv4": None, "ipv6": None}
        for line in quadlet_bytes.decode().splitlines():
            key, separator, value = line.strip().partition("=")
            field = {"Network": "network", "IP": "ipv4", "IP6": "ipv6"}.get(key)
            if separator and field:
                actual_quadlet[field] = value.strip()
        previous_name = actual_quadlet.get("network") or current_effective["podman_network"]
        old_network = _snapshot_network(previous_name)
        target_network = _snapshot_network(effective["podman_network"])
        for info in (old_network, target_network):
            if (
                info
                and info.get("driver") != "macvlan"
                and op == "apply"
                and info["name"] == effective["podman_network"]
            ):
                raise ValueError("Refusing to replace a non-macvlan network")
        snapshot = {
            "managed": _managed(before),
            "old_network": old_network,
            "target_network": target_network,
            "quadlet": quadlet_bytes.decode(),
        }
        snapshot_fd = _open_directory(snapshot_dir)
        try:
            _atomic_at(snapshot_fd, "recovery.json", json.dumps(snapshot).encode())
        finally:
            os.close(snapshot_fd)
        # Always stop for apply: an apparently no-op desired profile can have drift.
        stopped = True
        stop_ztp_stack()
        if op == "apply":
            ok, error = ensure_podman_network(get_ztp_profile(candidate))
            if not ok:
                raise RuntimeError(error or "Network creation failed")
            intended_quadlet = render_pod_quadlet_content(get_ztp_profile(candidate)).encode()
            if _read_regular(POD_FILE.name, quadlet_fd, 65536) != quadlet_bytes:
                raise RuntimeError("Quadlet changed concurrently")
            _atomic_at(quadlet_fd, POD_FILE.name, intended_quadlet, 0o644)
            committed = _managed(candidate)
            candidate = _cas_managed(manager, _managed(before), committed)
        else:
            fresh = manager.read_config()
            if _managed(fresh) != _managed(before):
                raise RuntimeError("Network configuration changed concurrently")
            candidate = fresh
        _regenerate_kea_configs(candidate, config_dir=manager.config_path.parent)
        start_ztp_stack(dhcp_enabled=bool((candidate.get("dhcp") or {}).get("enabled")))
        verify_effective_stack(candidate)
        fresh = manager.read_config()
        if _managed(fresh) != _managed(candidate) or fresh.get("dhcp") != candidate.get("dhcp"):
            raise RuntimeError("Configuration changed during readiness checks")
        if op == "apply":
            finished = deepcopy(candidate)
            ztp = finished["network"]["ztp"]
            ztp.update(
                status="applied",
                applied_at=utc_now_iso(),
                applied_parent=ztp["parent_interface"],
                applied_network=effective["podman_network"],
                last_error="",
            )
            _cas_managed(manager, committed, _managed(finished))
        return {
            "state": "succeeded",
            "error_code": None,
            "detail": "Host services and effective network verified",
            "effective_applied": True,
        }
    except Exception as exc:
        logger.exception("Host network operation failed")
        timeout = isinstance(exc, (TimeoutError, subprocess.TimeoutExpired))
        if not stopped:
            return {
                "state": "failed",
                "error_code": "timeout" if timeout else "validation",
                "detail": "Host prerequisites or configuration validation failed; no stack mutation performed",
            }
        # No command from the failed attempt remains running when rollback begins.
        recovery_token = _OPERATION_DEADLINE.set(time.monotonic() + 300)
        try:
            stop_ztp_stack()
            if committed is not None:
                # Compare first: never replace a newer network edit with the backup.
                restored = _cas_managed(manager, committed, _managed(before))
            else:
                restored = manager.read_config()
                if _managed(restored) != _managed(before):
                    raise RuntimeError("Concurrent network edit prevents automatic rollback")
            if intended_quadlet is not None:
                current_bytes = _read_regular(POD_FILE.name, quadlet_fd, 65536)
                if current_bytes not in (intended_quadlet, quadlet_bytes):
                    raise RuntimeError("Concurrent quadlet edit prevents automatic rollback")
                _atomic_at(quadlet_fd, POD_FILE.name, quadlet_bytes, 0o644)
            if (
                op == "apply"
                and target_network is None
                and effective["podman_network"] != previous_name
            ):
                ok, error = remove_stale_network(effective["podman_network"], ztp_only=True)
                if not ok:
                    raise RuntimeError(error or "Could not remove candidate network")
            _restore_network_info(target_network)
            _restore_network_info(old_network)
            _regenerate_kea_configs(restored, config_dir=manager.config_path.parent)
            start_ztp_stack(dhcp_enabled=bool((restored.get("dhcp") or {}).get("enabled")))
            # Previous actual quadlet may differ from a saved draft. Verify its
            # addresses and network while retaining the user's desired config.
            check = deepcopy(restored)
            old_profile = get_ztp_profile(check)
            old_profile.update(enabled=previous_name != "host", podman_network=previous_name)
            old_profile["ipv4"]["address"] = actual_quadlet.get("ipv4") or ""
            old_profile["ipv6"]["address"] = actual_quadlet.get("ipv6") or ""
            if old_network:
                old_profile["parent_interface"] = old_network.get("parent") or ""
                old_profile["macvlan_mode"] = old_network.get("mode") or "bridge"
                for entry in old_network.get("subnets") or []:
                    block = old_profile["ipv6" if ":" in entry["subnet"] else "ipv4"]
                    block.update(subnet=entry["subnet"], gateway=entry.get("gateway") or "")
            check.setdefault("network", {})["ztp"] = old_profile
            check.setdefault("container", {})["host_network"] = previous_name == "host"
            verify_effective_stack(check)
        except Exception:
            logger.exception("Host network rollback failed")
            return {
                "state": "rollback_failed",
                "error_code": "rollback_failed",
                "detail": "Rollback incomplete; inspect host journal and retained recovery snapshot",
                "effective_applied": False,
            }
        finally:
            _OPERATION_DEADLINE.reset(recovery_token)
        return {
            "state": "failed",
            "error_code": "timeout" if timeout else "podman_failed",
            "detail": "Host operation failed; previous runtime restored and verified",
            "effective_applied": False,
        }
    finally:
        if quadlet_fd is not None:
            os.close(quadlet_fd)
        _OPERATION_DEADLINE.reset(token)
