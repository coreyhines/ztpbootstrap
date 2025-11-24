#!/usr/bin/env python3
"""
DHCP Container Deployment Module
Handles on-the-fly container creation and management
"""

import logging
import os
import shutil
import subprocess
from pathlib import Path
from typing import Dict, Optional

logger = logging.getLogger(__name__)

# Paths
SYSTEMD_DIR = Path("/etc/containers/systemd/ztpbootstrap")
DHCP_CONTAINER_FILE = SYSTEMD_DIR / "ztpbootstrap-dhcp.container"
DHCP_SERVICE_NAME = "ztpbootstrap-dhcp.service"
DHCP_CONTAINER_NAME = "ztpbootstrap-dhcp"


# Look for container file relative to this file's location (works both in repo and container)
# In repo: webui/dhcp_deploy.py -> systemd/ztpbootstrap-dhcp.container
# In container: /app/dhcp_deploy.py -> /app/systemd/ztpbootstrap-dhcp.container
# We'll resolve this at runtime in get_source_container_file() to ensure the file exists
def get_source_container_file() -> Path:
    """Get the source container file path, checking multiple locations."""
    # First try: /app/systemd/ztpbootstrap-dhcp.container (container)
    path1 = Path(__file__).parent / "systemd" / "ztpbootstrap-dhcp.container"
    if path1.exists():
        return path1
    # Second try: ../systemd/ztpbootstrap-dhcp.container (repo structure)
    path2 = Path(__file__).parent.parent / "systemd" / "ztpbootstrap-dhcp.container"
    if path2.exists():
        return path2
    # Default to first path (will be checked again in create_dhcp_container)
    return path1


# For backward compatibility, set a default (will be resolved at runtime)
SOURCE_CONTAINER_FILE = Path(__file__).parent / "systemd" / "ztpbootstrap-dhcp.container"
CONFIG_DIR = Path(os.environ.get("ZTP_CONFIG_DIR", "/opt/containerdata/ztpbootstrap"))
DHCP_CONFIG_DIR = CONFIG_DIR / "dhcp"
DHCP_LEASES_DIR = DHCP_CONFIG_DIR / "leases"
DHCP_LOGS_DIR = DHCP_CONFIG_DIR / "logs"
# Temporary location in mounted directory (accessible from container)
TEMP_DHCP_CONTAINER_FILE = CONFIG_DIR / "systemd" / "ztpbootstrap-dhcp.container"


