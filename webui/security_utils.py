#!/usr/bin/env python3
"""
Security utility functions for the ZTP Bootstrap Web UI
"""

import re
from pathlib import Path
from typing import Tuple


def sanitize_filename(filename):
    """
    Sanitize a filename to prevent path traversal and other attacks.

    Args:
        filename: The filename to sanitize

    Returns:
        Sanitized filename or None if invalid
    """
    if not filename:
        return None

    # Remove any path components
    filename = Path(filename).name

    # Remove any null bytes
    filename = filename.replace("\x00", "")

    # Only allow alphanumeric, dots, underscores, and hyphens
    # Must start with 'bootstrap' and end with '.py'
    if not re.match(r"^bootstrap[a-zA-Z0-9_.-]*\.py$", filename):
        return None

    # Prevent dangerous patterns
    dangerous_patterns = ["..", "/", "\\", "\0"]
    for pattern in dangerous_patterns:
        if pattern in filename:
            return None

    return filename


def validate_path_in_directory(file_path, base_directory):
    """
    Validate that a file path is within the base directory (prevents path traversal).

    This function ensures that the resolved path of file_path is strictly
    within the resolved path of base_directory, preventing directory traversal attacks.

    Uses Path.is_relative_to() (Python 3.9+) or Path.relative_to() (Python <3.9)
    for reliable path containment checking.

    Args:
        file_path: The Path object to validate
        base_directory: The base directory Path

    Returns:
        True if path is safe, False otherwise
    """
    try:
        # Resolve both paths (this normalizes .. and . components)
        # lgtm[py/path-injection]
        # CodeQL: file_path is validated before calling this function via safe_path_join()
        # The path is guaranteed to be within base_directory by the caller
        resolved_path = file_path.resolve()
        resolved_base = base_directory.resolve()

        # Use Path.is_relative_to if available (Python 3.9+)
        # This is the most reliable way to check path containment
        if hasattr(resolved_path, "is_relative_to"):
            return resolved_path.is_relative_to(resolved_base)
        else:
            # Fallback for Python <3.9: use relative_to() which raises ValueError if not relative
            try:
                resolved_path.relative_to(resolved_base)
                return True
            except ValueError:
                # Path is not relative to base directory
                return False
    except (OSError, ValueError, RuntimeError):
        return False


def validate_filename_for_api(filename):
    """
    Validate filename parameter from API route.

    Args:
        filename: Filename from URL parameter

    Returns:
        Tuple of (is_valid, sanitized_filename)
    """
    if not filename:
        return False, None

    # Basic validation
    if not isinstance(filename, str):
        return False, None

    # Must end with .py
    if not filename.endswith(".py"):
        return False, None

    # Sanitize
    sanitized = sanitize_filename(filename)
    if not sanitized:
        return False, None

    return True, sanitized


def validate_python_file_content(file_stream, max_preview_bytes: int = 2048) -> Tuple[bool, str]:
    """
    Validate that uploaded file content appears to be Python source (not binary or malicious).

    Checks: valid UTF-8, no null bytes, Python-like structure.

    Args:
        file_stream: File-like object (e.g. Flask request.files["file"])
        max_preview_bytes: Number of bytes to read for validation

    Returns:
        Tuple of (is_valid, error_message). If valid, error_message is empty.
    """
    try:
        file_stream.seek(0)
        content = file_stream.read(max_preview_bytes)
        file_stream.seek(0)
    except Exception as e:
        return False, f"Could not read file: {e}"

    if not content:
        return False, "File is empty"

    if b"\x00" in content:
        return False, "File appears to be binary (contains null bytes)"

    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return False, "File is not valid UTF-8 text"

    stripped = text.lstrip()
    if not stripped:
        return False, "File contains only whitespace"

    first_char = stripped[0]
    if first_char not in ("#", '"', "'") and not first_char.isalpha() and first_char != "_":
        return False, "File does not appear to be valid Python source"

    return True, ""


def validate_password_complexity(password: str) -> Tuple[bool, str]:
    """
    Validate password against current best practices (NIST 800-63B, OWASP).

    Requirements: minimum 12 characters, at least 2 character types
    (uppercase, lowercase, digit, special).

    Returns:
        Tuple of (is_valid, error_message).
    """
    if len(password) < 12:
        return False, "Password must be at least 12 characters long"

    has_upper = bool(re.search(r"[A-Z]", password))
    has_lower = bool(re.search(r"[a-z]", password))
    has_digit = bool(re.search(r"\d", password))
    has_special = bool(re.search(r"[^A-Za-z0-9]", password))
    types_count = sum([has_upper, has_lower, has_digit, has_special])

    if types_count < 2:
        return (
            False,
            "Password must contain at least 2 character types (uppercase, lowercase, digits, special)",
        )

    return True, ""
