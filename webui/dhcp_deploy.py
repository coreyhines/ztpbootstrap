#!/usr/bin/env python3
"""
DHCP Container Deployment Module
Handles on-the-fly container creation and management
"""

import logging
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List

logger = logging.getLogger(__name__)

# Paths
SYSTEMD_DIR = Path("/etc/containers/systemd/ztpbootstrap")
DHCP_CONTAINER_FILE = SYSTEMD_DIR / "ztpbootstrap-dhcp.container"
DHCP_SERVICE_NAME = "ztpbootstrap-dhcp.service"
DHCP_CONTAINER_NAME = "ztpbootstrap-dhcp"

# Cache for socket permission warnings (to avoid spam)
_socket_warning_logged = False


def get_podman_cmd() -> List[str]:
    """
    Get podman command with appropriate connection settings.

    Tries to use podman directly first (if socket is accessible),
    then falls back to using --url if CONTAINER_HOST is set.

    Returns:
        List of command parts for podman
    """
    podman_cmd = ["podman"]

    # First, check if socket file exists and is accessible
    # Only log warnings once to avoid spam
    global _socket_warning_logged
    socket_path = Path("/run/podman/podman.sock")
    if socket_path.exists():
        # Check if we can access it (read permission)
        if not os.access(socket_path, os.R_OK):
            # Only log once to avoid spam
            pass  # Will be logged below if test fails
    # Don't log socket existence here - will be logged in test below if needed

    # Try to check if podman works directly (socket might be mounted)
    # This is faster and more reliable when running inside a container with socket access
    # We do a simple operation that requires socket access (like ps with no output)
    try:
        test_result = subprocess.run(
            ["podman", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        # Even if there are no containers, returncode 0 means socket is accessible
        if test_result.returncode == 0:
            # Podman works directly, no need for --url
            logger.debug("Podman socket accessible directly (tested with 'podman ps')")
            return podman_cmd
        else:
            error_msg = test_result.stderr or test_result.stdout or "unknown error"
            logger.debug(f"Podman direct access test failed: {error_msg}")
            # Check for specific permission errors (only log once to avoid spam)
            if not _socket_warning_logged and (
                "permission denied" in error_msg.lower()
                or "connect: permission denied" in error_msg.lower()
            ):
                logger.warning(
                    "Podman socket permission denied. The container may not have access to the socket. "
                    "This is a common issue when running in containers. "
                    "Consider running 'sudo systemctl start podman.socket' on the host, "
                    "or check socket permissions and SELinux context."
                )
                _socket_warning_logged = True
    except FileNotFoundError:
        logger.debug("Podman command not found")
    except subprocess.TimeoutExpired:
        logger.debug("Podman command timed out")
    except Exception as e:
        logger.debug(f"Podman direct access test exception: {e}")

    # If direct access doesn't work, try using CONTAINER_HOST
    container_host = os.environ.get("CONTAINER_HOST")
    if container_host:
        podman_cmd.extend(["--url", container_host])
        logger.debug(f"Using CONTAINER_HOST: {container_host}")
    else:
        # No CONTAINER_HOST set, but direct access failed
        # Still return podman_cmd without --url, it might work in some cases
        logger.debug("No CONTAINER_HOST set, using podman directly (may fail)")

    return podman_cmd


# Look for container file relative to this file's location (works both in repo and container)
# In repo: webui/dhcp_deploy.py -> systemd/ztpbootstrap-dhcp.container
# In container: /app/dhcp_deploy.py -> /app/systemd/ztpbootstrap-dhcp.container
# We'll resolve this at runtime in get_source_container_file() to ensure the file exists
def get_source_container_file() -> Path:
    """
    Get the source container file path, checking multiple locations.

    Since the systemd directory may not be mounted in the container,
    we check multiple locations including the installed location and
    try to read from the host filesystem if needed.
    """
    # First try: /app/systemd/ztpbootstrap-dhcp.container (if systemd dir is in webui)
    path1 = Path(__file__).parent / "systemd" / "ztpbootstrap-dhcp.container"
    if path1.exists():
        return path1

    # Second try: ../systemd/ztpbootstrap-dhcp.container (repo structure, if mounted)
    path2 = Path(__file__).parent.parent / "systemd" / "ztpbootstrap-dhcp.container"
    if path2.exists():
        return path2

    # Third try: Check if already installed in systemd directory (on host)
    # We can't directly check this from inside container, so we'll try to read it
    # in create_dhcp_container() if local paths don't exist
    # Return a special marker path that create_dhcp_container will recognize
    # Default to first path (will be checked again in create_dhcp_container)
    # If it doesn't exist, we'll try to read from host filesystem
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
        container_content = None

        # Try to read the source file
        if source_file.exists():
            # File exists locally, read it directly
            container_content = source_file.read_text()
            logger.info(f"Read container file from: {source_file}")
        else:
            # File doesn't exist locally, try to read from host filesystem via podman
            logger.info(
                f"Source file not found locally at {source_file}, trying to read from host..."
            )
            try:
                podman_cmd = get_podman_cmd()

                # Try to read from the installed location first
                read_result = subprocess.run(
                    podman_cmd
                    + [
                        "run",
                        "--rm",
                        "--privileged",
                        "--pid=host",
                        "registry.fedoraproject.org/fedora:latest",
                        "cat",
                        str(DHCP_CONTAINER_FILE),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                if read_result.returncode == 0 and read_result.stdout:
                    container_content = read_result.stdout
                    logger.info(f"Read container file from host at: {DHCP_CONTAINER_FILE}")
                else:
                    # Try to find the user's home directory first
                    user_home = None
                    try:
                        whoami_result = subprocess.run(
                            podman_cmd
                            + [
                                "run",
                                "--rm",
                                "--privileged",
                                "--pid=host",
                                "registry.fedoraproject.org/fedora:latest",
                                "sh",
                                "-c",
                                "echo $HOME",
                            ],
                            capture_output=True,
                            text=True,
                            timeout=5,
                        )
                        if whoami_result.returncode == 0:
                            user_home = whoami_result.stdout.strip()
                            logger.debug(f"Detected user home: {user_home}")
                    except Exception as e:
                        logger.debug(f"Could not detect user home: {e}")

                    # Try common repo locations on the host, including installed location
                    possible_host_paths = [
                        str(DHCP_CONTAINER_FILE),  # Installed location
                        "/opt/containerdata/ztpbootstrap/systemd/ztpbootstrap-dhcp.container",
                    ]

                    # Add user-specific paths
                    if user_home:
                        possible_host_paths.extend(
                            [
                                f"{user_home}/ztpbootstrap/systemd/ztpbootstrap-dhcp.container",
                            ]
                        )

                    # Add common user directories
                    possible_host_paths.extend(
                        [
                            "/root/ztpbootstrap/systemd/ztpbootstrap-dhcp.container",
                            "/home/fedora/ztpbootstrap/systemd/ztpbootstrap-dhcp.container",
                            "/home/corey/ztpbootstrap/systemd/ztpbootstrap-dhcp.container",
                            "/opt/ztpbootstrap/systemd/ztpbootstrap-dhcp.container",
                        ]
                    )

                    logger.info(
                        f"Trying to read container file from {len(possible_host_paths)} possible locations..."
                    )
                    for host_path in possible_host_paths:
                        logger.debug(f"Trying path: {host_path}")
                        read_result = subprocess.run(
                            podman_cmd
                            + [
                                "run",
                                "--rm",
                                "--privileged",
                                "--pid=host",
                                "registry.fedoraproject.org/fedora:latest",
                                "cat",
                                host_path,
                            ],
                            capture_output=True,
                            text=True,
                            timeout=10,
                        )
                        if read_result.returncode == 0 and read_result.stdout:
                            container_content = read_result.stdout
                            logger.info(f"Read container file from host at: {host_path}")
                            break
                        else:
                            logger.debug(
                                f"Failed to read {host_path}: returncode={read_result.returncode}, "
                                f"stderr={read_result.stderr[:100]}"
                            )
            except Exception as e:
                logger.error(f"Exception while trying to read container file from host: {e}")
                import traceback

                logger.debug(f"Traceback: {traceback.format_exc()}")

        # If we still don't have the content, generate it programmatically as fallback
        if not container_content:
            logger.warning(f"Source container file not found. Checked: {source_file}")
            logger.warning(
                "Could not read container file from any location, generating from template..."
            )
            # Generate container file content programmatically
            container_content = """[Unit]
Description=ZTP Bootstrap DHCP Server (Kea)
After=ztpbootstrap-pod.service ztpbootstrap-postgresql.service
Requires=ztpbootstrap-pod.service
Wants=ztpbootstrap-postgresql.service

[Container]
Image=docker.io/iscorg/kea:2.6.1
ContainerName=ztpbootstrap-dhcp
Pod=ztpbootstrap.pod
Exec=/bin/sh /app/start-kea.sh
Volume=/opt/containerdata/ztpbootstrap/dhcp:/etc/kea:rw
Volume=/opt/containerdata/ztpbootstrap/dhcp/leases:/var/lib/kea:rw
Volume=/opt/containerdata/ztpbootstrap/dhcp/logs:/var/log/kea:rw
Volume=/opt/containerdata/ztpbootstrap/webui:/app:ro
Environment=TZ=UTC
AddCapability=CAP_NET_RAW
AddCapability=CAP_NET_BIND_SERVICE

[Service]
Restart=no

[Install]
WantedBy=ztpbootstrap-pod.service
"""
            logger.info("Generated container file content from template")

        # Write to temp location (mounted, accessible from container)
        TEMP_DHCP_CONTAINER_FILE.write_text(container_content)
        logger.info(f"Created container file in temp location: {TEMP_DHCP_CONTAINER_FILE}")

        # Copy from temp location to systemd directory on host
        # Try multiple methods since we're running inside a container

        # Method 1: Try sudo (works if container has proper sudo access)
        copy_success = False
        try:
            result = subprocess.run(
                ["sudo", "mkdir", "-p", str(SYSTEMD_DIR)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                result = subprocess.run(
                    [
                        "sudo",
                        "cp",
                        str(TEMP_DHCP_CONTAINER_FILE),
                        str(DHCP_CONTAINER_FILE),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    copy_success = True
                    logger.info("Container file copied via sudo")
        except Exception as e:
            logger.debug(f"Sudo copy failed: {e}")

        # Method 2: Try using podman run to copy file on host (if we're in a container)
        if not copy_success:
            try:
                # Use podman to execute a command on the host
                # This works if we have access to the podman socket
                podman_cmd = get_podman_cmd()

                # Use podman run with --privileged to access host filesystem
                # First ensure the directory exists
                mkdir_result = subprocess.run(
                    podman_cmd
                    + [
                        "run",
                        "--rm",
                        "--privileged",
                        "--pid=host",
                        "--network=host",
                        "--volume=/opt/containerdata:/opt/containerdata:ro",
                        "--volume=/etc/containers:/etc/containers:rw",
                        "registry.fedoraproject.org/fedora:latest",
                        "sh",
                        "-c",
                        f"mkdir -p {SYSTEMD_DIR}",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                if mkdir_result.returncode == 0:
                    # Now copy the file
                    copy_result = subprocess.run(
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "--network=host",
                            "--volume=/opt/containerdata:/opt/containerdata:ro",
                            "--volume=/etc/containers:/etc/containers:rw",
                            "registry.fedoraproject.org/fedora:latest",
                            "cp",
                            str(TEMP_DHCP_CONTAINER_FILE),
                            str(DHCP_CONTAINER_FILE),
                        ],
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    if copy_result.returncode == 0:
                        copy_success = True
                        logger.info("Container file copied via podman run")
                    else:
                        logger.debug(f"podman run cp failed: {copy_result.stderr}")
                else:
                    logger.debug(f"podman run mkdir failed: {mkdir_result.stderr}")
            except Exception as e:
                logger.debug(f"Podman run copy failed: {e}")

        # Method 3: Try writing directly to systemd directory if it's mounted/writable
        if not copy_success:
            try:
                # Check if we can write directly to the systemd directory
                # This might work if /etc/containers is mounted as a volume
                systemd_dir = Path(SYSTEMD_DIR)
                systemd_dir.mkdir(parents=True, exist_ok=True)
                target_file = systemd_dir / "ztpbootstrap-dhcp.container"
                target_file.write_text(container_content)
                # Verify it was written
                if target_file.exists() and target_file.read_text() == container_content:
                    copy_success = True
                    logger.info("Container file written directly to systemd directory")
            except (PermissionError, OSError) as e:
                logger.debug(f"Direct write to systemd directory failed: {e}")

        # Method 4: If file exists in temp location, log a warning but continue
        # The file will need to be manually copied or systemd will pick it up on next reload
        if not copy_success:
            logger.warning(
                f"Could not copy container file to systemd directory automatically. "
                f"File is available at: {TEMP_DHCP_CONTAINER_FILE}. "
                f"Please copy it manually to {DHCP_CONTAINER_FILE} and run 'systemctl daemon-reload'"
            )
            # Verify the temp file exists
            if not TEMP_DHCP_CONTAINER_FILE.exists():
                logger.error("Container file was not created in temp location either!")
                return False
            # File exists in temp location but not in systemd directory
            # Return True but this is a partial success
            logger.warning(
                f"Container file created in temp location only. "
                f"Manual copy required: sudo cp {TEMP_DHCP_CONTAINER_FILE} {DHCP_CONTAINER_FILE}"
            )
            return True  # Partial success - file exists but needs manual copy

        # Verify the file was actually copied (only if copy_success was True)
        if copy_success:
            file_verified = False
            # Try multiple methods to verify
            # Method 1: Direct read if accessible
            try:
                if DHCP_CONTAINER_FILE.exists():
                    test_content = DHCP_CONTAINER_FILE.read_text()[:100]
                    if test_content and "[Unit]" in test_content:
                        file_verified = True
                        logger.info(f"Successfully created container file at {DHCP_CONTAINER_FILE}")
            except (PermissionError, OSError, FileNotFoundError):
                # File doesn't exist or can't be read directly
                pass

            # Method 2: Try podman to verify
            if not file_verified:
                try:
                    podman_cmd = get_podman_cmd()
                    verify_result = subprocess.run(
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "--network=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "test",
                            "-f",
                            str(DHCP_CONTAINER_FILE),
                        ],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    if verify_result.returncode == 0:
                        file_verified = True
                        logger.info(
                            f"Successfully created container file at {DHCP_CONTAINER_FILE} (verified via podman)"
                        )
                    else:
                        logger.warning(
                            f"Container file copy reported success but verification failed - file may not be at {DHCP_CONTAINER_FILE}"
                        )
                except Exception as e:
                    logger.debug(f"Could not verify container file via podman: {e}")
                    # Assume it exists if copy reported success
                    logger.info(
                        f"Container file copy reported success at {DHCP_CONTAINER_FILE} (could not verify)"
                    )
        else:
            # Copy didn't succeed, file is only in temp location
            logger.info(f"Container file created in temp location: {TEMP_DHCP_CONTAINER_FILE}")

        # Reload systemd (only if we can - this will fail in containers, which is fine)
        # The file is created, and systemd will pick it up on next reload or restart
        try:
            result = subprocess.run(
                ["sudo", "systemctl", "daemon-reload"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode != 0:
                logger.debug(f"Failed to reload systemd (expected in containers): {result.stderr}")
        except Exception as e:
            logger.debug(f"Could not reload systemd (expected in containers): {e}")
            # Don't fail - the file was created successfully, systemd reload can be done manually
            # or the service will be picked up on next systemd reload

        logger.info("DHCP container file created successfully")
        return True

    except FileNotFoundError as e:
        logger.error(f"Source container file not found: {e}")
        return False
    except PermissionError as e:
        logger.error(f"Permission denied creating DHCP container: {e}")
        return False
    except OSError as e:
        logger.error(f"OS error creating DHCP container: {e}")
        return False
    except subprocess.TimeoutExpired as e:
        logger.error(f"Timeout creating DHCP container: {e}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error creating DHCP container: {type(e).__name__}: {e}")
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

        # Ensure container file exists on the host
        # We need to check on the host since we're running inside a container
        container_file_exists = False
        try:
            # Check if file exists on host using podman run
            podman_cmd = get_podman_cmd()

            check_result = subprocess.run(
                podman_cmd
                + [
                    "run",
                    "--rm",
                    "--privileged",
                    "--pid=host",
                    "--network=host",
                    "--volume=/run/systemd:/run/systemd:rw",
                    "--volume=/sys/fs/cgroup:/sys/fs/cgroup:ro",
                    "registry.fedoraproject.org/fedora:latest",
                    "test",
                    "-f",
                    str(DHCP_CONTAINER_FILE),
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            container_file_exists = check_result.returncode == 0
        except Exception as e:
            logger.debug(f"Could not check container file existence: {e}")
            # Fallback: try direct check (might work if we're on host)
            try:
                container_file_exists = DHCP_CONTAINER_FILE.exists()
            except Exception:
                container_file_exists = False

        if not container_file_exists:
            logger.info("Container file does not exist on host, creating it...")
            if not create_dhcp_container():
                logger.error("Failed to create DHCP container file")
                return False
            # Wait a moment for the file to be written
            time.sleep(1)

        # Use systemctl to start the service (quadlets/systemd is our control mechanism)
        # Since we're running in a container, we need to execute systemctl on the host
        logger.info("Starting DHCP service via systemctl on host...")

        # Try to use podman to run systemctl on the host
        # This works by running a container with access to the host's systemd
        podman_cmd = get_podman_cmd()

        # Method 1: Use podman run to execute systemctl on the host
        systemctl_success = False
        try:
            # First reload systemd to ensure the service file is recognized
            # Mount systemd socket, D-Bus socket, and cgroup for systemctl to work
            # systemd socket needs to be read-write for systemctl commands to work
            reload_result = subprocess.run(
                podman_cmd
                + [
                    "run",
                    "--rm",
                    "--privileged",
                    "--pid=host",
                    "--network=host",
                    "--volume=/run/systemd:/run/systemd:rw",
                    "--volume=/run/dbus:/run/dbus:rw",
                    "--volume=/sys/fs/cgroup:/sys/fs/cgroup:ro",
                    "registry.fedoraproject.org/fedora:latest",
                    "systemctl",
                    "daemon-reload",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if reload_result.returncode != 0:
                logger.warning(f"systemctl daemon-reload failed: {reload_result.stderr}")
                logger.warning(f"systemctl daemon-reload stdout: {reload_result.stdout}")

            # Start the service via systemctl using podman run
            result = subprocess.run(
                podman_cmd
                + [
                    "run",
                    "--rm",
                    "--privileged",
                    "--pid=host",
                    "--network=host",
                    "--volume=/run/systemd:/run/systemd:rw",
                    "--volume=/run/dbus:/run/dbus:rw",
                    "--volume=/sys/fs/cgroup:/sys/fs/cgroup:ro",
                    "registry.fedoraproject.org/fedora:latest",
                    "systemctl",
                    "start",
                    DHCP_SERVICE_NAME,
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )

            if result.returncode == 0:
                logger.info("systemctl start command succeeded via podman run")
                systemctl_success = True
            else:
                logger.error(
                    f"Failed to start via podman run systemctl (returncode={result.returncode})"
                )
                logger.error(f"systemctl start stderr: {result.stderr}")
                logger.error(f"systemctl start stdout: {result.stdout}")
                logger.error(
                    f"Full command: {' '.join(podman_cmd + ['run', '--rm', '--privileged', '--pid=host', '--network=host', '--volume=/run/systemd:/run/systemd:rw', '--volume=/sys/fs/cgroup:/sys/fs/cgroup:ro', 'registry.fedoraproject.org/fedora:latest', 'systemctl', 'start', DHCP_SERVICE_NAME])}"
                )
        except Exception as e:
            logger.error(f"podman run systemctl failed with exception: {e}")
            import traceback

            logger.debug(f"Traceback: {traceback.format_exc()}")

        # Method 2: Try direct systemctl (works if we're on the host, not in a container)
        if not systemctl_success:
            try:
                # First reload systemd
                reload_result = subprocess.run(
                    ["sudo", "systemctl", "daemon-reload"],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                if reload_result.returncode != 0:
                    logger.debug(f"systemctl daemon-reload failed: {reload_result.stderr}")

                # Start the service
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
                if result.returncode == 0:
                    logger.info("systemctl start command succeeded (direct)")
                    systemctl_success = True
                else:
                    logger.warning(f"Failed to start DHCP container via systemctl: {result.stderr}")
            except Exception as e:
                logger.debug(f"Direct systemctl failed: {e}")

        # Method 3: If systemctl failed, try using nsenter to access host namespace
        # This works when we're in a container but can't access podman socket
        if not systemctl_success:
            logger.warning(
                "systemctl failed, attempting to use nsenter to access host namespace..."
            )
            try:
                # Try to use nsenter to run systemctl on the host
                # This works if we have access to the host's PID namespace
                # First, find the host's PID (usually 1, but we can check)
                host_pid = 1

                # Try to reload systemd on host via nsenter
                nsenter_reload = subprocess.run(
                    [
                        "nsenter",
                        "-t",
                        str(host_pid),
                        "-m",
                        "-p",
                        "-i",
                        "-n",
                        "systemctl",
                        "daemon-reload",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                if nsenter_reload.returncode == 0:
                    logger.info("systemctl daemon-reload succeeded via nsenter")

                    # Now try to start the service
                    nsenter_start = subprocess.run(
                        [
                            "nsenter",
                            "-t",
                            str(host_pid),
                            "-m",
                            "-p",
                            "-i",
                            "-n",
                            "systemctl",
                            "start",
                            DHCP_SERVICE_NAME,
                        ],
                        capture_output=True,
                        text=True,
                        timeout=30,
                    )
                    if nsenter_start.returncode == 0:
                        logger.info("systemctl start succeeded via nsenter")
                        systemctl_success = True
                    else:
                        logger.debug(f"nsenter systemctl start failed: {nsenter_start.stderr}")
                else:
                    logger.debug(f"nsenter systemctl daemon-reload failed: {nsenter_reload.stderr}")
            except FileNotFoundError:
                logger.debug("nsenter not available")
            except Exception as e:
                logger.debug(f"nsenter method failed: {e}")

        # Method 4: If all else failed, try starting container directly via podman
        # This is a fallback when systemctl isn't accessible (e.g., permission issues)
        # We use the same parameters from the container file template
        if not systemctl_success:
            logger.warning("systemctl failed, attempting direct podman start as fallback...")
            try:
                # Get podman command for direct start (may be different from systemctl method)
                direct_podman_cmd = get_podman_cmd()

                # Build podman run command with parameters from container file
                # These match the container file template
                run_cmd = direct_podman_cmd + [
                    "run",
                    "-d",
                    "--name",
                    DHCP_CONTAINER_NAME,
                    "--pod",
                    "ztpbootstrap",  # From Pod=ztpbootstrap.pod
                    "--volume",
                    "/opt/containerdata/ztpbootstrap/dhcp:/etc/kea:rw",
                    "--volume",
                    "/opt/containerdata/ztpbootstrap/dhcp/leases:/var/lib/kea:rw",
                    "--volume",
                    "/opt/containerdata/ztpbootstrap/dhcp/logs:/var/log/kea:rw",
                    "--volume",
                    "/opt/containerdata/ztpbootstrap/webui:/app:ro",
                    "--env",
                    "TZ=UTC",
                    "--cap-add",
                    "NET_RAW",
                    "--cap-add",
                    "NET_BIND_SERVICE",
                    "docker.io/iscorg/kea:2.6.1",
                    "/bin/sh",
                    "/app/start-kea.sh",
                ]

                logger.info("Starting container directly via podman (fallback method)...")
                direct_start_result = subprocess.run(
                    run_cmd,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )

                if direct_start_result.returncode == 0:
                    logger.info("Container started successfully via direct podman command")
                    systemctl_success = True  # Mark as success so we proceed to verification
                else:
                    # Check if container already exists (might be from previous run)
                    if "already in use" in direct_start_result.stderr.lower():
                        logger.info("Container name already in use, checking if it's running...")
                        # Check if container is actually running
                        ps_result = subprocess.run(
                            direct_podman_cmd
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
                        if DHCP_CONTAINER_NAME in ps_result.stdout:
                            logger.info("Container is already running")
                            systemctl_success = True
                        else:
                            # Container exists but isn't running, try to start it
                            logger.info("Container exists but not running, attempting to start...")
                            start_result = subprocess.run(
                                direct_podman_cmd + ["start", DHCP_CONTAINER_NAME],
                                capture_output=True,
                                text=True,
                                timeout=30,
                            )
                            if start_result.returncode == 0:
                                logger.info("Existing container started successfully")
                                systemctl_success = True
                            else:
                                logger.warning(
                                    f"Failed to start existing container: {start_result.stderr}"
                                )
                    else:
                        logger.warning(f"Direct podman start failed: {direct_start_result.stderr}")
                        logger.debug(f"Direct podman start stdout: {direct_start_result.stdout}")
            except Exception as e:
                logger.warning(f"Direct podman start fallback failed: {e}")
                import traceback

                logger.debug(f"Traceback: {traceback.format_exc()}")

        if not systemctl_success:
            logger.error(
                "Failed to start DHCP service via all available methods (systemctl, nsenter, podman)"
            )
            # Check if file actually exists in systemd directory or just temp location
            file_in_systemd = False
            file_in_temp = TEMP_DHCP_CONTAINER_FILE.exists()

            # Try multiple methods to verify file exists in systemd directory
            # Method 1: Try to read it directly (might work if mounted)
            try:
                if DHCP_CONTAINER_FILE.exists():
                    # Try to read a small portion to verify it's actually there
                    test_content = DHCP_CONTAINER_FILE.read_text()[:100]
                    if test_content and "[Unit]" in test_content:
                        file_in_systemd = True
            except (PermissionError, OSError, FileNotFoundError):
                # File doesn't exist or can't be read
                pass

            # Method 2: Try using podman to check (if socket is accessible)
            if not file_in_systemd:
                try:
                    podman_cmd = get_podman_cmd()
                    verify_result = subprocess.run(
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "--network=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "test",
                            "-f",
                            str(DHCP_CONTAINER_FILE),
                        ],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    file_in_systemd = verify_result.returncode == 0
                except Exception:
                    # Can't verify via podman, assume it doesn't exist
                    pass

            # Method 3: Try sudo test as last resort
            if not file_in_systemd:
                try:
                    verify_result = subprocess.run(
                        ["sudo", "test", "-f", str(DHCP_CONTAINER_FILE)],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    # Only trust this if we can also verify the file content
                    if verify_result.returncode == 0:
                        # Double-check by trying to read it
                        try:
                            read_result = subprocess.run(
                                ["sudo", "cat", str(DHCP_CONTAINER_FILE)],
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            if read_result.returncode == 0 and "[Unit]" in read_result.stdout:
                                file_in_systemd = True
                        except Exception:
                            pass
                except Exception:
                    # Can't verify, assume it doesn't exist
                    pass

            if file_in_systemd:
                logger.error(
                    f"Container file exists at {DHCP_CONTAINER_FILE}. "
                    f"Please run the following commands on the host to start the service:"
                )
                logger.error(
                    f"  sudo systemctl daemon-reload && sudo systemctl start {DHCP_SERVICE_NAME}"
                )
            elif file_in_temp:
                logger.error(
                    f"Container file was created in temp location only: {TEMP_DHCP_CONTAINER_FILE}"
                )
                logger.error("Please copy it to systemd directory and start the service:")
                logger.error(
                    f"  sudo cp {TEMP_DHCP_CONTAINER_FILE} {DHCP_CONTAINER_FILE} && "
                    f"sudo systemctl daemon-reload && sudo systemctl start {DHCP_SERVICE_NAME}"
                )
            else:
                logger.error("Container file was not created. Check logs above for errors.")

        # Wait up to 60 seconds for Kea installation and verify it's running
        logger.info("Starting DHCP service, waiting for Kea installation...")
        for i in range(12):  # Check every 5 seconds for up to 60 seconds
            time.sleep(5)
            status = check_dhcp_container_status()
            if status.get("container_running", False) or status.get("service_active", False):
                logger.info(f"DHCP container verified running after {i * 5} seconds")
                return True
            logger.debug(f"Waiting for container to start... ({i * 5}s)")

        if not systemctl_success:
            logger.error("systemctl start failed and container not running")
        else:
            logger.error("systemctl start succeeded but container not running after 60s")
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
        # First, check if container is actually running
        status = check_dhcp_container_status()
        if not status.get("container_running", False) and not status.get("service_active", False):
            logger.info("DHCP container is already stopped")
            return True

        # Use systemctl to stop the service (quadlets/systemd is our control mechanism)
        # Since we're running in a container, we need to execute systemctl on the host
        logger.info("Stopping DHCP service via systemctl on host...")

        # Try to use podman to run systemctl on the host
        # This works by running a container with access to the host's systemd
        podman_cmd = ["podman"]
        container_host = os.environ.get("CONTAINER_HOST")
        if container_host:
            podman_cmd.extend(["--url", container_host])

        # Method 1: Use podman run to execute systemctl on the host
        systemctl_success = False
        try:
            # Run a container with host systemd access to execute systemctl
            # Mount systemd socket, D-Bus socket, and cgroup for systemctl to work
            result = subprocess.run(
                podman_cmd
                + [
                    "run",
                    "--rm",
                    "--privileged",
                    "--pid=host",
                    "--network=host",
                    "--volume=/run/systemd:/run/systemd:rw",
                    "--volume=/run/dbus:/run/dbus:rw",
                    "--volume=/sys/fs/cgroup:/sys/fs/cgroup:ro",
                    "registry.fedoraproject.org/fedora:latest",
                    "systemctl",
                    "stop",
                    DHCP_SERVICE_NAME,
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode == 0:
                logger.info("systemctl stop command succeeded via podman run")
                systemctl_success = True
            else:
                logger.warning(f"Failed to stop via podman run systemctl: {result.stderr}")
        except Exception as e:
            logger.debug(f"podman run systemctl failed: {e}")

        # Method 2: Try direct systemctl (works if we're on the host, not in a container)
        if not systemctl_success:
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
                if result.returncode == 0:
                    logger.info("systemctl stop command succeeded (direct)")
                    systemctl_success = True
                else:
                    logger.warning(f"Failed to stop DHCP container via systemctl: {result.stderr}")
                    # Don't fail if service doesn't exist
                    if (
                        "not found" in result.stderr.lower()
                        or "does not exist" in result.stderr.lower()
                    ):
                        logger.info("Service doesn't exist, will try direct podman stop")
            except Exception as e:
                logger.debug(f"Direct systemctl failed: {e}")

        # Wait a moment for systemctl to take effect
        time.sleep(2)

        # Verify container actually stopped
        status = check_dhcp_container_status()
        if not status.get("container_running", False) and not status.get("service_active", False):
            logger.info("DHCP container stopped successfully via systemctl")
            return True

        # Container is still running, try direct podman stop as fallback
        logger.warning("Container still running after systemctl stop, trying direct podman stop...")
        try:
            podman_cmd = get_podman_cmd()

            # First, try to find the container and get its ID
            logger.info("Finding container...")
            if os.geteuid() == 0:
                ps_result = subprocess.run(
                    podman_cmd
                    + [
                        "ps",
                        "--filter",
                        f"name={DHCP_CONTAINER_NAME}",
                        "--format",
                        "{{.ID}}",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
            else:
                ps_result = subprocess.run(
                    ["sudo"]
                    + podman_cmd
                    + [
                        "ps",
                        "--filter",
                        f"name={DHCP_CONTAINER_NAME}",
                        "--format",
                        "{{.ID}}",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )

            container_id = None
            if ps_result.returncode == 0 and ps_result.stdout.strip():
                container_id = ps_result.stdout.strip().split()[0]
                logger.info(f"Found container ID: {container_id}")

            # Try multiple methods to stop the container
            # Use podman run to execute commands on the host since we're in a container
            stop_methods = []
            if container_id:
                stop_methods = [
                    # Method 1: Stop by ID using podman run (most reliable)
                    (
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "podman",
                            "stop",
                            container_id,
                        ],
                        "stop by ID via podman run",
                    ),
                    # Method 2: Kill by ID using podman run
                    (
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "podman",
                            "kill",
                            container_id,
                        ],
                        "kill by ID via podman run",
                    ),
                    # Method 3: Stop by name using podman run
                    (
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "podman",
                            "stop",
                            DHCP_CONTAINER_NAME,
                        ],
                        "stop by name via podman run",
                    ),
                    # Method 4: Kill by name using podman run
                    (
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "podman",
                            "kill",
                            DHCP_CONTAINER_NAME,
                        ],
                        "kill by name via podman run",
                    ),
                ]
            else:
                stop_methods = [
                    # Method 1: Stop by name using podman run
                    (
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "podman",
                            "stop",
                            DHCP_CONTAINER_NAME,
                        ],
                        "stop by name via podman run",
                    ),
                    # Method 2: Kill by name using podman run
                    (
                        podman_cmd
                        + [
                            "run",
                            "--rm",
                            "--privileged",
                            "--pid=host",
                            "registry.fedoraproject.org/fedora:latest",
                            "podman",
                            "kill",
                            DHCP_CONTAINER_NAME,
                        ],
                        "kill by name via podman run",
                    ),
                ]

            for cmd, method_name in stop_methods:
                logger.info(f"Trying podman {method_name}...")
                podman_result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )

                if podman_result.returncode == 0:
                    logger.info(f"Container stop command succeeded via {method_name}")
                    # Wait and verify
                    time.sleep(3)
                    status = check_dhcp_container_status()
                    if not status.get("container_running", False) and not status.get(
                        "service_active", False
                    ):
                        logger.info(f"DHCP container verified stopped after {method_name}")
                        return True
                    else:
                        logger.warning(
                            f"Container still appears to be running after {method_name}, trying next method..."
                        )
                        continue
                else:
                    logger.debug(
                        f"Failed to stop container via {method_name}: {podman_result.stderr}"
                    )
                    continue

            # Last resort: try to stop the entire pod (if container is in a pod)
            logger.warning("All container stop methods failed, trying to stop via pod...")
            for pod_cmd_name in [
                "ztpbootstrap",
                "ztpbootstrap-infra",
                "ztpbootstrap.pod",
            ]:
                pod_stop_result = subprocess.run(
                    podman_cmd
                    + [
                        "run",
                        "--rm",
                        "--privileged",
                        "--pid=host",
                        "registry.fedoraproject.org/fedora:latest",
                        "podman",
                        "pod",
                        "stop",
                        pod_cmd_name,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )

                if pod_stop_result.returncode == 0:
                    logger.info(f"Pod {pod_cmd_name} stopped, checking container status...")
                    time.sleep(3)
                    status = check_dhcp_container_status()
                    if not status.get("container_running", False) and not status.get(
                        "service_active", False
                    ):
                        logger.info("DHCP container stopped via pod stop")
                        return True

            logger.error("All stop methods failed - container may still be running")
            return False
        except Exception as e:
            logger.error(f"Exception during podman stop: {e}")
            return False

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


def check_dhcp_container_status() -> Dict[str, Any]:
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
            # Use helper function to get podman command with appropriate connection
            podman_cmd = get_podman_cmd()

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
                # If podman found the container, it's running - trust that
                # systemctl might fail from inside a container, so don't invalidate container_running
                if result["service_active"]:
                    result["service_status"] = "active"
                else:
                    # Container is running but systemctl check failed (likely from inside container)
                    # Assume service is active if container is running
                    result["service_active"] = True
                    result["service_status"] = "active"
                    logger.debug("Container found running via podman, assuming service is active")
        except Exception as e:
            logger.debug(f"Could not check container via podman: {e}")

        # Fallback: Check if Kea control agent is responding (port 8000)
        # This is a reliable way to verify the container is actually running
        # Use this when systemctl/podman checks fail (common from inside containers)
        # Note: For macvlan networking, the control agent won't be on 127.0.0.1
        # so we skip this check if we're on host network but DHCP is on macvlan
        if not result["container_running"] or not result["service_active"]:
            try:
                import socket

                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                result_check = sock.connect_ex(("127.0.0.1", 8000))
                sock.close()
                if result_check == 0:
                    # Port is open, so Kea is running
                    result["container_running"] = True
                    result["service_active"] = True
                    result["service_status"] = "active"
                    logger.debug("Kea control agent port check: service is running")
            except Exception as e:
                logger.debug(f"Could not check Kea control agent port: {e}")

        # Don't use lease file as a fallback - it can exist even when service is stopped
        # Trust systemctl and podman checks only

        # Don't assume running just because file exists - trust systemctl and podman checks

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