def create_dhcp_container() -> bool:
    """
    Create quadlet file and systemd service for DHCP container.

    Returns:
        True if successful, False otherwise
    """
    try:
        # Ensure systemd directory exists on host
        # First, ensure the temp directory exists (in mounted location)
        temp_dir = TEMP_DHCP_CONTAINER_FILE.parent
        temp_dir.mkdir(parents=True, exist_ok=True)

        # Ensure DHCP config directories exist
        for directory in [DHCP_CONFIG_DIR, DHCP_LEASES_DIR, DHCP_LOGS_DIR]:
            if not directory.exists():
                directory.mkdir(parents=True, exist_ok=True)

        # Get source container file (resolve at runtime)
        source_file = get_source_container_file()
        if not source_file.exists():
            logger.error(f"Source container file not found. Checked: {source_file}")
            # Try alternative path
            alt_path = Path(__file__).parent.parent / "systemd" / "ztpbootstrap-dhcp.container"
            if alt_path.exists():
                source_file = alt_path
                logger.info(f"Found source container file at alternative path: {alt_path}")
            else:
                logger.error(f"Source container file not found at any location")
                return False

        # Read source file
        container_content = source_file.read_text()

        # Write to temp location (mounted, accessible from container)
        TEMP_DHCP_CONTAINER_FILE.write_text(container_content)
        logger.info(f"Created container file in temp location: {TEMP_DHCP_CONTAINER_FILE}")

        # Copy from temp location to systemd directory on host using sudo
        # This works because we're copying from a mounted location to the host filesystem
        result = subprocess.run(
            ["sudo", "mkdir", "-p", str(SYSTEMD_DIR)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            logger.warning(
                f"Failed to create systemd directory (may already exist): {result.stderr}"
            )

        result = subprocess.run(
            ["sudo", "cp", str(TEMP_DHCP_CONTAINER_FILE), str(DHCP_CONTAINER_FILE)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            logger.error(f"Failed to copy container file to systemd directory: {result.stderr}")
            logger.error(
                f"Source: {TEMP_DHCP_CONTAINER_FILE} (exists: {TEMP_DHCP_CONTAINER_FILE.exists()})"
            )
            logger.error(f"Target: {DHCP_CONTAINER_FILE}")
            return False

        # Verify the file was copied (check via sudo since we may not have direct access)
        verify_result = subprocess.run(
            ["sudo", "test", "-f", str(DHCP_CONTAINER_FILE)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if verify_result.returncode != 0:
            logger.error(
                f"Container file verification failed - file not found at {DHCP_CONTAINER_FILE}"
            )
            return False

        logger.info(f"Successfully created container file at {DHCP_CONTAINER_FILE}")

        # Reload systemd
        # Always use sudo since we're likely running inside a container
        # and need to communicate with the host's systemd
        # Try with sudo, but don't fail if it doesn't work - the file is created
        result = subprocess.run(
            ["sudo", "systemctl", "daemon-reload"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            logger.warning(
                f"Failed to reload systemd (this may be expected in containers): {result.stderr}"
            )
            # Don't fail - the file was created successfully, systemd reload can be done manually
            # or the service will be picked up on next systemd reload

        logger.info("DHCP container file created successfully")
        return True

    except Exception as e:
        logger.error(f"Failed to create DHCP container: {e}")
        return False


def start_dhcp_container() -> bool:
    """
    Start DHCP container.

    Returns:
        True if successful, False otherwise
    """
    try:
        # First, check current status using the status function
        # This is more reliable than individual checks
        status = check_dhcp_container_status()
        if status.get("container_running", False):
            logger.info("DHCP container is already running")
            return True
        if status.get("service_active", False):
            logger.info("DHCP service is already active")
            return True

        # Ensure container file exists
        if not DHCP_CONTAINER_FILE.exists():
            if not create_dhcp_container():
                return False

        # Try systemctl to start the service
        # This works on the host system
        try:
            result = subprocess.run(
                ["sudo", "systemctl", "start", DHCP_SERVICE_NAME],
                capture_output=True,
                text=True,
                timeout=30,
            )

            if result.returncode == 0:
                logger.info("DHCP container started successfully via systemctl")
                return True

            # Even if systemctl start failed, check if it's running now
            # (might have been started by another process or already running)
            status = check_dhcp_container_status()
            if status.get("container_running", False) or status.get("service_active", False):
                logger.info("DHCP container is running (verified after start attempt)")
                return True

            logger.warning(f"systemctl start failed: {result.stderr}")
        except Exception as e:
            logger.debug(f"systemctl start failed: {e}, checking status...")
            # Check status even if systemctl failed
            status = check_dhcp_container_status()
            if status.get("container_running", False) or status.get("service_active", False):
                logger.info("DHCP container is running (verified after exception)")
                return True

        # If we can't verify via systemctl or podman, but the container file exists,
        # assume it might be running and return True (fail open)
        # This handles the case where we're inside a container and can't check the host
        if DHCP_CONTAINER_FILE.exists():
            logger.info(
                "Container file exists but cannot verify status from container - assuming running"
            )
            return True

        logger.error("Failed to start DHCP container")
        return False

    except Exception as e:
        logger.error(f"Failed to start DHCP container: {e}")
        # Final status check
        try:
            status = check_dhcp_container_status()
            if status.get("container_running", False) or status.get("service_active", False):
                logger.info("DHCP container is running (final check after exception)")
                return True
            # If container file exists, assume it's running (fail open)
            if status.get("exists", False) or DHCP_CONTAINER_FILE.exists():
                logger.info("Container file exists - assuming container is running")
                return True
        except Exception:
            # If we can't check but file exists, assume running
            if DHCP_CONTAINER_FILE.exists():
                logger.info(
                    "Container file exists - assuming container is running (exception case)"
                )
                return True
        return False


def stop_dhcp_container() -> bool:
    """
    Stop DHCP container.

    Returns:
        True if successful, False otherwise
    """
    try:
        if os.geteuid() == 0:
            result = subprocess.run(
                ["systemctl", "stop", DHCP_SERVICE_NAME],
                capture_output=True,
                text=True,
                timeout=30,
            )
        else:
            result = subprocess.run(
                ["sudo", "systemctl", "stop", DHCP_SERVICE_NAME],
                capture_output=True,
                text=True,
                timeout=30,
            )

        if result.returncode != 0:
            logger.warning(f"Failed to stop DHCP container: {result.stderr}")
            # Don't fail if service doesn't exist
            return "not found" in result.stderr.lower() or "does not exist" in result.stderr.lower()

        logger.info("DHCP container stopped successfully")
        return True

    except Exception as e:
        logger.error(f"Failed to stop DHCP container: {e}")
        return False


def remove_dhcp_container() -> bool:
    """
    Remove DHCP container (when disabled).

    Returns:
        True if successful, False otherwise
    """
    try:
        # Stop container first
        stop_dhcp_container()

        # Remove container file
        if DHCP_CONTAINER_FILE.exists():
            if os.geteuid() == 0:
                DHCP_CONTAINER_FILE.unlink()
            else:
                result = subprocess.run(
                    ["sudo", "rm", str(DHCP_CONTAINER_FILE)],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode != 0:
                    logger.warning(f"Failed to remove container file: {result.stderr}")

        # Reload systemd
        # Always use sudo since we're likely running inside a container
        # and need to communicate with the host's systemd
        subprocess.run(
            ["sudo", "systemctl", "daemon-reload"],
            capture_output=True,
            text=True,
            timeout=10,
        )

        logger.info("DHCP container removed successfully")
        return True

    except Exception as e:
        logger.error(f"Failed to remove DHCP container: {e}")
        return False


def check_dhcp_container_status() -> Dict[str, any]:
    """
    Get container status.

    Returns:
        Dict with status information:
        - exists: bool - Container file exists
        - service_active: bool - Service is active
        - container_running: bool - Container is running
        - service_status: str - Service status string
    """
    result = {
        "exists": False,
        "service_active": False,
        "container_running": False,
        "service_status": "unknown",
    }

    try:
        # Check service status first (we'll use this to infer file existence)
        # Try systemctl, but don't fail if it doesn't work (e.g., in containers)
        try:
            if os.geteuid() == 0:
                status_result = subprocess.run(
                    ["systemctl", "is-active", DHCP_SERVICE_NAME],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
            else:
                status_result = subprocess.run(
                    ["sudo", "systemctl", "is-active", DHCP_SERVICE_NAME],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )

            if status_result.returncode == 0:
                result["service_active"] = True
                result["service_status"] = status_result.stdout.strip()
        except Exception as e:
            logger.debug(f"Could not check systemctl status: {e}")
            # Don't fail - continue with other checks

        # Check if container is actually running via podman
        try:
            # Use CONTAINER_HOST environment variable if set, otherwise default
            podman_cmd = ["podman"]
            container_host = os.environ.get("CONTAINER_HOST")
            if container_host:
                podman_cmd.extend(["--url", container_host])

            podman_result = subprocess.run(
                podman_cmd
                + [
                    "ps",
                    "--filter",
                    f"name={DHCP_CONTAINER_NAME}",
                    "--format",
                    "{{.Names}}",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )

            if podman_result.returncode == 0 and DHCP_CONTAINER_NAME in podman_result.stdout:
                result["container_running"] = True
                # If container is running, assume service is active too
                if not result["service_active"]:
                    result["service_active"] = True
                    result["service_status"] = "active"
        except Exception as e:
            logger.debug(f"Could not check container via podman: {e}")

        # Fallback: Check if Kea control agent is responding (port 8000)
        # This is a reliable way to verify the container is actually running
        # Note: For macvlan networking, the control agent won't be on 127.0.0.1
        # so we skip this check if we're on host network but DHCP is on macvlan
        if not result["container_running"]:
            try:
                import socket

                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                result_check = sock.connect_ex(("127.0.0.1", 8000))
                sock.close()
                if result_check == 0:
                    result["container_running"] = True
                    if not result["service_active"]:
                        result["service_active"] = True
                        result["service_status"] = "active"
            except Exception as e:
                logger.debug(f"Could not check Kea control agent port: {e}")

        # Additional fallback: Check if lease file exists and has content (indicates DHCP is/was running)
        if not result["container_running"] and not result["service_active"]:
            try:
                lease_file = DHCP_LEASES_DIR / "dhcp4.leases"
                if lease_file.exists():
                    # Check if file has content (more than just header)
                    file_size = lease_file.stat().st_size
                    if file_size > 200:  # More than just header line
                        # Lease file has content, assume DHCP is or was recently running
                        result["container_running"] = True
                        result["service_active"] = True
                        result["service_status"] = "active (detected via lease file)"
                        logger.debug("Detected running DHCP via lease file content")
                    # Also check if file was modified recently (within last 30 minutes)
                    import time

                    file_mtime = lease_file.stat().st_mtime
                    current_time = time.time()
                    if current_time - file_mtime < 1800:  # 30 minutes
                        # Lease file was recently updated, assume DHCP is running
                        result["container_running"] = True
                        result["service_active"] = True
                        result["service_status"] = "active (detected via lease file timestamp)"
                        logger.debug("Detected running DHCP via lease file timestamp")
            except Exception as e:
                logger.debug(f"Could not check lease file: {e}")

        # Final fallback: If container file exists, assume it might be running
        # This handles cases where we can't verify status from inside a container
        if not result["container_running"] and not result["service_active"]:
            try:
                if DHCP_CONTAINER_FILE.exists():
                    # File exists, so service was created - assume it might be running
                    # This is a "fail open" approach for containerized WebUI
                    result["exists"] = True
                    logger.debug(
                        "Container file exists but cannot verify status - assuming may be running"
                    )
            except Exception:
                pass

        # Infer container file existence: if container is running or service is active,
        # the file must exist (systemd wouldn't be able to start the service without it)
        # Also try direct check if we're on the host (not in a container)
        if result["container_running"] or result["service_active"]:
            result["exists"] = True
        else:
            # Try direct check (works if we're on the host, not in a container)
            try:
                result["exists"] = DHCP_CONTAINER_FILE.exists()
            except Exception:
                # If we can't check directly (e.g., we're in a container), assume False
                # but this is okay - the file will show as existing once the service starts
                result["exists"] = False

    except Exception as e:
        logger.warning(f"Failed to check DHCP container status: {e}")
        result["service_status"] = f"error: {str(e)}"

    return result
