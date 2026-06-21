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
import subprocess
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

from network_config import (
    get_ztp_profile,
    merge_ztp_update,
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
    return subprocess.run(base + args, capture_output=True, text=True, timeout=timeout)


def _run_podman(args: List[str], timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(get_podman_cmd() + args, capture_output=True, text=True, timeout=timeout)


def create_network_backup(tag: Optional[str] = None) -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = tag or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = BACKUP_DIR / stamp
    dest.mkdir(parents=True, exist_ok=True)
    if POD_FILE.exists():
        shutil.copy2(POD_FILE, dest / "ztpbootstrap.pod")
    config_path = Path("/opt/containerdata/ztpbootstrap/config.yaml")
    if config_path.exists():
        shutil.copy2(config_path, dest / "config.yaml")
    return dest


def restore_network_backup(backup_path: Path) -> bool:
    pod_backup = backup_path / "ztpbootstrap.pod"
    if pod_backup.exists() and POD_FILE.parent.exists():
        shutil.copy2(pod_backup, POD_FILE)
        return True
    return False


def ensure_podman_network(profile: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
    effective = resolve_effective_network({"network": {"ztp": profile}, "container": {"host_network": False}})
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
        sig_current = (
            existing.get("parent"),
            [(s.get("subnet"), s.get("gateway")) for s in existing.get("subnets") or []],
            existing.get("mode") or "bridge",
        )
        sig_desired = (
            parent,
            [
                (ipv4_subnet, ipv4_gateway),
            ]
            + ([(ipv6_subnet, ipv6_gateway)] if ipv6_subnet else []),
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
        "--gateway",
        ipv4_gateway,
        "-o",
        f"parent={parent}",
        "-o",
        f"mode={mode}",
    ]
    if ipv6_subnet:
        if ipv6_gateway:
            cmd.extend(["--subnet", ipv6_subnet, "--gateway", ipv6_gateway])
        else:
            cmd.extend(["--subnet", ipv6_subnet])
    cmd.append(name)

    result = _run_podman(cmd, timeout=90)
    if result.returncode != 0:
        return False, result.stderr.strip() or result.stdout.strip() or "podman network create failed"
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
            return False, f"Network {name} is shared with foreign containers: {', '.join(foreign)}"
    result = _run_podman(["network", "rm", name], timeout=30)
    if result.returncode != 0 and "no such network" not in (result.stderr or "").lower():
        return False, result.stderr.strip() or "podman network rm failed"
    return True, None


def render_pod_quadlet_content(profile: Dict[str, Any]) -> str:
    effective = resolve_effective_network({"network": {"ztp": profile}, "container": {"host_network": False}})
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
            _run_systemctl(["stop", service], timeout=90)
        except subprocess.TimeoutExpired:
            logger.warning(f"Timeout stopping {service}")


def start_ztp_stack(dhcp_enabled: bool = False) -> None:
    _run_systemctl(["daemon-reload"], timeout=30)
    for service in SERVICES_START_ORDER:
        if service.startswith("ztpbootstrap-dhcp") and not dhcp_enabled:
            continue
        try:
            _run_systemctl(["start", service], timeout=120)
        except subprocess.TimeoutExpired:
            logger.warning(f"Timeout starting {service}")


def restart_ztp_stack(config: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
    dhcp_enabled = bool((config.get("dhcp") or {}).get("enabled"))
    try:
        stop_ztp_stack()
        start_ztp_stack(dhcp_enabled=dhcp_enabled)
        return True, None
    except Exception as exc:
        return False, str(exc)


def _regenerate_kea_configs(config: Dict[str, Any]) -> None:
    if not (config.get("dhcp") or {}).get("enabled"):
        return
    try:
        from dhcp_config import generate_kea_config

        kea_config = generate_kea_config(config)
        dhcp_config_dir = Path("/opt/containerdata/ztpbootstrap/dhcp")
        dhcp_config_dir.mkdir(parents=True, exist_ok=True)
        if "Dhcp4" in kea_config:
            (dhcp_config_dir / "kea-dhcp4.conf").write_text(
                json.dumps({"Dhcp4": kea_config["Dhcp4"]}, indent=2)
            )
        if "Dhcp6" in kea_config:
            (dhcp_config_dir / "kea-dhcp6.conf").write_text(
                json.dumps({"Dhcp6": kea_config["Dhcp6"]}, indent=2)
            )
        if "Control-agent" in kea_config:
            (dhcp_config_dir / "kea-ctrl-agent.conf").write_text(
                json.dumps({"Control-agent": kea_config["Control-agent"]}, indent=2)
            )
    except Exception as exc:
        logger.warning(f"Kea config regeneration failed: {exc}")


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
    config: Dict[str, Any], restart: bool = True, current_config: Optional[Dict[str, Any]] = None
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
                stop_ztp_stack()
                stopped = True

            for old_network in plan.get("remove_networks") or []:
                ok, err = remove_stale_network(old_network, ztp_only=True)
                if not ok:
                    raise RuntimeError(err or f"Failed to remove {old_network}")

            if plan.get("create_network") or plan.get("replace_network"):
                ok, err = ensure_podman_network(ztp)
                if not ok:
                    raise RuntimeError(err or "Failed to create podman network")

            if plan.get("update_quadlet") or plan.get("create_network") or plan.get("replace_network"):
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
        if stopped and backup_path is not None:
            restore_network_backup(backup_path)
            try:
                restart_ztp_stack(config)
            except Exception:
                pass
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
        if quadlet.get("ipv4") and effective.get("ipv4_address") and quadlet.get("ipv4") != effective.get("ipv4_address"):
            drift_items.append("quadlet IP differs from config")
        if podman_info is None and desired_network:
            drift_items.append(f"podman network {desired_network} does not exist")
        elif podman_info and effective.get("parent_interface"):
            if podman_info.get("parent") != effective.get("parent_interface"):
                drift_items.append("podman network parent differs from config")

    dhcp_subnet = ((config.get("dhcp") or {}).get("ipv4") or {}).get("subnet") or ""
    ztp_subnet = (ztp.get("ipv4") or {}).get("subnet") or ""
    subnet_mismatch = bool(
        dhcp_subnet and ztp_subnet and dhcp_subnet != ztp_subnet and (config.get("dhcp") or {}).get("enabled")
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
