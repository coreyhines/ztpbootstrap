#!/usr/bin/env python3
"""
Simple Web UI for ZTP Bootstrap Service
Lightweight Flask application for configuration and monitoring
"""

import fcntl
import json
import logging
import os
import re
import secrets
import subprocess
import time
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path

import yaml
from flask import Flask, jsonify, render_template, request, send_from_directory, session
from werkzeug.security import check_password_hash, generate_password_hash

# Debug flag - set via environment variable
DEBUG = os.environ.get("DEBUG", "false").lower() == "true"

# Import security and utility modules
try:
    from config_manager import ConfigManager
    from dhcp_validation import validate_dhcp_config
    from rate_limiter import rate_limiter
except ImportError as e:
    print(f"Warning: Security/utility modules not available: {e}", flush=True)
    # Create fallback if needed
    rate_limiter = None
    ConfigManager = None
    validate_dhcp_config = None

# Import DHCP modules
try:
    from dhcp_config import generate_kea_config
    from dhcp_deploy import (
        check_dhcp_container_status,
        create_dhcp_container,
        start_dhcp_container,
        stop_dhcp_container,
    )
    from dhcp_utils import (
        calculate_default_range,
        check_dhcp_port_conflicts,
        detect_gateway,
        detect_host_interfaces,
        detect_networking_mode,
        detect_subnet,
    )
    from kea_client import (
        add_reservation,
        delete_lease,
        delete_reservation,
        get_lease,
        get_leases,
        get_statistics,
        reload_config,
    )
except ImportError as e:
    # DHCP modules not available - will fail gracefully
    print(f"Warning: DHCP modules not available: {e}", flush=True)

# Import network modules
try:
    from network_config import get_ztp_profile, merge_ztp_update, sync_legacy_network_fields
    from network_deploy import (
        apply_ztp_network,
        auto_detect_from_parent,
        get_network_status,
        restart_ztp_stack,
    )
    from network_utils import discover_parent_interfaces, list_ztp_podman_networks
    from network_validation import plan_network_changes, validate_ztp_profile
except ImportError as e:
    print(f"Warning: Network modules not available: {e}", flush=True)
    get_ztp_profile = None
    merge_ztp_update = None
    sync_legacy_network_fields = None
    apply_ztp_network = None
    auto_detect_from_parent = None
    get_network_status = None
    restart_ztp_stack = None
    discover_parent_interfaces = None
    list_ztp_podman_networks = None
    plan_network_changes = None
    validate_ztp_profile = None

# Import security utilities
try:
    from security_utils import (
        sanitize_filename,
        validate_filename_for_api,
        validate_password_complexity,
        validate_path_in_directory,
        validate_python_file_content,
    )
except ImportError:
    # Fallback if security_utils not available
    def sanitize_filename(filename):
        if not filename or not isinstance(filename, str):
            return None
        filename = Path(filename).name.replace("\x00", "")
        if not re.match(r"^bootstrap[a-zA-Z0-9_.-]*\.py$", filename):
            return None
        if any(pattern in filename for pattern in ["..", "/", "\\"]):
            return None
        return filename

    def validate_path_in_directory(file_path, base_directory):
        try:
            resolved_path = file_path.resolve()
            resolved_base = base_directory.resolve()
            return os.path.commonpath([str(resolved_path), str(resolved_base)]) == str(
                resolved_base
            )
        except (OSError, ValueError):
            return False

    def validate_python_file_content(file_stream, max_preview_bytes=2048):
        return True, ""

    def validate_password_complexity(password):
        return len(password) >= 8, ""

    def validate_filename_for_api(filename):
        if not filename or not isinstance(filename, str) or not filename.endswith(".py"):
            return False, None
        sanitized = sanitize_filename(filename)
        return (sanitized is not None), sanitized


def safe_path_join(base_dir, filename):
    """
    Safely join a base directory with a sanitized filename.
    This function ensures the resulting path is within base_dir.

    This function prevents path traversal attacks by:
    1. Validating filename contains no path separators
    2. Validating the resulting path is strictly within base_dir
    3. Returning None if any validation fails

    Args:
        base_dir: Base directory Path object (trusted, from environment/config)
        filename: Sanitized filename (must be validated via validate_filename_for_api first)

    Returns:
        Path object if safe, None otherwise

    Note: CodeQL may flag this as path injection, but the filename parameter
    is guaranteed to be sanitized by validate_filename_for_api() before calling this function.
    """
    if not filename or not isinstance(filename, str):
        return None

    # Double-check filename is safe (no path components)
    # This is redundant but helps CodeQL understand the validation
    if "/" in filename or "\\" in filename or ".." in filename:
        return None

    # Construct path - CodeQL may flag this, but filename is validated above
    # nosemgrep: python.lang.security.path-injection.path-injection
    result_path = base_dir / filename

    # Validate the path is within base directory (prevents path traversal)
    if not validate_path_in_directory(result_path, base_dir):
        return None

    return result_path


app = Flask(__name__)
# Enable template auto-reload in production for development/testing
app.config["TEMPLATES_AUTO_RELOAD"] = True

# Configuration paths
CONFIG_DIR = Path(os.environ.get("ZTP_CONFIG_DIR", "/opt/containerdata/ztpbootstrap"))
CONFIG_FILE = CONFIG_DIR / "config.yaml"
BOOTSTRAP_SCRIPT = CONFIG_DIR / "bootstrap.py"
NGINX_CONF = CONFIG_DIR / "nginx.conf"
SCRIPTS_METADATA = CONFIG_DIR / "scripts_metadata.json"
DEVICE_CONNECTIONS_FILE = CONFIG_DIR / "device_connections.json"
# Try shared volume first, then container path
NGINX_ACCESS_LOG = Path("/var/log/nginx/ztpbootstrap_access.log")
NGINX_ERROR_LOG = Path("/var/log/nginx/ztpbootstrap_error.log")
# Fallback to config directory if mounted there
if not NGINX_ACCESS_LOG.exists():
    NGINX_ACCESS_LOG = CONFIG_DIR / "logs" / "ztpbootstrap_access.log"
if not NGINX_ERROR_LOG.exists():
    NGINX_ERROR_LOG = CONFIG_DIR / "logs" / "ztpbootstrap_error.log"

# Initialize ConfigManager for thread-safe config updates (Issue #1)
config_manager = ConfigManager(CONFIG_FILE) if ConfigManager else None

# ============================================================================
# Security Event Logging Configuration
# ============================================================================

# Configure security logger for audit trail
security_logger = logging.getLogger("security")
security_logger.setLevel(logging.INFO)

logger = logging.getLogger(__name__)

# Create logs directory if it doesn't exist
SECURITY_LOG_DIR = CONFIG_DIR / "logs"
SECURITY_LOG_DIR.mkdir(parents=True, exist_ok=True)

# Add file handler for security events
security_log_file = SECURITY_LOG_DIR / "security.log"
security_handler = logging.FileHandler(security_log_file)
security_handler.setLevel(logging.INFO)

# Format: timestamp | level | IP | username | action | outcome | details
security_formatter = logging.Formatter(
    "%(asctime)s | %(levelname)s | %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
)
security_handler.setFormatter(security_formatter)
security_logger.addHandler(security_handler)

# Also log to console for debugging
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)
console_handler.setFormatter(security_formatter)
security_logger.addHandler(console_handler)


def log_security_event(event_type, outcome, ip_address=None, details=None):
    """
    Log a security-relevant event

    Args:
        event_type: Type of event (e.g., 'login', 'file_upload', 'csrf_failure')
        outcome: 'success' or 'failure'
        ip_address: Client IP address (optional)
        details: Additional details about the event (optional)
    """
    ip_str = f"IP={ip_address}" if ip_address else "IP=unknown"
    details_str = f" | {details}" if details else ""

    log_message = f"{ip_str} | event={event_type} | outcome={outcome}{details_str}"

    if outcome == "failure":
        security_logger.warning(log_message)
    else:
        security_logger.info(log_message)


# ============================================================================
# Authentication Configuration
# ============================================================================


# Load authentication configuration
def load_auth_config():
    """Load authentication configuration from config.yaml or environment"""
    config = {
        "admin_password_hash": None,
        "session_timeout": 3600,  # Default: 1 hour
        "session_secret": None,
    }

    # Try to load from config.yaml
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r") as f:
                yaml_config = yaml.safe_load(f)
                if yaml_config and "auth" in yaml_config:
                    auth_config = yaml_config["auth"]
                    if "admin_password_hash" in auth_config:
                        # Ensure it's a string (YAML might return other types)
                        hash_value = auth_config["admin_password_hash"]
                        config["admin_password_hash"] = str(hash_value) if hash_value else None
                    if "session_timeout" in auth_config:
                        config["session_timeout"] = auth_config["session_timeout"]
                    if "session_secret" in auth_config:
                        config["session_secret"] = auth_config["session_secret"]
        except Exception as e:
            print(f"Warning: Failed to load auth config from {CONFIG_FILE}: {e}")

    # Override with environment variable if set
    env_password = os.environ.get("ZTP_ADMIN_PASSWORD")
    if env_password:
        # Hash the plain text password from environment
        config["admin_password_hash"] = generate_password_hash(env_password)

    # Generate session secret if not provided and persist it (Issue #8)
    if not config["session_secret"]:
        config["session_secret"] = secrets.token_hex(32)
        # Persist the generated session secret to config file
        try:
            if config_manager and CONFIG_FILE.exists():
                # Only update the auth section's session_secret
                current_config = config_manager.read_config()
                if "auth" not in current_config:
                    current_config["auth"] = {}
                current_config["auth"]["session_secret"] = config["session_secret"]
                config_manager.write_config(current_config)
        except Exception as e:
            print(f"Warning: Failed to persist session secret: {e}")

    return config


# Load auth config
AUTH_CONFIG = load_auth_config()


# Function to reload auth config (useful after password changes)
def reload_auth_config():
    """Reload authentication configuration from config.yaml"""
    global AUTH_CONFIG
    AUTH_CONFIG = load_auth_config()
    # NOTE: Do NOT update app.secret_key here - changing the secret key during
    # a request breaks Flask session cookie signing. The secret key should only
    # be set once at startup. If the session_secret changes, the app must be
    # restarted for it to take effect.


# Configure Flask session
app.secret_key = AUTH_CONFIG["session_secret"]
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
# Only set Secure flag if HTTPS is available
app.config["SESSION_COOKIE_SECURE"] = os.environ.get("HTTPS_ENABLED", "false").lower() == "true"
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(seconds=AUTH_CONFIG["session_timeout"])

# Rate limiting storage (simple in-memory dict)
login_attempts = {}


def clean_old_attempts():
    """Clean up old login attempts (older than 15 minutes)"""
    cutoff = time.time() - 900  # 15 minutes
    to_remove = [ip for ip, data in login_attempts.items() if data["reset_time"] < cutoff]
    for ip in to_remove:
        del login_attempts[ip]


def is_rate_limited(ip):
    """
    Check if IP is rate limited

    Rate limiting rules:
    - Maximum 5 failed attempts per 15 minutes
    - Lockout duration: 15 minutes from first failed attempt
    - Successful login resets the counter
    """
    clean_old_attempts()
    if ip in login_attempts:
        data = login_attempts[ip]
        if data["attempts"] >= 5 and time.time() < data["reset_time"]:
            return True
    return False


def record_login_attempt(ip, success):
    """Record a login attempt"""
    clean_old_attempts()
    if ip not in login_attempts:
        login_attempts[ip] = {"attempts": 0, "reset_time": time.time() + 900}

    if success:
        # Reset on successful login
        if ip in login_attempts:
            del login_attempts[ip]
    else:
        # Increment failed attempts
        login_attempts[ip]["attempts"] += 1
        # Reset time is 15 minutes from first failed attempt
        if login_attempts[ip]["attempts"] == 1:
            login_attempts[ip]["reset_time"] = time.time() + 900


def is_authenticated():
    """Check if current session is authenticated"""
    if "authenticated" not in session:
        return False
    if not session["authenticated"]:
        return False
    # Check if session has expired
    if "expires_at" in session:
        if time.time() > session["expires_at"]:
            # Session expired
            session.clear()
            return False
    return True


def generate_csrf_token():
    """Generate a CSRF token for the current session"""
    if "csrf_token" not in session:
        session["csrf_token"] = secrets.token_hex(32)
    return session["csrf_token"]


def validate_csrf_token(token):
    """Validate a CSRF token"""
    if "csrf_token" not in session:
        return False
    return secrets.compare_digest(session["csrf_token"], token)


def require_auth(f):
    """Decorator to require authentication for write endpoints"""

    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not is_authenticated():
            return jsonify({"error": "Authentication required", "code": "AUTH_REQUIRED"}), 401

        # CSRF protection for write operations (POST, PUT, DELETE, PATCH)
        if request.method in ["POST", "PUT", "DELETE", "PATCH"]:
            # Get CSRF token from header or JSON body
            csrf_token = (
                request.headers.get("X-CSRF-Token")
                or request.get_json(silent=True, force=True)
                or {}
            )
            if isinstance(csrf_token, dict):
                csrf_token = csrf_token.get("csrf_token")

            if not csrf_token or not validate_csrf_token(csrf_token):
                # Log CSRF failure
                client_ip = request.remote_addr or "unknown"
                log_security_event(
                    "csrf_validation",
                    "failure",
                    client_ip,
                    f"endpoint={request.endpoint} method={request.method}",
                )
                return (
                    jsonify({"error": "Invalid or missing CSRF token", "code": "CSRF_ERROR"}),
                    403,
                )

        return f(*args, **kwargs)

    return decorated_function


# ============================================================================
# Authentication Endpoints
# ============================================================================


@app.route("/api/auth/status")
def auth_status():
    """Get current authentication status"""
    if is_authenticated():
        # Generate CSRF token if not exists
        csrf_token = generate_csrf_token()
        return jsonify(
            {
                "authenticated": True,
                "expires_at": session.get("expires_at"),
                "csrf_token": csrf_token,
            }
        )
    return jsonify({"authenticated": False, "expires_at": None, "csrf_token": None})


