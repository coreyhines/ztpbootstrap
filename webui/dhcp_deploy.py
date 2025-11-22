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
SOURCE_CONTAINER_FILE = Path(__file__).parent.parent / "systemd" / "ztpbootstrap-dhcp.container"
CONFIG_DIR = Path(os.environ.get("ZTP_CONFIG_DIR", "/opt/containerdata/ztpbootstrap"))
DHCP_CONFIG_DIR = CONFIG_DIR / "dhcp"
DHCP_LEASES_DIR = DHCP_CONFIG_DIR / "leases"
DHCP_LOGS_DIR = DHCP_CONFIG_DIR / "logs"


def create_dhcp_container() -> bool:
    """
    Create quadlet file and systemd service for DHCP container.

    Returns:
        True if successful, False otherwise
    """
    try:
        # Ensure systemd directory exists
        if not SYSTEMD_DIR.exists():
            if os.geteuid() == 0:
                SYSTEMD_DIR.mkdir(parents=True, exist_ok=True)
            else:
                # Try with sudo
                result = subprocess.run(
                    ["sudo", "mkdir", "-p", str(SYSTEMD_DIR)],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode != 0:
                    logger.error(f"Failed to create systemd directory: {result.stderr}")
                    return False

        # Ensure DHCP config directories exist
        for directory in [DHCP_CONFIG_DIR, DHCP_LEASES_DIR, DHCP_LOGS_DIR]:
            if not directory.exists():
                directory.mkdir(parents=True, exist_ok=True)

        # Copy container file from source
        if not SOURCE_CONTAINER_FILE.exists():
            logger.error(f"Source container file not found: {SOURCE_CONTAINER_FILE}")
            return False

        # Read source file
        container_content = SOURCE_CONTAINER_FILE.read_text()

        # Write to destination
        if os.geteuid() == 0:
            DHCP_CONTAINER_FILE.write_text(container_content)
        else:
            # Use sudo to write
            temp_file = Path("/tmp/ztpbootstrap-dhcp.container")
            temp_file.write_text(container_content)
            result = subprocess.run(
                ["sudo", "cp", str(temp_file), str(DHCP_CONTAINER_FILE)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            temp_file.unlink()
            if result.returncode != 0:
                logger.error(f"Failed to copy container file: {result.stderr}")
                return False

        # Reload systemd
        if os.geteuid() == 0:
            subprocess.run(["systemctl", "daemon-reload"], check=True, timeout=10)
        else:
            result = subprocess.run(
                ["sudo", "systemctl", "daemon-reload"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode != 0:
                logger.error(f"Failed to reload systemd: {result.stderr}")
                return False

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
        # Ensure container file exists
        if not DHCP_CONTAINER_FILE.exists():
            if not create_dhcp_container():
                return False

        # Start service
        if os.geteuid() == 0:
            result = subprocess.run(
                ["systemctl", "start", DHCP_SERVICE_NAME],
                capture_output=True,
                text=True,
                timeout=30,
            )
        else:
            result = subprocess.run(
                ["sudo", "systemctl", "start", DHCP_SERVICE_NAME],
                capture_output=True,
                text=True,
                timeout=30,
            )

        if result.returncode != 0:
            logger.error(f"Failed to start DHCP container: {result.stderr}")
            return False

        logger.info("DHCP container started successfully")
        return True

    except Exception as e:
        logger.error(f"Failed to start DHCP container: {e}")
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
        if os.geteuid() == 0:
            subprocess.run(["systemctl", "daemon-reload"], check=False, timeout=10)
        else:
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
        # Check if container file exists
        result["exists"] = DHCP_CONTAINER_FILE.exists()

        # Check service status
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

        # Check if container is actually running via podman
        podman_result = subprocess.run(
            ["podman", "ps", "--filter", f"name={DHCP_CONTAINER_NAME}", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            timeout=5,
        )

        if podman_result.returncode == 0 and DHCP_CONTAINER_NAME in podman_result.stdout:
            result["container_running"] = True

    except Exception as e:
        logger.warning(f"Failed to check DHCP container status: {e}")
        result["service_status"] = f"error: {str(e)}"

    return result
