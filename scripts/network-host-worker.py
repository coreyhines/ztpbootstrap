#!/usr/bin/python3 -I
"""Entry point for the independent, root-owned host network worker."""

import os
import signal
import sys
import threading

# -I ignores PYTHONPATH, PYTHONHOME, user site packages and the script directory.
# Only explicit, root-owned installed modules belong on the privileged import path.
sys.path.insert(0, "/usr/local/lib/ztpbootstrap")
for key in (
    "CONTAINER_HOST",
    "CONTAINER_CONNECTION",
    "CONTAINER_SOCK",
    "PYTHONPATH",
    "PYTHONHOME",
):
    os.environ.pop(key, None)
os.environ["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin"

from network_jobs import run_worker  # noqa: E402


def main() -> None:
    """Stop accepting work on SIGTERM while the current transaction settles."""
    stopping = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_args: stopping.set())
    signal.signal(signal.SIGINT, lambda *_args: stopping.set())
    run_worker(stop_event=stopping)


if __name__ == "__main__":
    main()