@app.route("/api/auth/login", methods=["POST"])
def auth_login():
    """Login endpoint"""
    # Reload auth config on each login attempt to pick up password changes
    reload_auth_config()
    try:
        # Get client IP
        client_ip = request.remote_addr or "unknown"

        # Check rate limiting
        if is_rate_limited(client_ip):
            # Log security event
            log_security_event("login", "failure", client_ip, "reason=rate_limited")

            # Calculate remaining lockout time
            if client_ip in login_attempts:
                remaining_time = int(login_attempts[client_ip]["reset_time"] - time.time())
                remaining_minutes = max(0, remaining_time // 60)
                return (
                    jsonify(
                        {
                            "error": f"Too many login attempts. Please try again in {remaining_minutes} minute(s).",
                            "code": "RATE_LIMITED",
                            "remaining_time": remaining_time,
                        }
                    ),
                    429,
                )
            return (
                jsonify(
                    {
                        "error": "Too many login attempts. Please try again later.",
                        "code": "RATE_LIMITED",
                    }
                ),
                429,
            )

        # Check if authentication is configured
        if not AUTH_CONFIG["admin_password_hash"]:
            return (
                jsonify(
                    {"error": "Authentication is not configured", "code": "AUTH_NOT_CONFIGURED"}
                ),
                503,
            )

        # Get password from request
        data = request.get_json()
        if not data or "password" not in data:
            record_login_attempt(client_ip, False)
            return jsonify({"error": "Password is required", "code": "MISSING_PASSWORD"}), 400

        password = data["password"]

        # Debug logging (only in debug mode)
        if DEBUG:
            print(
                f"Login attempt: password length={len(password)}, hash format={AUTH_CONFIG['admin_password_hash'][:30] if AUTH_CONFIG.get('admin_password_hash') else 'None'}...",
                flush=True,
            )

        # Verify password
        # Handle both Werkzeug format and fallback format from setup script
        password_hash = AUTH_CONFIG["admin_password_hash"]
        password_valid = False

        # Check if this is the fallback format from setup-interactive.sh
        # Format: pbkdf2:sha256:<base64_hash> (no $ separator)
        if (
            password_hash
            and password_hash.startswith("pbkdf2:sha256:")
            and "$" not in password_hash
        ):
            # Use fallback format verification
            # lgtm[py/path-injection]
            # CodeQL: password_hash comes from config file (trusted source), not user input
            import base64
            import hashlib

            try:
                # Extract the base64 hash
                hash_part = password_hash.split(":", 2)[2]
                # Decode the base64 hash (handle padding if needed)
                try:
                    stored_hash = base64.b64decode(hash_part)
                except Exception as e:
                    if DEBUG:
                        print(
                            f"Base64 decode error (first attempt): {e}, hash_part length: {len(hash_part)}",
                            flush=True,
                        )
                    # Add padding if needed (base64 strings must be multiple of 4)
                    missing_padding = len(hash_part) % 4
                    if missing_padding:
                        hash_part += "=" * (4 - missing_padding)
                    try:
                        stored_hash = base64.b64decode(hash_part)
                    except Exception as e2:
                        if DEBUG:
                            print(f"Base64 decode error (after padding): {e2}", flush=True)
                        password_valid = False
                        stored_hash = None
                # Generate hash with same parameters (salt='ztpbootstrap', iterations=100000)
                if stored_hash:
                    computed_hash = hashlib.pbkdf2_hmac(
                        "sha256", password.encode("utf-8"), b"ztpbootstrap", 100000
                    )
                    password_valid = stored_hash == computed_hash
                    if DEBUG:
                        print(
                            f"Password verification (fallback format): valid={password_valid}, hash lengths match={len(stored_hash) == len(computed_hash)}",
                            flush=True,
                        )
            except Exception as e:
                if DEBUG:
                    print(
                        f"Exception during fallback password verification: {type(e).__name__}: {e}",
                        flush=True,
                    )
                password_valid = False
        else:
            # Use Werkzeug's standard format
            try:
                password_valid = check_password_hash(password_hash, password)
                if DEBUG:
                    print(
                        f"Password verification (Werkzeug format): valid={password_valid}",
                        flush=True,
                    )
            except (ValueError, TypeError) as e:
                if DEBUG:
                    print(
                        f"Exception during Werkzeug password verification: {type(e).__name__}: {e}",
                        flush=True,
                    )
                password_valid = False

        if password_valid:
            # Successful login
            record_login_attempt(client_ip, True)

            # Migrate from legacy fallback format to Werkzeug (per-user salt)
            if (
                password_hash
                and password_hash.startswith("pbkdf2:sha256:")
                and "$" not in password_hash
            ):
                try:
                    new_hash = generate_password_hash(password)
                    with open(CONFIG_FILE, "r") as f:
                        yaml_config = yaml.safe_load(f) or {}
                    if "auth" not in yaml_config:
                        yaml_config["auth"] = {}
                    yaml_config["auth"]["admin_password_hash"] = new_hash
                    with open(CONFIG_FILE, "w") as f:
                        yaml.dump(
                            yaml_config,
                            f,
                            default_flow_style=False,
                            sort_keys=False,
                            allow_unicode=True,
                        )
                    reload_auth_config()
                    log_security_event(
                        "login",
                        "success",
                        client_ip,
                        "user=admin details=migrated_legacy_password_to_werkzeug",
                    )
                except Exception:
                    log_security_event("login", "success", client_ip, "user=admin")
            else:
                log_security_event("login", "success", client_ip, "user=admin")

            # Create session
            session["authenticated"] = True
            session["login_time"] = time.time()
            session["expires_at"] = time.time() + AUTH_CONFIG["session_timeout"]
            session.permanent = True

            # Generate CSRF token for the session
            csrf_token = generate_csrf_token()

            return jsonify(
                {
                    "success": True,
                    "expires_at": session["expires_at"],
                    "csrf_token": csrf_token,
                }
            )
        else:
            # Failed login
            record_login_attempt(client_ip, False)

            # Log security event
            log_security_event("login", "failure", client_ip, "user=admin reason=invalid_password")

            return jsonify({"error": "Invalid password", "code": "INVALID_PASSWORD"}), 401
    except Exception as e:
        if DEBUG:
            print(f"Login error: {type(e).__name__}: {e}", flush=True)
        return jsonify({"error": "Login failed", "code": "LOGIN_ERROR"}), 500


@app.route("/api/auth/logout", methods=["POST"])
def auth_logout():
    """Logout endpoint"""
    session.clear()
    return jsonify({"success": True})


@app.route("/api/auth/change-password", methods=["POST"])
@require_auth
def auth_change_password():
    """Change admin password endpoint"""
    try:
        data = request.get_json()
        if not data or "current_password" not in data or "new_password" not in data:
            return (
                jsonify(
                    {
                        "error": "Current password and new password are required",
                        "code": "MISSING_PASSWORD",
                    }
                ),
                400,
            )

        current_password = data["current_password"]
        new_password = data["new_password"]

        # Validate new password (12 chars min, 2+ character types per best practices)
        pwd_valid, pwd_error = validate_password_complexity(new_password)
        if not pwd_valid:
            return jsonify({"error": pwd_error, "code": "PASSWORD_WEAK"}), 400

        # Declare global before using it
        global AUTH_CONFIG

        # Verify current password
        password_hash = AUTH_CONFIG["admin_password_hash"]
        password_valid = False

        # Check if this is the fallback format from setup-interactive.sh
        if (
            password_hash
            and password_hash.startswith("pbkdf2:sha256:")
            and "$" not in password_hash
        ):
            import base64
            import hashlib

            try:
                hash_part = password_hash.split(":", 2)[2]
                stored_hash = base64.b64decode(hash_part)
                computed_hash = hashlib.pbkdf2_hmac(
                    "sha256", current_password.encode("utf-8"), b"ztpbootstrap", 100000
                )
                password_valid = stored_hash == computed_hash
            except Exception:
                password_valid = False
        else:
            # Use werkzeug's check_password_hash (imported at top of file)
            try:
                password_valid = check_password_hash(password_hash, current_password)
            except (ValueError, TypeError, AttributeError):
                password_valid = False

        if not password_valid:
            return (
                jsonify({"error": "Current password is incorrect", "code": "INVALID_PASSWORD"}),
                401,
            )

        # Generate new password hash using Werkzeug (secure with random salt)
        # This migrates legacy passwords to secure format (Issue #2)
        try:
            new_password_hash = generate_password_hash(new_password)
            # Log migration if old password was legacy format
            if (
                password_hash
                and password_hash.startswith("pbkdf2:sha256:")
                and "$" not in password_hash
            ):
                security_logger.info(
                    f"IP={request.remote_addr} | event=password_migration | outcome=success | details=Migrated from legacy hardcoded-salt format to Werkzeug format"
                )
        except (ImportError, NameError):
            # Fallback to hashlib format (same as setup script)
            # WARNING: This uses hardcoded salt and should be migrated (Issue #2)
            security_logger.warning(
                f"IP={request.remote_addr} | event=password_change | outcome=warning | details=Using legacy password format with hardcoded salt"
            )
            import base64
            import hashlib

            hash_bytes = hashlib.pbkdf2_hmac(
                "sha256", new_password.encode("utf-8"), b"ztpbootstrap", 100000
            )
            hash_b64 = base64.b64encode(hash_bytes).decode("utf-8")
            new_password_hash = f"pbkdf2:sha256:{hash_b64}"

        # Update config.yaml
        if CONFIG_FILE.exists():
            try:
                # Read current config
                with open(CONFIG_FILE, "r") as f:
                    yaml_config = yaml.safe_load(f) or {}

                # Ensure auth section exists
                if "auth" not in yaml_config:
                    yaml_config["auth"] = {}

                # Update password hash (ensure it's a string and properly formatted)
                # Werkzeug hashes contain special characters ($, :) that need proper handling
                yaml_config["auth"]["admin_password_hash"] = str(new_password_hash).strip()

                # Write back to file using atomic write with file locking (write to temp, then rename)

                temp_file = CONFIG_FILE.with_suffix(".yaml.tmp")
                try:
                    # Use file locking to prevent race conditions
                    with open(CONFIG_FILE, "r+") as lock_file:
                        try:
                            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except (IOError, OSError):
                            # File is locked by another process, wait briefly and retry
                            time.sleep(0.1)
                            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

                        # Write to temp file while holding lock
                        with open(temp_file, "w") as f:
                            yaml.dump(
                                yaml_config,
                                f,
                                default_flow_style=False,
                                sort_keys=False,
                                allow_unicode=True,
                            )
                        # Atomic rename (releases lock automatically)
                        temp_file.replace(CONFIG_FILE)
                except (IOError, OSError) as e:
                    # File locking not available (Windows) or failed - use atomic write without lock
                    if DEBUG:
                        print(f"File locking not available, using atomic write: {e}", flush=True)
                    try:
                        with open(temp_file, "w") as f:
                            yaml.dump(
                                yaml_config,
                                f,
                                default_flow_style=False,
                                sort_keys=False,
                                allow_unicode=True,
                            )
                        # Atomic rename
                        temp_file.replace(CONFIG_FILE)
                    except Exception as e2:
                        # Clean up temp file on error
                        if temp_file.exists():
                            temp_file.unlink()
                        raise e2
                except Exception as e:
                    # Clean up temp file on error
                    if temp_file.exists():
                        temp_file.unlink()
                    raise e

                # Reload auth config using the reload function
                reload_auth_config()

                # Verify the new hash was loaded correctly
                loaded_hash = AUTH_CONFIG.get("admin_password_hash")
                expected_hash = str(new_password_hash).strip()
                test_result = False

                if loaded_hash != expected_hash:
                    # Hash format might differ but still be valid (e.g., werkzeug generates different formats)
                    # Still try to verify the password works with the loaded hash
                    pass

                # Verify the new password works with the loaded hash
                if loaded_hash:
                    try:
                        # Use check_password_hash imported at top of file
                        test_result = check_password_hash(loaded_hash, new_password)
                    except (ImportError, NameError, AttributeError):
                        # Fallback format verification
                        if loaded_hash.startswith("pbkdf2:sha256:") and "$" not in loaded_hash:
                            import base64
                            import hashlib

                            try:
                                hash_part = loaded_hash.split(":", 2)[2]
                                stored_hash = base64.b64decode(hash_part)
                                computed_hash = hashlib.pbkdf2_hmac(
                                    "sha256", new_password.encode("utf-8"), b"ztpbootstrap", 100000
                                )
                                test_result = stored_hash == computed_hash
                            except Exception:
                                test_result = False

                if not test_result:
                    if DEBUG:
                        print(
                            "ERROR: New password hash verification failed after reload!",
                            flush=True,
                        )

                return jsonify({"success": True})
            except Exception as e:
                # Log detailed error for debugging
                import traceback

                if DEBUG:
                    print(
                        f"Error updating password in config.yaml: {type(e).__name__}: {e}",
                        flush=True,
                    )
                    print(f"Traceback: {traceback.format_exc()}", flush=True)
                return (
                    jsonify(
                        {
                            "error": "Failed to update password. Please check file permissions.",
                            "code": "UPDATE_ERROR",
                        }
                    ),
                    500,
                )
        else:
            return jsonify({"error": "Config file not found", "code": "CONFIG_NOT_FOUND"}), 404
    except Exception as e:
        # Log detailed error for debugging
        import traceback

        if DEBUG:
            print(f"Change password error: {type(e).__name__}: {e}", flush=True)
            print(f"Traceback: {traceback.format_exc()}", flush=True)
        return jsonify({"error": "Failed to change password", "code": "CHANGE_PASSWORD_ERROR"}), 500


# ============================================================================
# Original Routes (Read-Only - No Auth Required)
# ============================================================================


@app.route("/")
def index():
    """Main dashboard page"""
    return render_template("index.html")


@app.route("/images/<path:filename>")
def serve_image(filename):
    """Serve images from webui/images directory"""
    images_dir = Path(__file__).parent / "images"
    if not images_dir.exists():
        return "Images directory not found", 404
    try:
        return send_from_directory(str(images_dir), filename)
    except FileNotFoundError:
        return "Image not found", 404


@app.route("/api/config")
@require_auth
def get_config():
    """Get current configuration (requires authentication due to sensitive data)"""
    try:
        if CONFIG_FILE.exists():
            raw_content = CONFIG_FILE.read_text()
            # Try to parse YAML using PyYAML
            try:
                parsed_config = yaml.safe_load(raw_content)
                return jsonify({"parsed": parsed_config, "raw": raw_content})
            except yaml.YAMLError:
                # YAML parsing failed, return raw content
                return jsonify(
                    {
                        "raw": raw_content,
                        "parsed": None,
                        "error": "YAML parse error: Invalid configuration file format",
                    }
                )
        else:
            return jsonify({"error": "Config file not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def load_scripts_metadata():
    """Load scripts metadata from JSON file"""
    if SCRIPTS_METADATA.exists():
        try:
            with open(SCRIPTS_METADATA, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_scripts_metadata(metadata):
    """Save scripts metadata to JSON file"""
    # lgtm[py/path-injection]
    # CodeQL: SCRIPTS_METADATA is a trusted path constructed from CONFIG_DIR (environment variable)
    # It is not user-controlled and is safe to use
    try:
        with open(SCRIPTS_METADATA, "w") as f:
            json.dump(metadata, f, indent=2)
        return True
    except Exception as e:
        print(f"Error saving metadata: {e}")
        return False


def cleanup_old_backups():
    """Keep only the 5 most recent backup files, delete older ones"""
    try:
        script_dir = CONFIG_DIR
        backup_files = []

        # Find all backup files
        for file in script_dir.glob("bootstrap_backup_*.py"):
            try:
                backup_files.append((file.stat().st_mtime, file))
            except OSError:
                continue

        # Sort by modification time (newest first)
        backup_files.sort(key=lambda x: x[0], reverse=True)

        # Keep only the 5 most recent, delete the rest
        if len(backup_files) > 5:
            for mtime, backup_file in backup_files[5:]:
                try:
                    backup_file.unlink()
                    print(f"Deleted old backup: {backup_file.name}")
                except OSError as e:
                    print(f"Error deleting backup {backup_file.name}: {e}")
    except Exception as e:
        print(f"Error cleaning up backups: {e}")


@app.route("/api/bootstrap-scripts")
def list_bootstrap_scripts():
    """List available bootstrap scripts"""
    scripts = []
    script_dir = CONFIG_DIR
    active_script = None

    # Check which script is currently active (bootstrap.py is the active one)
    active_path = BOOTSTRAP_SCRIPT
    if active_path.exists():
        if active_path.is_symlink():
            # Resolve symlink to get the actual target file
            try:
                resolved = active_path.resolve()
                active_script = resolved.name
            except Exception:
                active_script = active_path.name
        else:
            # bootstrap.py is a regular file, so it's the active one
            active_script = active_path.name

    # Get the resolved path and name of the active script for comparison
    active_resolved_path = None
    active_resolved_name = None
    if active_script:
        try:
            active_file = script_dir / active_script
            if active_file.exists():
                active_resolved_path = active_file.resolve()
                active_resolved_name = active_resolved_path.name
        except Exception:
            pass

    for file in script_dir.glob("bootstrap*.py"):
        # Skip backup files (they shouldn't be shown in the UI)
        if file.name.startswith("bootstrap_backup_"):
            continue

        # Skip symlink loops (symlinks pointing to themselves)
        try:
            if file.is_symlink():
                resolved = file.resolve()
                if resolved == file:
                    # Symlink loop detected, skip this file
                    continue
        except (OSError, RuntimeError):
            # Error resolving symlink (loop or broken), skip this file
            continue

        # Only mark as active if this file's NAME matches the resolved target name
        # This ensures only the actual target file is marked active, not the symlink
        is_active = False
        if active_resolved_name:
            # Compare by name, not by resolved path, to avoid marking symlinks as active
            is_active = file.name == active_resolved_name
        else:
            is_active = file.name == active_script

        try:
            # For bootstrap.py, if it's a symlink, we still want to show it
            # but we'll mark the target as active instead
            file_stat = file.stat()
            scripts.append(
                {
                    "name": file.name,
                    "path": str(file),
                    "size": file_stat.st_size,
                    "modified": file_stat.st_mtime,
                    "active": is_active,
                }
            )
        except OSError:
            # Skip files that can't be stat'd (e.g., symlink loops)
            continue

    # Always include bootstrap.py in the list if it exists (even as symlink)
    # This ensures it's visible even when it's a symlink to another file
    bootstrap_py_path = script_dir / "bootstrap.py"
    if bootstrap_py_path.exists() and not any(s["name"] == "bootstrap.py" for s in scripts):
        try:
            is_active = False
            if active_resolved_name:
                # If bootstrap.py is a symlink, check if its target matches
                if bootstrap_py_path.is_symlink():
                    try:
                        resolved = bootstrap_py_path.resolve()
                        is_active = resolved.name == active_resolved_name
                    except Exception:
                        pass
                else:
                    is_active = "bootstrap.py" == active_resolved_name
            else:
                is_active = "bootstrap.py" == active_script

            file_stat = bootstrap_py_path.stat()
            scripts.append(
                {
                    "name": "bootstrap.py",
                    "path": str(bootstrap_py_path),
                    "size": file_stat.st_size,
                    "modified": file_stat.st_mtime,
                    "active": is_active,
                }
            )
        except OSError:
            pass

    # Sort scripts: active script first, then by name
    scripts.sort(key=lambda x: (not x["active"], x["name"]))

    return jsonify({"scripts": scripts, "active": active_script})


@app.route("/api/bootstrap-script/<filename>")
def get_bootstrap_script(filename):
    """
    Get bootstrap script content.

    Security: The filename parameter is validated via validate_filename_for_api()
    before being used in path construction, preventing path traversal attacks.
    """
    try:
        # Validate filename to prevent path traversal
        # CodeQL: filename is validated and sanitized before path construction
        is_valid, sanitized_filename = validate_filename_for_api(filename)
        if not is_valid:
            return jsonify({"error": "Invalid filename"}), 400

        # Construct safe path using validated filename
        # CodeQL: sanitized_filename is guaranteed safe by validate_filename_for_api()
        script_path = safe_path_join(CONFIG_DIR, sanitized_filename)
        if script_path is None:
            return jsonify({"error": "Invalid path"}), 400

        if not script_path.exists() or not script_path.suffix == ".py":
            return jsonify({"error": "Script not found"}), 404

        # Check if this script is the active one
        active_path = BOOTSTRAP_SCRIPT
        is_active = False
        if active_path.exists():
            try:
                if active_path.is_symlink():
                    is_active = script_path.resolve() == active_path.resolve()
                else:
                    is_active = script_path.name == active_path.name
            except Exception:
                is_active = script_path.name == active_path.name

        # lgtm[py/path-injection]
        # CodeQL: script_path is validated via safe_path_join() above, ensuring it's within CONFIG_DIR
        return jsonify(
            {
                "name": sanitized_filename,
                "content": script_path.read_text(),
                "path": str(script_path),
                "active": is_active,
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/bootstrap-script/<filename>/set-active", methods=["POST"])
@require_auth
def set_active_script(filename):
    """Set a bootstrap script as active"""
    try:
        # Validate filename to prevent path traversal
        is_valid, sanitized_filename = validate_filename_for_api(filename)
        if not is_valid:
            return jsonify({"error": "Invalid filename"}), 400

        # Construct safe path
        script_path = safe_path_join(CONFIG_DIR, sanitized_filename)
        if script_path is None:
            return jsonify({"error": "Invalid path"}), 400

        if not script_path.exists() or not script_path.suffix == ".py":
            return jsonify({"error": "Script not found"}), 404

        # Special case: if setting bootstrap.py as active, ensure it's a regular file
        if sanitized_filename == "bootstrap.py":
            target = BOOTSTRAP_SCRIPT

            # If bootstrap.py doesn't exist, we need to find what it should point to
            # or create it from another file. But if the user is clicking on bootstrap.py,
            # it should exist (either as file or symlink)
            if not script_path.exists():
                return (
                    jsonify(
                        {
                            "error": "bootstrap.py not found. Please set another script as active first."
                        }
                    ),
                    404,
                )

            # Resolve the source file path before potentially removing the symlink
            source_file = script_path
            if script_path.is_symlink():
                try:
                    # Get the actual target file that the symlink points to
                    source_file = script_path.resolve()
                    if not source_file.exists():
                        return jsonify({"error": f"Symlink target not found: {source_file}"}), 404
                except (OSError, RuntimeError) as e:
                    return jsonify({"error": f"Cannot resolve symlink: {str(e)}"}), 500

            # If bootstrap.py is a symlink, remove it first
            if target.exists() and target.is_symlink():
                try:
                    target.unlink()
                except (OSError, RuntimeError):
                    pass

            # Copy the source file to bootstrap.py
            import shutil

            try:
                shutil.copy2(source_file, target)
            except (OSError, shutil.Error) as e:
                return jsonify({"error": f"Failed to copy file: {str(e)}"}), 500

            return jsonify(
                {
                    "success": True,
                    "message": "bootstrap.py is now the active bootstrap script",
                    "active": "bootstrap.py",
                }
            )

        # For other scripts, create symlink to bootstrap.py
        target = BOOTSTRAP_SCRIPT
        if target.exists() and target.is_symlink():
            target.unlink()
        elif target.exists():
            # Backup existing bootstrap.py
            # lgtm[py/path-injection]
            backup = CONFIG_DIR / f"bootstrap_backup_{int(target.stat().st_mtime)}.py"
            target.rename(backup)
            # Clean up old backups, keeping only the 5 most recent
            cleanup_old_backups()

        # Create symlink to the selected script
        target.symlink_to(script_path.name)

        return jsonify(
            {
                "success": True,
                "message": f"{sanitized_filename} is now the active bootstrap script",
                "active": sanitized_filename,
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/bootstrap-script/<filename>/rename", methods=["POST"])
@require_auth
def rename_bootstrap_script(filename):
    """Rename a bootstrap script"""
    try:
        # Validate filename to prevent path traversal
        is_valid, sanitized_filename = validate_filename_for_api(filename)
        if not is_valid:
            return jsonify({"error": "Invalid filename"}), 400

        # Construct safe path
        script_path = safe_path_join(CONFIG_DIR, sanitized_filename)
        if script_path is None:
            return jsonify({"error": "Invalid path"}), 400

        if not script_path.exists() or not script_path.suffix == ".py":
            return jsonify({"error": "Script not found"}), 404

        data = request.get_json()
        new_name = data.get("new_name", "").strip()

        if not new_name:
            return jsonify({"error": "New name is required"}), 400

        # Sanitize and validate new name
        sanitized_new_name = sanitize_filename(new_name)
        if not sanitized_new_name:
            # If sanitization fails, try to fix it
            if not new_name.endswith(".py"):
                return jsonify({"error": "New name must end with .py"}), 400
            if not new_name.startswith("bootstrap"):
                new_name = f"bootstrap_{new_name}"
            sanitized_new_name = sanitize_filename(new_name)
            if not sanitized_new_name:
                return jsonify({"error": "Invalid new filename format"}), 400

        new_name = sanitized_new_name

        # Check if new name already exists
        new_path = safe_path_join(CONFIG_DIR, new_name)
        if new_path is None:
            return jsonify({"error": "Invalid new filename"}), 400
        if new_path.exists() and new_path != script_path:
            return jsonify({"error": f"A script with the name {new_name} already exists"}), 400

        # Prevent renaming the active script (bootstrap.py)
        active_path = BOOTSTRAP_SCRIPT
        if active_path.exists():
            try:
                if active_path.is_symlink():
                    resolved = active_path.resolve()
                    if resolved == script_path.resolve():
                        return (
                            jsonify(
                                {
                                    "error": "Cannot rename the active script. Set another script as active first."
                                }
                            ),
                            400,
                        )
                elif active_path.resolve() == script_path.resolve():
                    return (
                        jsonify(
                            {
                                "error": "Cannot rename bootstrap.py when it is the active script. Set another script as active first."
                            }
                        ),
                        400,
                    )
            except (OSError, RuntimeError):
                pass

        # Rename the file
        # CodeQL: Both script_path and new_path are validated via safe_path_join() above
        try:
            script_path.rename(new_path)

            # Update metadata if it exists
            metadata = load_scripts_metadata()
            if sanitized_filename in metadata:
                metadata[new_name] = metadata.pop(sanitized_filename)
                save_scripts_metadata(metadata)

            # Log security event
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_rename",
                "success",
                client_ip,
                f"old_name={sanitized_filename} new_name={new_name}",
            )

            return jsonify(
                {
                    "success": True,
                    "message": f"Script renamed from {sanitized_filename} to {new_name}",
                    "old_name": sanitized_filename,
                    "new_name": new_name,
                }
            )
        except OSError as e:
            # Log failure
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_rename",
                "failure",
                client_ip,
                f"old_name={sanitized_filename} new_name={new_name} reason=filesystem_error",
            )
            return jsonify({"error": f"Failed to rename file: {str(e)}"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/bootstrap-script/<filename>", methods=["DELETE"])
@require_auth
def delete_bootstrap_script(filename):
    """Delete a bootstrap script"""
    try:
        # Validate filename to prevent path traversal
        is_valid, sanitized_filename = validate_filename_for_api(filename)
        if not is_valid:
            return jsonify({"error": "Invalid filename"}), 400

        # Construct safe path
        script_path = safe_path_join(CONFIG_DIR, sanitized_filename)
        if script_path is None:
            return jsonify({"error": "Invalid path"}), 400

        if not script_path.exists() or not script_path.suffix == ".py":
            return jsonify({"error": "Script not found"}), 404

        # Prevent deleting bootstrap.py if it's the active script (not a symlink)
        if sanitized_filename == "bootstrap.py":
            target = BOOTSTRAP_SCRIPT
            if target.exists() and not target.is_symlink():
                return (
                    jsonify(
                        {
                            "error": "Cannot delete bootstrap.py when it is the active script. Set another script as active first."
                        }
                    ),
                    400,
                )

        # Check if this script is currently active
        active_path = BOOTSTRAP_SCRIPT
        if active_path.exists():
            try:
                if active_path.is_symlink():
                    resolved = active_path.resolve()
                    if resolved == script_path.resolve():
                        return (
                            jsonify(
                                {
                                    "error": "Cannot delete the active script. Set another script as active first."
                                }
                            ),
                            400,
                        )
                elif active_path.resolve() == script_path.resolve():
                    return (
                        jsonify(
                            {
                                "error": "Cannot delete the active script. Set another script as active first."
                            }
                        ),
                        400,
                    )
            except (OSError, RuntimeError):
                pass

        # Delete the file
        try:
            script_path.unlink()

            # Log security event
            client_ip = request.remote_addr or "unknown"
            log_security_event("file_delete", "success", client_ip, f"filename={filename}")
        except OSError as e:
            # Log failure
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_delete", "failure", client_ip, f"filename={filename} reason=filesystem_error"
            )
            return jsonify({"error": f"Failed to delete file: {str(e)}"}), 500

        return jsonify({"success": True, "message": f"Script {filename} deleted successfully"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/bootstrap-scripts/backups")
def list_backup_scripts():
    """List backup bootstrap scripts"""
    backups = []
    script_dir = CONFIG_DIR

    for file in script_dir.glob("bootstrap_backup_*.py"):
        try:
            stat = file.stat()
            # Extract timestamp from filename (bootstrap_backup_TIMESTAMP.py)
            timestamp_str = file.stem.replace("bootstrap_backup_", "")
            try:
                timestamp = int(timestamp_str)
                from datetime import datetime

                dt = datetime.fromtimestamp(timestamp)
                human_date = dt.strftime("%Y-%m-%d %H:%M:%S")
            except (ValueError, OSError):
                # Fallback to file modification time
                from datetime import datetime

                dt = datetime.fromtimestamp(stat.st_mtime)
                human_date = dt.strftime("%Y-%m-%d %H:%M:%S")

            backups.append(
                {
                    "name": file.name,
                    "path": str(file),
                    "size": stat.st_size,
                    "modified": stat.st_mtime,
                    "human_date": human_date,
                    "timestamp": timestamp if "timestamp" in locals() else int(stat.st_mtime),
                }
            )
        except OSError:
            continue

    # Sort by timestamp (newest first)
    backups.sort(key=lambda x: x["timestamp"], reverse=True)

    return jsonify({"backups": backups})


@app.route("/api/bootstrap-script/backup/<filename>/restore", methods=["POST"])
@require_auth
def restore_backup_script(filename):
    """Restore a backup script"""
    try:
        # Validate filename is a backup
        if not filename.startswith("bootstrap_backup_") or not filename.endswith(".py"):
            return jsonify({"error": "Invalid backup filename"}), 400

        # Sanitize filename to prevent path traversal
        sanitized_filename = sanitize_filename(filename)
        if not sanitized_filename:
            return jsonify({"error": "Invalid backup filename"}), 400

        # Construct safe path
        backup_path = safe_path_join(CONFIG_DIR, sanitized_filename)
        if backup_path is None:
            return jsonify({"error": "Invalid path"}), 400
        if not backup_path.exists():
            return jsonify({"error": "Backup not found"}), 404

        # Get restore option from request
        data = request.get_json() or {}
        restore_as = data.get("restore_as", "new")  # 'new' or 'active'

        if restore_as == "active":
            # Restore as bootstrap.py (active)
            target = BOOTSTRAP_SCRIPT
            import shutil

            shutil.copy2(backup_path, target)
            return jsonify(
                {
                    "success": True,
                    "message": f"Backup {filename} restored as bootstrap.py (active)",
                    "restored_as": "active",
                }
            )
        else:
            # Restore as a new script with a cleaned name
            # Extract original name or create a new one
            from datetime import datetime

            timestamp_str = filename.replace("bootstrap_backup_", "").replace(".py", "")
            try:
                timestamp = int(timestamp_str)
                dt = datetime.fromtimestamp(timestamp)
                new_name = f"bootstrap_restored_{dt.strftime('%Y%m%d_%H%M%S')}.py"
            except Exception:
                new_name = f"bootstrap_restored_{int(time.time())}.py"

            new_path = safe_path_join(CONFIG_DIR, new_name)
            if new_path is None:
                return jsonify({"error": "Invalid restored filename"}), 400
            import shutil

            shutil.copy2(backup_path, new_path)
            return jsonify(
                {
                    "success": True,
                    "message": f"Backup {filename} restored as {new_name}",
                    "restored_as": "new",
                    "new_filename": new_name,
                }
            )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/bootstrap-script/upload", methods=["POST"])
@require_auth
def upload_bootstrap_script():
    """Upload a new bootstrap script"""
    try:
        if "file" not in request.files:
            return jsonify({"error": "No file provided"}), 400

        file = request.files["file"]
        if file.filename == "":
            return jsonify({"error": "No file selected"}), 400

        if not file.filename.endswith(".py"):
            return jsonify({"error": "File must be a Python script (.py)"}), 400

        # Sanitize and validate filename
        original_filename = file.filename
        if not original_filename:
            return jsonify({"error": "Invalid filename"}), 400

        # Sanitize filename to prevent path traversal
        filename = sanitize_filename(original_filename)
        if not filename:
            # Try to fix common cases
            if not original_filename.startswith("bootstrap"):
                original_filename = f"bootstrap_{original_filename}"
            filename = sanitize_filename(original_filename)
            if not filename:
                return (
                    jsonify(
                        {
                            "error": "Invalid filename format. Must be a valid Python filename starting with bootstrap"
                        }
                    ),
                    400,
                )

        # Construct safe path
        file_path = safe_path_join(CONFIG_DIR, filename)
        if file_path is None:
            return jsonify({"error": "Invalid file path"}), 400

        # Validate file content (Python source, not binary)
        content_valid, content_error = validate_python_file_content(file)
        if not content_valid:
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_upload", "failure", client_ip, f"filename={filename} reason={content_error}"
            )
            return jsonify({"error": content_error}), 400

        # Try to save with proper error handling
        try:
            # Get file size from the file object before saving (avoids path injection)
            # Flask file objects have content_length, or we can read the stream
            file_size = None
            if hasattr(file, "content_length") and file.content_length:
                file_size = file.content_length
            else:
                # Fallback: read stream to get size
                file.seek(0, 2)  # Seek to end
                file_size = file.tell()
                file.seek(0)  # Reset to beginning for save

            file.save(str(file_path))
            # Set permissions - try with subprocess if direct chmod fails
            try:
                file_path.chmod(0o644)
            except PermissionError:
                # Try using chmod command
                subprocess.run(["chmod", "644", str(file_path)], check=False)

            # Log security event
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_upload", "success", client_ip, f"filename={filename} size={file_size}"
            )
        except PermissionError as e:
            # Log failure
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_upload", "failure", client_ip, f"filename={filename} reason=permission_denied"
            )
            return (
                jsonify(
                    {"error": f"Permission denied: {str(e)}. Directory may need write permissions."}
                ),
                500,
            )
        except OSError as e:
            # Log failure
            client_ip = request.remote_addr or "unknown"
            log_security_event(
                "file_upload", "failure", client_ip, f"filename={filename} reason=filesystem_error"
            )
            return jsonify({"error": f"File system error: {str(e)}"}), 500

        return jsonify(
            {
                "success": True,
                "message": f"Script {filename} uploaded successfully",
                "filename": filename,
                "path": str(file_path),
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/status")
def get_status():
    """Get service status"""
    try:
        # Check if pod service is running
        # Since we're in a container, systemctl may not work, so we use the health endpoint as primary method
        container_running = False
        health_ok = False

        # Primary method: Check if we can reach nginx health endpoint (indicates service is running)
        # This is the most reliable method when systemctl is not available in containers
        try:
            import urllib.request

            response = urllib.request.urlopen("http://127.0.0.1/health", timeout=2)
            status_code = response.getcode()
            if status_code == 200:
                container_running = True
                # Also check the response body for health status
                health_body = response.read().decode().strip()
                health_ok = health_body == "healthy"
        except Exception:
            # Health endpoint not reachable - try systemctl as fallback
            try:
                result = subprocess.run(
                    ["systemctl", "is-active", "--quiet", "ztpbootstrap-pod.service"],
                    capture_output=True,
                    text=True,
                    timeout=2,
                )
                if result.returncode == 0:
                    container_running = True
                    # If systemctl says it's running, assume health is ok
                    health_ok = True
            except Exception:
                pass

        return jsonify(
            {
                "container_running": container_running,
                "health_ok": health_ok,
                "config_exists": CONFIG_FILE.exists(),
                "bootstrap_script_exists": BOOTSTRAP_SCRIPT.exists(),
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def load_device_connections():
    """Load device connection data from JSON file"""
    if DEVICE_CONNECTIONS_FILE.exists():
        try:
            with open(DEVICE_CONNECTIONS_FILE, "r") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_device_connections(connections):
    """Save device connection data to JSON file"""
    try:
        with open(DEVICE_CONNECTIONS_FILE, "w") as f:
            json.dump(connections, f, indent=2)
        return True
    except Exception as e:
        print(f"Error saving device connections: {e}")
        return False


def parse_nginx_access_log():
    """Parse nginx access log to track device connections"""
    connections = load_device_connections()
    current_time = time.time()

    # Track which log lines we've already processed
    # Only track processed lines for the last 24 hours to allow re-processing if filtering logic changes
    processed_lines_file = CONFIG_DIR / "processed_log_lines.txt"
    processed_lines = set()
    if processed_lines_file.exists():
        try:
            with open(processed_lines_file, "r") as f:
                all_processed = [line.strip() for line in f if line.strip()]
                # Only keep lines from the last 24 hours (approximate - check timestamp in log line)
                cutoff_time = current_time - 86400  # 24 hours
                for line in all_processed:
                    # Try to extract timestamp from log line to determine if it's recent
                    # Format: IP - - [timestamp] ...
                    match = re.match(r"^[^-]+ - - \[([^\]]+)\]", line)
                    if match:
                        try:
                            timestamp_str = match.group(1)
                            dt = datetime.strptime(timestamp_str.split()[0], "%d/%b/%Y:%H:%M:%S")
                            line_timestamp = dt.timestamp()
                            if line_timestamp > cutoff_time:
                                processed_lines.add(line)
                        except Exception:
                            # If we can't parse timestamp, keep the line (conservative approach)
                            processed_lines.add(line)
                    else:
                        # If it doesn't match log format, it might be a MARK line, keep it
                        processed_lines.add(line)
        except Exception:
            pass

    # Nginx log format: IP - - [timestamp] "method path protocol" status size "referer" "user-agent"
    # Example: 10.0.2.15 - - [08/Nov/2025:12:00:00 +0000] "GET /bootstrap.py HTTP/1.1" 200 1234 "-" "Arista-ZTP/1.0"

    if not NGINX_ACCESS_LOG.exists():
        return connections

    try:
        # Read last 1000 lines to avoid processing too much
        with open(NGINX_ACCESS_LOG, "r") as f:
            lines = f.readlines()
            recent_lines = lines[-1000:] if len(lines) > 1000 else lines

        new_processed_lines = set()
        for line in recent_lines:
            line_stripped = line.strip()
            # Skip if we've already processed this line
            if line_stripped in processed_lines:
                new_processed_lines.add(line_stripped)
                continue

            # Parse log line
            # Match: IP - - [timestamp] "method path protocol" status size "referer" "user-agent"
            match = re.match(
                r'^(\S+) - - \[([^\]]+)\] "(\S+) (\S+) ([^"]+)" (\d+) (\S+) "([^"]*)" "([^"]*)"',
                line,
            )
            if not match:
                new_processed_lines.add(line_stripped)
                continue

            ip = match.group(1)
            timestamp_str = match.group(2)
            path = match.group(4)
            status = int(match.group(6))
            user_agent = match.group(9)

            # Skip health checks, UI requests, and API requests (WebUI's own requests)
            # Note: We allow browser downloads of /bootstrap.py and / (root, which serves bootstrap.py) to be tracked (for testing purposes)
            # but filter out other browser requests (UI, API, etc.)
            # Also allow Arista device user agents (Arista-EOS, Arista-ZTP, etc.) to be tracked
            is_browser = user_agent and (
                "Mozilla" in user_agent
                or "Gecko" in user_agent
                or "Chrome" in user_agent
                or "Safari" in user_agent
            )
            is_arista_device = user_agent and (
                "Arista" in user_agent or "EOS" in user_agent or "ZTP" in user_agent
            )
            is_bootstrap_path = path == "/bootstrap.py" or path == "/"

            # Filter out if:
            # 1. It's a health/UI/API path (except bootstrap paths)
            # 2. It's a browser request to a non-bootstrap path
            # But always allow Arista device requests and bootstrap path requests
            if (
                not is_arista_device
                and not is_bootstrap_path
                and (
                    path in ["/health", "/ui", "/api"]
                    or path.startswith("/ui/")
                    or path.startswith("/api/")
                    or "/api/" in path
                    or (is_browser and not is_bootstrap_path)
                )
            ):
                # Mark as processed but don't count
                new_processed_lines.add(line_stripped)
                continue

            # Parse timestamp (format: 08/Nov/2025:12:00:00 +0000)
            try:
                dt = datetime.strptime(timestamp_str.split()[0], "%d/%b/%Y:%H:%M:%S")
                timestamp = dt.timestamp()
            except Exception:
                continue

            # Initialize device entry if not exists
            if ip not in connections:
                connections[ip] = {
                    "ip": ip,
                    "first_seen": timestamp,
                    "last_seen": timestamp,
                    "bootstrap_downloaded": False,
                    "bootstrap_download_time": None,
                    "session_start": timestamp,
                    "session_end": timestamp,
                    "total_requests": 0,
                    "user_agent": user_agent,
                    "sessions": [],
                }

            device = connections[ip]
            device["last_seen"] = timestamp
            device["total_requests"] = device.get("total_requests", 0) + 1

            # Track bootstrap.py downloads (both /bootstrap.py and / which serves bootstrap.py as index)
            if (path == "/bootstrap.py" or (path == "/" and status == 200)) and status == 200:
                device["bootstrap_downloaded"] = True
                if (
                    not device["bootstrap_download_time"]
                    or timestamp > device["bootstrap_download_time"]
                ):
                    device["bootstrap_download_time"] = timestamp

            # Track sessions (requests within 5 minutes are considered same session)
            if device["sessions"]:
                last_session = device["sessions"][-1]
                if timestamp - last_session["end"] < 300:  # 5 minutes
                    last_session["end"] = timestamp
                    last_session["requests"] += 1
                else:
                    # New session
                    device["sessions"].append({"start": timestamp, "end": timestamp, "requests": 1})
            else:
                device["sessions"].append({"start": timestamp, "end": timestamp, "requests": 1})

            # Keep only last 50 sessions per device
            if len(device["sessions"]) > 50:
                device["sessions"] = device["sessions"][-50:]

            # Mark this line as processed
            new_processed_lines.add(line_stripped)

        # Save processed lines (keep only last 2000 to avoid file growing too large)
        all_processed = processed_lines | new_processed_lines
        if len(all_processed) > 2000:
            # Keep only the most recent 2000
            all_processed = set(list(all_processed)[-2000:])

        try:
            with open(processed_lines_file, "w") as f:
                for line in sorted(all_processed):
                    f.write(line + "\n")
        except Exception as e:
            print(f"Error saving processed lines: {e}")

        # Clean up old devices (not seen in 24 hours)
        cutoff_time = current_time - 86400  # 24 hours
        connections = {
            ip: data for ip, data in connections.items() if data["last_seen"] > cutoff_time
        }

        save_device_connections(connections)
        return connections
    except Exception as e:
        print(f"Error parsing nginx log: {e}")
        return connections


@app.route("/api/logs")
def get_logs():
    """Get recent logs from specified source"""
    try:
        log_source = request.args.get("source", "nginx_access")
        lines = int(request.args.get("lines", 100))

        logs = []

        if log_source == "nginx_access":
            # Try multiple paths - works with both host networking and macvlan
            # The logs are mounted as a volume, so we should be able to read them directly
            log_paths = [
                Path("/var/log/nginx/ztpbootstrap_access.log"),  # Mounted volume path
                CONFIG_DIR / "logs" / "ztpbootstrap_access.log",  # Alternative path
            ]

            log_found = False
            for log_path in log_paths:
                if log_path.exists():
                    try:
                        with open(log_path, "r") as f:
                            all_lines = f.readlines()
                            recent_lines = (
                                all_lines[-lines:] if len(all_lines) > lines else all_lines
                            )
                            # Filter out UI/API requests to reduce noise
                            filtered_lines = []
                            for line in recent_lines:
                                # Skip UI and API requests (they're not interesting for device tracking)
                                if (
                                    "/ui/" not in line
                                    and "/api/" not in line
                                    and " /ui " not in line
                                    and " /api " not in line
                                ):
                                    filtered_lines.append(line)
                            logs = (
                                "".join(filtered_lines)
                                if filtered_lines
                                else "No device requests found in recent log entries (UI/API requests filtered out)"
                            )
                            log_found = True
                            break
                    except Exception as e:
                        logs = f"Error reading nginx access log from {log_path}: {str(e)}"
                        log_found = True
                        break

            if not log_found:
                # Fallback: Try to read from nginx container via podman exec
                # This works regardless of networking mode if podman is accessible
                try:
                    result = subprocess.run(
                        [
                            "podman",
                            "exec",
                            "ztpbootstrap-nginx",
                            "tail",
                            "-n",
                            str(lines),
                            "/var/log/nginx/ztpbootstrap_access.log",
                        ],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    if result.returncode == 0 and result.stdout.strip():
                        # Filter out UI/API requests
                        all_lines = result.stdout.split("\n")
                        filtered_lines = [
                            line
                            for line in all_lines
                            if "/ui/" not in line
                            and "/api/" not in line
                            and " /ui " not in line
                            and " /api " not in line
                        ]
                        logs = (
                            "\n".join(filtered_lines)
                            if filtered_lines
                            else "No device requests found in recent log entries (UI/API requests filtered out)"
                        )
                    else:
                        logs = f"Nginx access log not found. Checked paths: {', '.join(str(p) for p in log_paths)}"
                except FileNotFoundError:
                    logs = f"Nginx access log not accessible. Podman not available. Checked paths: {', '.join(str(p) for p in log_paths)}"
                except Exception as e:
                    logs = f"Error accessing nginx access log: {str(e)}"

        elif log_source == "nginx_error":
            # Try multiple paths - works with both host networking and macvlan
            # The logs are mounted as a volume, so we should be able to read them directly
            log_paths = [
                Path("/var/log/nginx/ztpbootstrap_error.log"),  # Mounted volume path
                CONFIG_DIR / "logs" / "ztpbootstrap_error.log",  # Alternative path
            ]

            log_found = False
            for log_path in log_paths:
                if log_path.exists():
                    try:
                        with open(log_path, "r") as f:
                            all_lines = f.readlines()
                            recent_lines = (
                                all_lines[-lines:] if len(all_lines) > lines else all_lines
                            )
                            logs = "".join(recent_lines)
                            log_found = True
                            break
                    except Exception as e:
                        logs = f"Error reading nginx error log from {log_path}: {str(e)}"
                        log_found = True
                        break

            if not log_found:
                # Fallback: Try to read from nginx container via podman exec
                # This works regardless of networking mode if podman is accessible
                try:
                    result = subprocess.run(
                        [
                            "podman",
                            "exec",
                            "ztpbootstrap-nginx",
                            "tail",
                            "-n",
                            str(lines),
                            "/var/log/nginx/ztpbootstrap_error.log",
                        ],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    logs = (
                        result.stdout
                        if result.returncode == 0 and result.stdout.strip()
                        else f"Error: {result.stderr or 'No log content'}"
                    )
                except FileNotFoundError:
                    logs = f"Nginx error log not accessible. Podman not available. Checked paths: {', '.join(str(p) for p in log_paths)}"
                except Exception as e:
                    logs = f"Error accessing nginx error log: {str(e)}"

        elif log_source == "dhcp":
            # DHCP logs from Kea server
            # Try multiple sources: podman logs, Kea log file, journalctl
            logs = ""
            log_found = False
            try:
                # First try: podman logs (most reliable for container logs)
                # Try without sudo first (if running in container with podman socket access)
                try:
                    result = subprocess.run(
                        ["podman", "logs", "--tail", str(lines), "ztpbootstrap-dhcp"],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    if result.returncode == 0 and result.stdout:
                        # Filter out UI/API requests and format
                        all_lines = result.stdout.split("\n")
                        filtered_lines = []
                        for line in all_lines:
                            # Filter out control agent HTTP requests (UI/API)
                            if "HTTP" in line and ("GET" in line or "POST" in line):
                                continue
                            # Only include DHCP-related log entries
                            if any(
                                keyword in line
                                for keyword in [
                                    "DHCP",
                                    "LEASE",
                                    "Kea",
                                    "packet",
                                    "subnet",
                                    "lease",
                                ]
                            ):
                                filtered_lines.append(line)
                        logs = (
                            "\n".join(filtered_lines[-lines:])
                            if filtered_lines
                            else "No device requests found in recent log entries (UI/API requests filtered out)"
                        )
                        log_found = True
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    # Try with sudo as fallback
                    try:
                        result = subprocess.run(
                            [
                                "sudo",
                                "podman",
                                "logs",
                                "--tail",
                                str(lines),
                                "ztpbootstrap-dhcp",
                            ],
                            capture_output=True,
                            text=True,
                            timeout=10,
                        )
                        if result.returncode == 0 and result.stdout:
                            all_lines = result.stdout.split("\n")
                            filtered_lines = []
                            for line in all_lines:
                                if "HTTP" in line and ("GET" in line or "POST" in line):
                                    continue
                                if any(
                                    keyword in line
                                    for keyword in [
                                        "DHCP",
                                        "LEASE",
                                        "Kea",
                                        "packet",
                                        "subnet",
                                        "lease",
                                    ]
                                ):
                                    filtered_lines.append(line)
                            logs = (
                                "\n".join(filtered_lines[-lines:])
                                if filtered_lines
                                else "No device requests found in recent log entries (UI/API requests filtered out)"
                            )
                            log_found = True
                    except Exception:
                        pass

                # Fallback: Try Kea log file if podman logs didn't work
                if not log_found:
                    log_paths = [
                        Path("/opt/containerdata/ztpbootstrap/dhcp/logs/kea.log"),
                        CONFIG_DIR / "dhcp" / "logs" / "kea.log",
                    ]
                    for log_path in log_paths:
                        if log_path.exists():
                            try:
                                with open(log_path, "r") as f:
                                    all_lines = f.readlines()
                                    recent_lines = (
                                        all_lines[-lines:] if len(all_lines) > lines else all_lines
                                    )
                                    # Parse and format Kea logs
                                    formatted_lines = []
                                    for line in recent_lines:
                                        # Kea logs are typically JSON or text format
                                        # Try to parse JSON first, fallback to text
                                        try:
                                            log_entry = json.loads(line.strip())
                                            # Format JSON log entry
                                            timestamp = log_entry.get("timestamp", "")
                                            level = log_entry.get("severity", "INFO")
                                            message = log_entry.get("message", "")
                                            # Extract relay agent info if present
                                            relay_info = ""
                                            if "relay" in log_entry:
                                                relay = log_entry["relay"]
                                                giaddr = relay.get("giaddr", "")
                                                if giaddr:
                                                    relay_info = f"[RELAY: {giaddr}] "
                                            formatted_lines.append(
                                                f"{timestamp} [{level}] {relay_info}{message}"
                                            )
                                        except (json.JSONDecodeError, ValueError):
                                            # Plain text log, use as-is
                                            formatted_lines.append(line.rstrip())
                                    logs = "\n".join(formatted_lines)
                                    log_found = True
                                    break
                            except Exception as e:
                                logs = f"Error reading DHCP log from {log_path}: {str(e)}"
                                log_found = True
                                break

                if not log_found:
                    # Fallback 2: Try journalctl for DHCP service (with sudo and journal path)
                    journal_paths = [
                        Path("/run/systemd/journal"),
                        Path("/run/log/journal"),
                        Path("/var/log/journal"),
                    ]
                    journal_accessible = False
                    journal_path = None
                    for jpath in journal_paths:
                        if jpath.exists():
                            try:
                                if os.access(jpath, os.R_OK):
                                    journal_accessible = True
                                    journal_path = jpath
                                    break
                            except Exception:
                                pass

                    if journal_accessible and journal_path:
                        try:
                            # Try with sudo first
                            result = subprocess.run(
                                [
                                    "sudo",
                                    "journalctl",
                                    "-D",
                                    str(journal_path),
                                    "--system",
                                    "-u",
                                    "ztpbootstrap-dhcp.service",
                                    "-n",
                                    str(lines),
                                    "--no-pager",
                                    "--no-hostname",
                                ],
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            if result.returncode == 0 and result.stdout.strip():
                                logs = result.stdout
                                log_found = True
                        except (FileNotFoundError, subprocess.TimeoutExpired):
                            pass
                        except Exception:
                            # Try without sudo
                            try:
                                result = subprocess.run(
                                    [
                                        "journalctl",
                                        "-D",
                                        str(journal_path),
                                        "--system",
                                        "-u",
                                        "ztpbootstrap-dhcp.service",
                                        "-n",
                                        str(lines),
                                        "--no-pager",
                                        "--no-hostname",
                                    ],
                                    capture_output=True,
                                    text=True,
                                    timeout=5,
                                )
                                if result.returncode == 0 and result.stdout.strip():
                                    logs = result.stdout
                                    log_found = True
                            except Exception:
                                pass
            except Exception as e:
                logs = f"Error accessing DHCP logs: {str(e)}"
                log_found = False

            if not log_found:
                logs = "DHCP logs not found. DHCP server may not be running or logs not configured."

        # Handle container logs (default) - only if not nginx_access, nginx_error, or dhcp
        if log_source not in ["nginx_access", "nginx_error", "dhcp"]:
            # Helper function to check if a systemd service exists
            # Note: systemctl may not be available in containers, so we try multiple methods
            def check_service_exists(service_name):
                """Check if a systemd service exists and is available"""
                # First check if systemctl is available
                try:
                    subprocess.run(
                        ["systemctl", "--version"], capture_output=True, timeout=1, check=False
                    )
                    systemctl_available = True
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    systemctl_available = False

                if systemctl_available:
                    try:
                        # Use list-unit-files and grep for the service name
                        result = subprocess.run(
                            ["systemctl", "list-unit-files", "--type=service", "--no-legend"],
                            capture_output=True,
                            text=True,
                            timeout=2,
                        )
                        if result.returncode == 0:
                            # Check if service name appears in the output
                            for line in result.stdout.split("\n"):
                                if line.strip().startswith(service_name):
                                    return True
                        # Fallback: try is-active (returns 0 for active, 3 for inactive, 1 for not found)
                        result2 = subprocess.run(
                            ["systemctl", "is-active", service_name],
                            capture_output=True,
                            text=True,
                            timeout=2,
                        )
                        # is-active returns 0 for active, 3 for inactive, 1 for not found
                        # So return code 0 or 3 means service exists
                        if result2.returncode == 0 or result2.returncode == 3:
                            return True
                    except Exception as e:
                        # Log error for debugging but don't fail
                        print(
                            f"Error checking service {service_name} with systemctl: {e}", flush=True
                        )

                # If systemctl not available, try to verify via journalctl
                # If we can query the journal for this service, it exists
                try:
                    journalctl_path = Path("/usr/bin/journalctl")
                    if journalctl_path.exists() and os.access(journalctl_path, os.X_OK):
                        result = subprocess.run(
                            ["journalctl", "-u", service_name, "-n", "1", "--no-pager"],
                            capture_output=True,
                            text=True,
                            timeout=2,
                        )
                        # If journalctl returns 0 or can query it, service likely exists
                        # Return code 1 might mean no logs yet, but service could still exist
                        if result.returncode == 0:
                            return True
                        # If stderr says "No entries" that means service exists but no logs
                        if result.returncode == 1 and "no entries" in result.stderr.lower():
                            return True
                except Exception:
                    pass

                return False

            # Check which services exist (pod-based deployment)
            pod_service_exists = check_service_exists("ztpbootstrap-pod.service")
            nginx_service_exists = check_service_exists("ztpbootstrap-nginx.service")
            webui_service_exists = check_service_exists("ztpbootstrap-webui.service")

            # Build container mappings (pod-based setup)
            containers = {}
            # Pod service itself doesn't have a direct container, but we can get its logs via journalctl
            if nginx_service_exists:
                containers["ztpbootstrap-nginx.service"] = "ztpbootstrap-nginx"
            else:
                # Try anyway - container might exist even if service detection failed
                containers["ztpbootstrap-nginx.service"] = "ztpbootstrap-nginx"
            if webui_service_exists:
                containers["ztpbootstrap-webui.service"] = "ztpbootstrap-webui"
            else:
                # Try anyway - container might exist even if service detection failed
                containers["ztpbootstrap-webui.service"] = "ztpbootstrap-webui"
            # Optionally include pod service for pod lifecycle logs
            if pod_service_exists:
                containers["ztpbootstrap-pod.service"] = None  # Pod itself, no direct container

            # If no containers detected, use default mappings
            if not containers:
                containers = {
                    "ztpbootstrap-pod.service": None,
                    "ztpbootstrap-nginx.service": "ztpbootstrap-nginx",
                    "ztpbootstrap-webui.service": "ztpbootstrap-webui",
                }

            # Check if podman binary is available and can actually execute
            podman_available = False
            podman_socket_accessible = False
            podman_binary_path = Path("/usr/bin/podman")
            if podman_binary_path.exists() and os.access(podman_binary_path, os.X_OK):
                # Actually try to execute it to see if it works (might fail due to missing libraries)
                try:
                    # Set LD_LIBRARY_PATH to help find libraries
                    env = os.environ.copy()
                    env["LD_LIBRARY_PATH"] = "/lib64:/usr/lib64:/usr/lib64/systemd"
                    podman_check = subprocess.run(
                        ["/usr/bin/podman", "--version"],
                        capture_output=True,
                        text=True,
                        timeout=2,
                        env=env,
                    )
                    podman_available = podman_check.returncode == 0
                except Exception:
                    # Try without LD_LIBRARY_PATH
                    try:
                        podman_check = subprocess.run(
                            ["/usr/bin/podman", "--version"],
                            capture_output=True,
                            text=True,
                            timeout=2,
                        )
                        podman_available = podman_check.returncode == 0
                    except Exception:
                        pass
            else:
                # Fallback: try to run podman to see if it's in PATH
                try:
                    podman_check = subprocess.run(
                        ["podman", "--version"], capture_output=True, text=True, timeout=1
                    )
                    podman_available = podman_check.returncode == 0
                except Exception:
                    pass

            # Check podman socket accessibility
            # Try multiple possible socket locations
            socket_paths = [
                Path("/run/podman/podman.sock"),
                Path("/run/user/0/podman/podman.sock"),
                Path("/var/run/podman/podman.sock"),
            ]
            podman_socket_accessible = False
            for socket_path in socket_paths:
                if socket_path.exists():
                    try:
                        if os.access(socket_path, os.R_OK):
                            podman_socket_accessible = True
                            break
                    except Exception:
                        pass

            # Also try to test podman connectivity directly
            if podman_available and not podman_socket_accessible:
                try:
                    # Try a simple podman command to see if it can connect
                    test_result = subprocess.run(
                        ["podman", "ps", "--format", "{{.Names}}"],
                        capture_output=True,
                        text=True,
                        timeout=2,
                    )
                    if test_result.returncode == 0:
                        podman_socket_accessible = True
                except Exception:
                    pass

            # Check journalctl availability and ability to actually execute
            journalctl_available = False
            journal_accessible = False
            journalctl_binary_path = Path("/usr/bin/journalctl")
            if journalctl_binary_path.exists() and os.access(journalctl_binary_path, os.X_OK):
                # Actually try to execute it to see if it works (might fail due to missing libraries)
                try:
                    # Set LD_LIBRARY_PATH to help find systemd libraries
                    env = os.environ.copy()
                    env["LD_LIBRARY_PATH"] = "/lib64:/usr/lib64:/usr/lib64/systemd"
                    journalctl_check = subprocess.run(
                        ["/usr/bin/journalctl", "--version"],
                        capture_output=True,
                        text=True,
                        timeout=2,
                        env=env,
                    )
                    journalctl_available = journalctl_check.returncode == 0
                except Exception:
                    # Try without LD_LIBRARY_PATH
                    try:
                        journalctl_check = subprocess.run(
                            ["/usr/bin/journalctl", "--version"],
                            capture_output=True,
                            text=True,
                            timeout=2,
                        )
                        journalctl_available = journalctl_check.returncode == 0
                    except Exception:
                        pass
            else:
                # Fallback: try to run journalctl to see if it's in PATH
                try:
                    journalctl_check = subprocess.run(
                        ["journalctl", "--version"], capture_output=True, text=True, timeout=1
                    )
                    journalctl_available = journalctl_check.returncode == 0
                except Exception:
                    pass

            # Check journal directory accessibility
            journal_paths = [
                Path("/run/systemd/journal"),
                Path("/run/log/journal"),
                Path("/var/log/journal"),
            ]
            for journal_path in journal_paths:
                if journal_path.exists():
                    try:
                        if os.access(journal_path, os.R_OK):
                            journal_accessible = True
                            break
                    except Exception:
                        pass

            # Collect diagnostic information
            diagnostics = []
            diagnostics.append("Deployment mode: Pod-based")
            diagnostics.append(f"Services detected: {', '.join(containers.keys())}")
            diagnostics.append(
                f"Podman binary exists: {podman_binary_path.exists() if 'podman_binary_path' in locals() else 'Unknown'}"
            )
            diagnostics.append(f"Podman executable: {podman_available}")
            diagnostics.append(f"Podman socket accessible: {podman_socket_accessible}")
            diagnostics.append(
                f"Journalctl binary exists: {journalctl_binary_path.exists() if 'journalctl_binary_path' in locals() else 'Unknown'}"
            )
            diagnostics.append(f"Journalctl executable: {journalctl_available}")
            diagnostics.append(f"Journal accessible: {journal_accessible}")
            diagnostics.append(
                "Note: Container uses Fedora-based image with podman and journalctl installed via dnf."
            )

            # Try to get container logs using multiple methods
            log_parts = []
            logs_retrieved = False

            for service, container_name in containers.items():
                log_parts.append(f"=== {service} ===")
                container_logs = None
                method_used = None

                # Skip pod service if it has no direct container (we'll get its logs via journalctl only)
                if container_name is None:
                    # For pod service, only try journalctl
                    if journalctl_available:
                        try:
                            # Set LD_LIBRARY_PATH for journalctl execution
                            env = os.environ.copy()
                            env["LD_LIBRARY_PATH"] = "/lib64:/usr/lib64:/usr/lib64/systemd"
                            journal_result = subprocess.run(
                                [
                                    "/usr/bin/journalctl",
                                    "-D",
                                    "/var/log/journal",
                                    "--system",
                                    "-u",
                                    service,
                                    "-n",
                                    str(lines // max(len(containers), 1)),
                                    "--no-pager",
                                    "--no-hostname",
                                ],
                                capture_output=True,
                                text=True,
                                timeout=3,
                                env=env,
                            )
                            if journal_result.returncode == 0 and journal_result.stdout.strip():
                                # Filter out UI/API log requests to prevent recursive noise
                                raw_logs = journal_result.stdout.strip()
                                filtered_log_lines = []
                                for log_line in raw_logs.split("\n"):
                                    # Skip lines that contain API log requests (they create recursive noise)
                                    if (
                                        "/api/logs" not in log_line
                                        and "/api/device-connections" not in log_line
                                    ):
                                        filtered_log_lines.append(log_line)
                                container_logs = (
                                    "\n".join(filtered_log_lines)
                                    if filtered_log_lines
                                    else journal_result.stdout.strip()
                                )
                                method_used = "journalctl"
                        except Exception:
                            logging.exception(
                                f"Exception while retrieving logs via journalctl for {service}"
                            )
                            diagnostics.append(f"journalctl for {service} failed")
                    if container_logs:
                        log_parts.append(container_logs)
                        logs_retrieved = True
                    else:
                        log_parts.append("Pod service logs (lifecycle events only)")
                        log_parts.append("No recent pod lifecycle events.")
                    log_parts.append("")
                    continue

                # Method 1: Try podman logs (works if podman socket is accessible)
                if podman_available and podman_socket_accessible:
                    try:
                        # Set LD_LIBRARY_PATH for podman execution
                        env = os.environ.copy()
                        env["LD_LIBRARY_PATH"] = "/lib64:/usr/lib64:/usr/lib64/systemd"
                        result = subprocess.run(
                            [
                                "/usr/bin/podman",
                                "logs",
                                "--tail",
                                str(lines // max(len(containers), 1)),
                                container_name,
                            ],
                            capture_output=True,
                            text=True,
                            timeout=3,
                            env=env,
                        )
                        if result.returncode == 0 and result.stdout.strip():
                            # Filter out UI/API log requests to prevent recursive noise
                            raw_logs = result.stdout.strip()
                            filtered_log_lines = []
                            for log_line in raw_logs.split("\n"):
                                # Skip lines that contain API log requests (they create recursive noise)
                                if (
                                    "/api/logs" not in log_line
                                    and "/api/device-connections" not in log_line
                                ):
                                    filtered_log_lines.append(log_line)
                            container_logs = (
                                "\n".join(filtered_log_lines)
                                if filtered_log_lines
                                else result.stdout.strip()
                            )
                            method_used = "podman"
                        elif result.returncode != 0:
                            diagnostics.append(
                                f"podman logs {container_name} returned code {result.returncode}: {result.stderr}"
                            )
                    except FileNotFoundError:
                        diagnostics.append("podman binary not found")
                    except subprocess.TimeoutExpired:
                        diagnostics.append(f"podman logs {container_name} timed out")
                    except Exception as e:
                        diagnostics.append(f"podman logs {container_name} failed: {str(e)}")

                # Method 2: Try journalctl (works if journal is accessible)
                if not container_logs and journalctl_available:
                    try:
                        # Set LD_LIBRARY_PATH for journalctl execution
                        env = os.environ.copy()
                        env["LD_LIBRARY_PATH"] = "/lib64:/usr/lib64:/usr/lib64/systemd"
                        journal_result = subprocess.run(
                            [
                                "/usr/bin/journalctl",
                                "-D",
                                "/var/log/journal",
                                "--system",
                                "-u",
                                service,
                                "-n",
                                str(lines // max(len(containers), 1)),
                                "--no-pager",
                                "--no-hostname",
                            ],
                            capture_output=True,
                            text=True,
                            timeout=3,
                            env=env,
                        )
                        if journal_result.returncode == 0 and journal_result.stdout.strip():
                            # Filter out UI/API log requests to prevent recursive noise
                            raw_logs = journal_result.stdout.strip()
                            filtered_log_lines = []
                            for log_line in raw_logs.split("\n"):
                                # Skip lines that contain API log requests (they create recursive noise)
                                if (
                                    "/api/logs" not in log_line
                                    and "/api/device-connections" not in log_line
                                ):
                                    filtered_log_lines.append(log_line)
                            container_logs = (
                                "\n".join(filtered_log_lines)
                                if filtered_log_lines
                                else journal_result.stdout.strip()
                            )
                            method_used = "journalctl"
                        elif journal_result.returncode != 0:
                            diagnostics.append(
                                f"journalctl -u {service} returned code {journal_result.returncode}: {journal_result.stderr}"
                            )
                    except FileNotFoundError:
                        diagnostics.append("journalctl binary not found")
                    except subprocess.TimeoutExpired:
                        diagnostics.append(f"journalctl -u {service} timed out")
                    except Exception as e:
                        diagnostics.append(f"journalctl -u {service} failed: {str(e)}")

                if container_logs:
                    log_parts.append(container_logs)
                    if method_used:
                        log_parts.append(f"[Retrieved via {method_used}]")
                    logs_retrieved = True
                else:
                    log_parts.append(f"Container: {container_name or 'N/A'}")
                    log_parts.append("Logs not available from within container.")
                log_parts.append("")

            if log_parts:
                logs = "\n".join(log_parts)
                # Only show help message if no logs were retrieved
                if not logs_retrieved or "Logs not available from within container" in logs:
                    # Add diagnostic information
                    logs = "\n" + "=" * 70 + "\n"
                    logs += "CONTAINER LOGS ACCESS DIAGNOSTICS\n"
                    logs += "=" * 70 + "\n\n"

                    # Add diagnostics
                    if diagnostics:
                        logs += "Diagnostic Information:\n"
                        for diag in diagnostics:
                            logs += f"  - {diag}\n"
                        logs += "\n"

                    # Try to get hostname for better instructions
                    import socket

                    hostname = None
                    host_ip = None

                    # Try multiple methods to get host information
                    try:
                        # Try reading from /etc/hostname (if mounted)
                        hostname_file = Path("/etc/hostname")
                        if hostname_file.exists():
                            hostname = hostname_file.read_text().strip()
                    except Exception:
                        pass

                    if not hostname:
                        try:
                            hostname = socket.gethostname()
                            # If it's a pod/container name, try to get actual hostname
                            if "pod" in hostname.lower() or "container" in hostname.lower():
                                hostname = None
                        except Exception:
                            pass

                    # Try to get host IP from environment or network
                    try:
                        # Check if we can get host IP from hostname resolution
                        if hostname:
                            host_ip = socket.gethostbyname(hostname)
                    except Exception:
                        pass

                    # Build SSH instruction
                    if hostname and hostname not in ["ztpbootstrap", "localhost"]:
                        ssh_target = hostname
                        if host_ip:
                            ssh_instruction = f"  ssh user@{hostname}  # or ssh user@{host_ip}"
                        else:
                            ssh_instruction = f"  ssh user@{hostname}"
                    else:
                        ssh_target = "the host server"
                        ssh_instruction = (
                            "  ssh user@<hostname-or-ip>  # Replace with actual hostname or IP"
                        )

                    logs += (
                        "Container logs require host-level access to systemd journal and podman.\n"
                    )
                    logs += (
                        "To view container logs, you need to SSH to the host server where this\n"
                    )
                    logs += "service is running and execute the commands below.\n\n"
                    logs += f"SSH to {ssh_target}:\n"
                    logs += f"{ssh_instruction}\n\n"
                    logs += "Once connected, run one of these commands:\n\n"

                    # Build service-specific commands
                    logs += "Using journalctl (recommended):\n"
                    if pod_service_exists:
                        logs += "  sudo journalctl -u ztpbootstrap-pod.service -n 50 -f\n"
                    if nginx_service_exists:
                        logs += "  sudo journalctl -u ztpbootstrap-nginx.service -n 50 -f\n"
                    if webui_service_exists:
                        logs += "  sudo journalctl -u ztpbootstrap-webui.service -n 50 -f\n"
                    logs += "\n"

                    logs += "Or using podman logs:\n"
                    if nginx_service_exists:
                        logs += "  sudo podman logs ztpbootstrap-nginx --tail 50 -f\n"
                    if webui_service_exists:
                        logs += "  sudo podman logs ztpbootstrap-webui --tail 50 -f\n"
                    logs += "\n"

                    logs += "Note: The -f flag follows the logs in real-time. Remove it to see\n"
                    logs += "      only the last N lines without following.\n"
                    logs += "=" * 70 + "\n"

                    # Append the original log_parts if any
                    if log_parts and any("===" in part for part in log_parts):
                        logs += "\n" + "\n".join(log_parts)
            else:
                logs = "Container logs are not available from within the container."
                if diagnostics:
                    logs += "\n\nDiagnostic Information:\n"
                    for diag in diagnostics:
                        logs += f"  - {diag}\n"

        if not logs:
            logs = "No logs available"

        return jsonify({"logs": logs, "source": log_source})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/logs/mark", methods=["POST"])
@require_auth
def mark_logs():
    """Insert a MARK line into the nginx logs"""
    try:
        from datetime import datetime

        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
        mark_line = f"===== MARK: {timestamp} =====\n"

        # Get which log source to mark (default to both)
        log_source = request.args.get("source", "both")
        errors = []

        # Write MARK to nginx access log
        if log_source in ["both", "nginx_access", "access"]:
            if NGINX_ACCESS_LOG.exists():
                try:
                    with open(NGINX_ACCESS_LOG, "a") as f:
                        f.write(mark_line)
                except Exception as e:
                    errors.append(f"Failed to write MARK to access log: {str(e)}")
            else:
                # Try to write via podman exec using safer approach (Issue #3)
                # Use tee instead of shell echo to avoid command injection
                try:
                    result = subprocess.run(
                        [
                            "podman",
                            "exec",
                            "-i",
                            "ztpbootstrap-nginx",
                            "tee",
                            "-a",
                            "/var/log/nginx/ztpbootstrap_access.log",
                        ],
                        input=mark_line,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    if result.returncode != 0:
                        errors.append(f"Failed to write MARK to access log: {result.stderr}")
                except Exception as e:
                    errors.append(f"Failed to write MARK to access log: {str(e)}")

        # Write MARK to nginx error log
        if log_source in ["both", "nginx_error", "error"]:
            if NGINX_ERROR_LOG.exists():
                try:
                    with open(NGINX_ERROR_LOG, "a") as f:
                        f.write(mark_line)
                except Exception as e:
                    errors.append(f"Failed to write MARK to error log: {str(e)}")
            else:
                # Try to write via podman exec using safer approach (Issue #3)
                # Use tee instead of shell echo to avoid command injection
                try:
                    result = subprocess.run(
                        [
                            "podman",
                            "exec",
                            "-i",
                            "ztpbootstrap-nginx",
                            "tee",
                            "-a",
                            "/var/log/nginx/ztpbootstrap_error.log",
                        ],
                        input=mark_line,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    if result.returncode != 0:
                        errors.append(f"Failed to write MARK to error log: {result.stderr}")
                except Exception as e:
                    errors.append(f"Failed to write MARK to error log: {str(e)}")

        if errors:
            return jsonify({"error": "; ".join(errors)}), 500

        return jsonify(
            {"success": True, "message": f"MARK inserted at {timestamp}", "timestamp": timestamp}
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/device-connections")
def get_device_connections():
    """Get device connection data"""
    try:
        # Parse nginx logs to update connection data
        connections = parse_nginx_access_log()

        # Format for frontend
        devices = []
        for ip, data in connections.items():
            # Calculate session duration
            sessions = data.get("sessions", [])
            total_duration = sum(s["end"] - s["start"] for s in sessions)
            last_session_duration = sessions[-1]["end"] - sessions[-1]["start"] if sessions else 0

            devices.append(
                {
                    "ip": ip,
                    "first_seen": data["first_seen"],
                    "last_seen": data["last_seen"],
                    "bootstrap_downloaded": data.get("bootstrap_downloaded", False),
                    "bootstrap_download_time": data.get("bootstrap_download_time"),
                    "total_requests": data.get("total_requests", 0),
                    "total_sessions": len(sessions),
                    "total_duration": total_duration,
                    "last_session_duration": last_session_duration,
                    "user_agent": data.get("user_agent", "Unknown"),
                }
            )

        # Sort by last seen (most recent first)
        devices.sort(key=lambda x: x["last_seen"], reverse=True)

        return jsonify({"devices": devices})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ============================================================================
# DHCP API Endpoints
# ============================================================================


@app.route("/api/dhcp/config", methods=["GET"])
@require_auth
def get_dhcp_config():
    """Get current DHCP configuration"""
    try:
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, "r") as f:
                config = yaml.safe_load(f)
            dhcp_config = config.get("dhcp", {})
            return jsonify({"dhcp": dhcp_config})
        else:
            return jsonify({"error": "Config file not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/config", methods=["PUT"])
@require_auth
def update_dhcp_config():
    """Update DHCP configuration (Issue #1, #5, #7 fixed)"""
    try:
        data = request.get_json()
        if not data or "dhcp" not in data:
            return jsonify({"error": "Invalid request: dhcp config required"}), 400

        client_ip = request.remote_addr

        # Validate DHCP configuration (Issue #5, #7)
        if validate_dhcp_config:
            is_valid, error_msg = validate_dhcp_config(data["dhcp"])
            if not is_valid:
                log_security_event(
                    "dhcp_config_update", "failure", client_ip, f"validation_error={error_msg}"
                )
                return jsonify({"error": f"Invalid DHCP configuration: {error_msg}"}), 400

        # Use ConfigManager for thread-safe update (Issue #1)
        if config_manager:
            success, error_msg = config_manager.update_section("dhcp", data["dhcp"])
            if not success:
                log_security_event(
                    "dhcp_config_update", "failure", client_ip, f"update_error={error_msg}"
                )
                return jsonify({"error": f"Failed to update configuration: {error_msg}"}), 500

            # Read back the updated config
            config = config_manager.read_config()
        else:
            # Fallback to old method if ConfigManager not available
            if CONFIG_FILE.exists():
                with open(CONFIG_FILE, "r") as f:
                    config = yaml.safe_load(f)
            else:
                config = {}

            config["dhcp"] = data["dhcp"]

            with open(CONFIG_FILE, "w") as f:
                yaml.dump(config, f, default_flow_style=False, sort_keys=False)

        # Log successful update
        log_security_event("dhcp_config_update", "success", client_ip, "config_updated")

        # Generate Kea config files if DHCP is enabled
        if config.get("dhcp", {}).get("enabled", False):
            try:
                kea_config = generate_kea_config(config)
                # Write Kea config files
                dhcp_config_dir = CONFIG_DIR / "dhcp"
                dhcp_config_dir.mkdir(parents=True, exist_ok=True)

                if "Dhcp4" in kea_config:
                    dhcp4_file = dhcp_config_dir / "kea-dhcp4.conf"
                    # Validate JSON before writing
                    try:
                        config_json = {"Dhcp4": kea_config["Dhcp4"]}
                        # Test JSON serialization
                        json_str = json.dumps(config_json, indent=2)
                        # Validate it can be parsed back
                        json.loads(json_str)
                        # Write the validated JSON
                        with open(dhcp4_file, "w") as f:
                            f.write(json_str)
                    except (TypeError, ValueError) as e:
                        logger.error(f"Invalid JSON in DHCP4 config: {e}")
                        raise

                if "Dhcp6" in kea_config:
                    dhcp6_file = dhcp_config_dir / "kea-dhcp6.conf"
                    with open(dhcp6_file, "w") as f:
                        # Kea expects the config wrapped in a top-level "Dhcp6" key
                        json.dump({"Dhcp6": kea_config["Dhcp6"]}, f, indent=2)

                if "Control-agent" in kea_config:
                    ctrl_agent_file = dhcp_config_dir / "kea-ctrl-agent.conf"
                    with open(ctrl_agent_file, "w") as f:
                        # Kea expects the config wrapped in a top-level "Control-agent" key
                        json.dump({"Control-agent": kea_config["Control-agent"]}, f, indent=2)

                # Reload Kea config if container is running
                try:
                    reload_config("dhcp4")
                    reload_config("dhcp6")
                except Exception:
                    pass  # Kea may not be running yet
            except Exception as e:
                security_logger.warning(f"Failed to generate Kea config: {e}")

        return jsonify({"success": True, "dhcp": config.get("dhcp", {})})
    except Exception as e:
        log_security_event(
            "dhcp_config_update", "failure", request.remote_addr, f"exception={str(e)}"
        )
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/config/auto-detect", methods=["POST"])
@require_auth
def auto_detect_dhcp_config():
    """Auto-detect subnet and gateway"""
    try:
        data = request.get_json() or {}
        ipv4_address = data.get("ipv4_address")
        ipv6_address = data.get("ipv6_address")

        result = {}

        # Detect gateway
        gateway_info = detect_gateway(ipv4_address, ipv6_address)
        result["gateway"] = gateway_info

        # Detect subnet if IP provided
        if ipv4_address:
            subnet = detect_subnet(ipv4_address)
            result["ipv4_subnet"] = subnet
            # Calculate default range
            range_start, range_end = calculate_default_range(
                subnet, gateway_info.get("ipv4_gateway"), ipv4_address
            )
            result["ipv4_range"] = {"start": range_start, "end": range_end}

        if ipv6_address:
            subnet = detect_subnet(ipv6_address)
            result["ipv6_subnet"] = subnet
            # Calculate default range
            range_start, range_end = calculate_default_range(
                subnet, gateway_info.get("ipv6_gateway"), ipv6_address
            )
            result["ipv6_range"] = {"start": range_start, "end": range_end}

        # Detect networking mode
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, "r") as f:
                config = yaml.safe_load(f)
            networking_mode = detect_networking_mode(config)
            result["networking_mode"] = networking_mode

            # Detect interfaces if host networking
            if networking_mode == "host":
                interfaces = detect_host_interfaces()
                result["interfaces"] = interfaces

        return jsonify(result)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/status", methods=["GET"])
@require_auth
def get_dhcp_status():
    """Get DHCP service status (enabled/disabled, container status, networking mode)"""
    try:
        # Get config
        dhcp_enabled = False
        networking_mode = "unknown"
        port_conflicts = {"ipv4_conflict": False, "ipv6_conflict": False}

        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, "r") as f:
                config = yaml.safe_load(f)
            dhcp_config = config.get("dhcp", {})
            dhcp_enabled = dhcp_config.get("enabled", False)
            networking_mode = detect_networking_mode(config)

            # Check port conflicts
            port_conflicts = check_dhcp_port_conflicts()

        # Get container status
        container_status = check_dhcp_container_status()

        return jsonify(
            {
                "enabled": dhcp_enabled,
                "networking_mode": networking_mode,
                "port_conflicts": port_conflicts,
                "container": container_status,
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/enable", methods=["POST"])
@require_auth
def enable_dhcp():
    """Enable DHCP (creates container if needed) (Issue #1, #9 fixed)"""
    # Rate limiting: max 5 calls per minute (Issue #9)
    if rate_limiter:
        is_allowed, info = rate_limiter.check_rate_limit(max_calls=5, window=60)
        if not is_allowed:
            return (
                jsonify(
                    {
                        "error": "Rate limit exceeded. Please try again later.",
                        "code": "RATE_LIMIT_EXCEEDED",
                        "retry_after": info.get("retry_after", 60),
                    }
                ),
                429,
            )

    try:
        client_ip = request.remote_addr

        # Check for port conflicts (warning only, don't block)
        # In VM environments (like QEMU), other DHCP servers may be running
        # We'll attempt to start Kea anyway - it will fail with a clear error if it can't bind
        port_conflicts = check_dhcp_port_conflicts()

        # Load and update config using ConfigManager (Issue #1)
        if config_manager:
            config = config_manager.read_config()
            if "dhcp" not in config:
                config["dhcp"] = {}
            config["dhcp"]["enabled"] = True

            # Update just the dhcp section atomically
            success, error_msg = config_manager.update_section("dhcp", config["dhcp"])
            if not success:
                log_security_event(
                    "dhcp_enable", "failure", client_ip, f"config_update_error={error_msg}"
                )
                return jsonify({"error": f"Failed to update configuration: {error_msg}"}), 500
        else:
            # Fallback to old method
            if not CONFIG_FILE.exists():
                return jsonify({"error": "Config file not found"}), 404

            with open(CONFIG_FILE, "r") as f:
                config = yaml.safe_load(f)

            # Enable DHCP in config
            if "dhcp" not in config:
                config["dhcp"] = {}
            config["dhcp"]["enabled"] = True

            # Write config
            with open(CONFIG_FILE, "w") as f:
                yaml.dump(config, f, default_flow_style=False, sort_keys=False)

        # Generate Kea config
        kea_config = generate_kea_config(config)
        dhcp_config_dir = CONFIG_DIR / "dhcp"
        dhcp_config_dir.mkdir(parents=True, exist_ok=True)

        if "Dhcp4" in kea_config:
            dhcp4_file = dhcp_config_dir / "kea-dhcp4.conf"
            # Validate JSON before writing
            try:
                config_json = {"Dhcp4": kea_config["Dhcp4"]}
                # Test JSON serialization
                json_str = json.dumps(config_json, indent=2)
                # Validate it can be parsed back
                json.loads(json_str)
                # Write the validated JSON
                with open(dhcp4_file, "w") as f:
                    f.write(json_str)
            except (TypeError, ValueError) as e:
                logger.error(f"Invalid JSON in DHCP4 config: {e}")
                raise

        if "Dhcp6" in kea_config:
            dhcp6_file = dhcp_config_dir / "kea-dhcp6.conf"
            with open(dhcp6_file, "w") as f:
                # Kea expects the config wrapped in a top-level "Dhcp6" key
                json.dump({"Dhcp6": kea_config["Dhcp6"]}, f, indent=2)

        if "Control-agent" in kea_config:
            ctrl_agent_file = dhcp_config_dir / "kea-ctrl-agent.conf"
            with open(ctrl_agent_file, "w") as f:
                # Kea expects the config wrapped in a top-level "Control-agent" key
                json.dump({"Control-agent": kea_config["Control-agent"]}, f, indent=2)

        # Create container if needed
        container_status = check_dhcp_container_status()
        if not container_status["exists"]:
            logger.info("Container file does not exist, creating it...")
            if not create_dhcp_container():
                logger.error("Failed to create DHCP container file")
                return (
                    jsonify(
                        {
                            "error": "Failed to create DHCP container file. Check logs for details. The container file may need to be manually copied to /etc/containers/systemd/ztpbootstrap/ztpbootstrap-dhcp.container"
                        }
                    ),
                    500,
                )

        # Start container
        logger.info("Starting DHCP container...")
        if not start_dhcp_container():
            logger.error("Failed to start DHCP container")
            # Check if container is actually running despite the failure
            final_status = check_dhcp_container_status()
            if final_status.get("container_running", False):
                logger.info("Container is running despite start_dhcp_container returning False")
                # Container is running, so return success
                networking_mode = detect_networking_mode(config)
                return jsonify(
                    {
                        "success": True,
                        "networking_mode": networking_mode,
                        "port_conflicts": port_conflicts,
                        "warning": "Container started but systemctl commands may have failed. Container is running.",
                    }
                )

            # Container file was created but we couldn't start it automatically
            # Check if file exists in temp location (might not be in systemd directory)
            from dhcp_deploy import TEMP_DHCP_CONTAINER_FILE

            temp_file_exists = TEMP_DHCP_CONTAINER_FILE.exists()

            if temp_file_exists:
                # File exists in temp location but needs to be copied to systemd directory
                networking_mode = detect_networking_mode(config)
                return jsonify(
                    {
                        "success": True,
                        "networking_mode": networking_mode,
                        "port_conflicts": port_conflicts,
                        "warning": f"DHCP container file created in temp location, but could not be copied to systemd directory automatically. Please run: sudo cp {TEMP_DHCP_CONTAINER_FILE} /etc/containers/systemd/ztpbootstrap/ztpbootstrap-dhcp.container && sudo systemctl daemon-reload && sudo systemctl start ztpbootstrap-dhcp.service",
                        "manual_start_required": True,
                        "temp_file_location": str(TEMP_DHCP_CONTAINER_FILE),
                    }
                )
            else:
                # File should be in systemd directory but we can't start it
                networking_mode = detect_networking_mode(config)
                return jsonify(
                    {
                        "success": True,
                        "networking_mode": networking_mode,
                        "port_conflicts": port_conflicts,
                        "warning": "DHCP container file created successfully, but automatic start failed due to Podman socket permission issues. Please run 'sudo systemctl daemon-reload && sudo systemctl start ztpbootstrap-dhcp.service' on the host to start the service manually.",
                        "manual_start_required": True,
                    }
                )

            # Container file doesn't exist and we couldn't start - this is a real error
            return (
                jsonify(
                    {"error": "Failed to create and start DHCP container. Check logs for details."}
                ),
                500,
            )

        networking_mode = detect_networking_mode(config)

        # Log successful DHCP enable (Issue #10)
        log_security_event("dhcp_enable", "success", client_ip, "dhcp_container_started")

        return jsonify(
            {
                "success": True,
                "networking_mode": networking_mode,
                "port_conflicts": port_conflicts,
            }
        )
    except Exception as e:
        log_security_event("dhcp_enable", "failure", request.remote_addr, f"exception={str(e)}")
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/disable", methods=["POST"])
@require_auth
def disable_dhcp():
    """Disable DHCP (Issue #1, #9, #10 fixed)"""
    # Rate limiting: max 5 calls per minute (Issue #9)
    if rate_limiter:
        is_allowed, info = rate_limiter.check_rate_limit(max_calls=5, window=60)
        if not is_allowed:
            return (
                jsonify(
                    {
                        "error": "Rate limit exceeded. Please try again later.",
                        "code": "RATE_LIMIT_EXCEEDED",
                        "retry_after": info.get("retry_after", 60),
                    }
                ),
                429,
            )

    try:
        client_ip = request.remote_addr

        # Load and update config using ConfigManager (Issue #1)
        if config_manager:
            config = config_manager.read_config()
            if "dhcp" in config:
                config["dhcp"]["enabled"] = False
                success, error_msg = config_manager.update_section("dhcp", config["dhcp"])
                if not success:
                    log_security_event(
                        "dhcp_disable", "failure", client_ip, f"config_update_error={error_msg}"
                    )
                    return jsonify({"error": f"Failed to update configuration: {error_msg}"}), 500
        else:
            # Fallback to old method
            if CONFIG_FILE.exists():
                with open(CONFIG_FILE, "r") as f:
                    config = yaml.safe_load(f)
                config["dhcp"]["enabled"] = False

                # Write config
                with open(CONFIG_FILE, "w") as f:
                    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

        # Stop container and verify it stopped
        stop_success = stop_dhcp_container()

        # Verify container is actually stopped
        container_status = check_dhcp_container_status()
        container_still_running = container_status.get(
            "container_running", False
        ) or container_status.get("service_active", False)

        if not stop_success or container_still_running:
            logger.warning("Failed to stop DHCP container or container still running")
            # Config is updated, but container didn't stop
            # Return success with warning so UI doesn't revert, but include status
            return jsonify(
                {
                    "success": True,
                    "warning": "DHCP has been disabled in configuration, but the container may still be running. Please check the status.",
                    "container_status": container_status,
                }
            )

        # Optionally remove container (or leave it for future use)
        # remove_dhcp_container()

        # Log successful DHCP disable (Issue #10)
        log_security_event("dhcp_disable", "success", client_ip, "dhcp_container_stopped")

        return jsonify({"success": True})
    except Exception as e:
        log_security_event("dhcp_disable", "failure", request.remote_addr, f"exception={str(e)}")
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/leases", methods=["GET"])
@require_auth
def get_dhcp_leases():
    """Get current DHCP leases (IPv4 and IPv6)"""
    try:
        leases = []
        seen_leases = {}  # Track seen MAC+IP combinations to deduplicate
        ipv4_leases = get_leases("dhcp4")
        ipv6_leases = get_leases("dhcp6")

        for lease in ipv4_leases:
            # Use expire field if available, otherwise calculate from valid-lifetime
            expires = lease.get("expire", 0)
            if not expires and lease.get("valid-lifetime"):
                # If expire not set, calculate from current time + valid-lifetime
                import time

                expires = int(time.time()) + lease.get("valid-lifetime", 0)

            # Convert state to readable string
            state = lease.get("state", "unknown")
            if state == "0":
                state = "active"
            elif state == "1":
                state = "expired"
            elif state == "2":
                state = "reclaimed"

            mac = lease.get("hw-address", "")
            ip = lease.get("ip-address", "")
            lease_key = f"{mac}:{ip}"

            # Deduplicate: prefer active leases, then most recent expires
            if lease_key not in seen_leases:
                seen_leases[lease_key] = {
                    "mac": mac,
                    "ip": ip,
                    "type": "ipv4",
                    "state": state,
                    "expires": expires,
                }
            else:
                # If we've seen this MAC+IP combo, prefer active state or more recent expire
                existing = seen_leases[lease_key]
                if state == "active" and existing["state"] != "active":
                    seen_leases[lease_key] = {
                        "mac": mac,
                        "ip": ip,
                        "type": "ipv4",
                        "state": state,
                        "expires": expires,
                    }
                elif expires > existing["expires"]:
                    seen_leases[lease_key] = {
                        "mac": mac,
                        "ip": ip,
                        "type": "ipv4",
                        "state": state,
                        "expires": expires,
                    }

        for lease in ipv6_leases:
            # Use expire field if available, otherwise calculate from valid-lifetime
            expires = lease.get("expire", 0)
            if not expires and lease.get("valid-lifetime"):
                # If expire not set, calculate from current time + valid-lifetime
                import time

                expires = int(time.time()) + lease.get("valid-lifetime", 0)

            # Convert state to readable string
            state = lease.get("state", "unknown")
            if state == "0":
                state = "active"
            elif state == "1":
                state = "expired"
            elif state == "2":
                state = "reclaimed"

            mac = lease.get("hw-address", "")
            ip = lease.get("ip-address", "")
            lease_key = f"{mac}:{ip}"

            # Deduplicate: prefer active leases, then most recent expires
            if lease_key not in seen_leases:
                seen_leases[lease_key] = {
                    "mac": mac,
                    "ip": ip,
                    "type": "ipv6",
                    "state": state,
                    "expires": expires,
                }
            else:
                # If we've seen this MAC+IP combo, prefer active state or more recent expire
                existing = seen_leases[lease_key]
                if state == "active" and existing["state"] != "active":
                    seen_leases[lease_key] = {
                        "mac": mac,
                        "ip": ip,
                        "type": "ipv6",
                        "state": state,
                        "expires": expires,
                    }
                elif expires > existing["expires"]:
                    seen_leases[lease_key] = {
                        "mac": mac,
                        "ip": ip,
                        "type": "ipv6",
                        "state": state,
                        "expires": expires,
                    }

        # Convert deduplicated dict to list
        leases = list(seen_leases.values())

        return jsonify({"leases": leases})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/leases/<mac>", methods=["GET"])
@require_auth
def get_dhcp_lease(mac):
    """Get specific lease by MAC address"""
    try:
        lease = get_lease(mac, "dhcp4")
        if not lease:
            lease = get_lease(mac, "dhcp6")

        if lease:
            return jsonify({"lease": lease})
        else:
            return jsonify({"error": "Lease not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/leases/<mac>", methods=["DELETE"])
@require_auth
def delete_dhcp_lease(mac):
    """Delete/release a lease"""
    try:
        success = delete_lease(mac, "dhcp4") or delete_lease(mac, "dhcp6")
        if success:
            return jsonify({"success": True})
        else:
            return jsonify({"error": "Failed to delete lease"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/reservations", methods=["GET"])
@require_auth
def get_dhcp_reservations():
    """Get static reservations"""
    try:
        # Kea doesn't have a direct "get all reservations" command
        # Reservations are stored in config, so we read from config
        if CONFIG_FILE.exists():
            with open(CONFIG_FILE, "r") as f:
                config = yaml.safe_load(f)
            dhcp_config = config.get("dhcp", {})
            reservations = dhcp_config.get("reservations", [])
            return jsonify({"reservations": reservations})
        else:
            return jsonify({"reservations": []})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/reservations", methods=["POST"])
@require_auth
def add_dhcp_reservation():
    """Add static reservation"""
    try:
        data = request.get_json()
        if not data or "mac" not in data or "ip" not in data:
            return jsonify({"error": "MAC and IP address required"}), 400

        # Add via Kea API
        reservation = {
            "hw-address": data["mac"],
            "ip-address": data["ip"],
        }
        if "hostname" in data:
            reservation["hostname"] = data["hostname"]

        success = add_reservation(reservation, "dhcp4")
        if success:
            # Also update config file
            if CONFIG_FILE.exists():
                with open(CONFIG_FILE, "r") as f:
                    config = yaml.safe_load(f)
                if "dhcp" not in config:
                    config["dhcp"] = {}
                if "reservations" not in config["dhcp"]:
                    config["dhcp"]["reservations"] = []
                config["dhcp"]["reservations"].append(reservation)
                with open(CONFIG_FILE, "w") as f:
                    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

            return jsonify({"success": True})
        else:
            return jsonify({"error": "Failed to add reservation"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/reservations/<mac>", methods=["DELETE"])
@require_auth
def remove_dhcp_reservation(mac):
    """Remove static reservation"""
    try:
        success = delete_reservation(mac, "dhcp4")
        if success:
            # Also update config file
            if CONFIG_FILE.exists():
                with open(CONFIG_FILE, "r") as f:
                    config = yaml.safe_load(f)
                if "dhcp" in config and "reservations" in config["dhcp"]:
                    config["dhcp"]["reservations"] = [
                        r for r in config["dhcp"]["reservations"] if r.get("hw-address") != mac
                    ]
                    with open(CONFIG_FILE, "w") as f:
                        yaml.dump(config, f, default_flow_style=False, sort_keys=False)

            return jsonify({"success": True})
        else:
            return jsonify({"error": "Failed to remove reservation"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/dhcp/statistics", methods=["GET"])
@require_auth
def get_dhcp_statistics():
    """Get DHCP server statistics"""
    try:
        stats = {}
        ipv4_stats = get_statistics("dhcp4")
        ipv6_stats = get_statistics("dhcp6")

        stats["ipv4"] = ipv4_stats
        stats["ipv6"] = ipv6_stats

        return jsonify({"statistics": stats})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ============================================================================
# ZTP Network API Endpoints
# ============================================================================


def _load_full_config() -> dict:
    if config_manager:
        return config_manager.read_config()
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, "r") as f:
            return yaml.safe_load(f) or {}
    return {}


def _save_full_config(config: dict):
    if config_manager:
        try:
            config_manager.write_config(config)
            return True, None
        except Exception as exc:
            return False, str(exc)
    try:
        with open(CONFIG_FILE, "w") as f:
            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        return True, None
    except Exception as exc:
        return False, str(exc)


@app.route("/api/network/status", methods=["GET"])
@require_auth
def api_network_status():
    """Current ZTP network profile, drift, and runtime state."""
    try:
        if not get_network_status:
            return jsonify({"error": "Network modules not available"}), 503
        config = _load_full_config()
        payload = get_network_status(config)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/parents", methods=["GET"])
@require_auth
def api_network_parents():
    """Discover candidate macvlan parent interfaces."""
    try:
        if not discover_parent_interfaces:
            return jsonify({"error": "Network modules not available"}), 503
        return jsonify({"parents": discover_parent_interfaces()})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/podman", methods=["GET"])
@require_auth
def api_network_podman():
    """List ZTP-related Podman networks."""
    try:
        if not list_ztp_podman_networks:
            return jsonify({"error": "Network modules not available"}), 503
        return jsonify({"networks": list_ztp_podman_networks()})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/validate", methods=["POST"])
@require_auth
def api_network_validate():
    """Dry-run validation and change plan."""
    try:
        if not validate_ztp_profile or not plan_network_changes:
            return jsonify({"error": "Network modules not available"}), 503
        data = request.get_json() or {}
        current = _load_full_config()
        desired = merge_ztp_update(current, data.get("ztp") or data)
        errors, warnings = validate_ztp_profile(desired)
        plan = plan_network_changes(current, desired)
        return jsonify(
            {
                "valid": len(errors) == 0,
                "errors": errors,
                "warnings": warnings,
                "plan": plan,
            }
        )
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/ztp", methods=["PUT"])
@require_auth
def api_network_ztp_save():
    """Save ZTP profile to config without restart."""
    try:
        if not merge_ztp_update or not validate_ztp_profile:
            return jsonify({"error": "Network modules not available"}), 503
        data = request.get_json() or {}
        ztp_data = data.get("ztp") or data
        config = _load_full_config()
        config = merge_ztp_update(config, ztp_data)
        errors, warnings = validate_ztp_profile(config)
        if errors:
            return jsonify({"error": "; ".join(errors), "errors": errors, "warnings": warnings}), 400
        network = config.setdefault("network", {})
        ztp = network.setdefault("ztp", {})
        if ztp.get("enabled") and ztp.get("status") != "applied":
            ztp["status"] = "pending"
        ok, err = _save_full_config(config)
        if not ok:
            return jsonify({"error": err}), 500
        return jsonify({"success": True, "ztp": get_ztp_profile(config), "warnings": warnings})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/apply", methods=["POST"])
@require_auth
def api_network_apply():
    """Save ZTP profile and apply network changes with restart."""
    try:
        if not apply_ztp_network or not merge_ztp_update:
            return jsonify({"error": "Network modules not available"}), 503
        data = request.get_json() or {}
        ztp_data = data.get("ztp") or data
        current = _load_full_config()
        config = merge_ztp_update(current, ztp_data)
        success, error_msg, updated = apply_ztp_network(
            config, restart=True, current_config=current
        )
        if success:
            ok, save_err = _save_full_config(updated)
            if not ok:
                return jsonify({"error": save_err}), 500
            return jsonify({"success": True, "ztp": get_ztp_profile(updated)})
        ok, save_err = _save_full_config(updated)
        if not ok:
            return jsonify({"error": save_err}), 500
        return jsonify({"error": error_msg or "Apply failed"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/restart", methods=["POST"])
@require_auth
def api_network_restart():
    """Restart ZTP stack without config changes."""
    try:
        if not restart_ztp_stack:
            return jsonify({"error": "Network modules not available"}), 503
        config = _load_full_config()
        success, error_msg = restart_ztp_stack(config)
        if success:
            return jsonify({"success": True})
        return jsonify({"error": error_msg or "Restart failed"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/network/auto-detect", methods=["POST"])
@require_auth
def api_network_auto_detect():
    """Suggest subnet/gateway from parent interface."""
    try:
        if not auto_detect_from_parent:
            return jsonify({"error": "Network modules not available"}), 503
        data = request.get_json() or {}
        parent = (data.get("parent_interface") or "").strip()
        if not parent:
            return jsonify({"error": "parent_interface is required"}), 400
        return jsonify(auto_detect_from_parent(parent))
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    # Run on all interfaces (accessible from nginx container in pod)
    app.run(host="0.0.0.0", port=5000, debug=False)
