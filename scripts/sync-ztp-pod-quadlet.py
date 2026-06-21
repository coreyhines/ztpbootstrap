#!/usr/bin/env python3
"""CLI wrapper: sync ztpbootstrap.pod from config.yaml (used by update-config.sh)."""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

WEBUI_DIR = Path(__file__).resolve().parent.parent / "webui"
sys.path.insert(0, str(WEBUI_DIR))

from network_config import get_ztp_profile  # noqa: E402
from network_deploy import sync_pod_quadlet  # noqa: E402


def main() -> int:
    config_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/opt/containerdata/ztpbootstrap/config.yaml")
    if not config_path.exists():
        print(f"Config not found: {config_path}", file=sys.stderr)
        return 1
    config = yaml.safe_load(config_path.read_text()) or {}
    ztp = get_ztp_profile(config)
    ok, err = sync_pod_quadlet(ztp)
    if not ok:
        print(err or "sync failed", file=sys.stderr)
        return 1
    print("Synced ztpbootstrap.pod from config")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
