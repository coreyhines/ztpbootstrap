#!/usr/bin/env python3
"""
CVaaS configuration helpers for the Web UI.

Updates config.yaml cvaas.enroll_chars and syncs enrollChars in bootstrap.py
(matching update-config.sh behavior).
"""

import re
from pathlib import Path
from typing import Optional, Tuple

from config_manager import create_unique_backup

ENROLL_CHARS_LINE = re.compile(r"^enrollChars = .*$", re.MULTILINE)


def validate_enroll_chars(value: str) -> Tuple[bool, Optional[str], Optional[str]]:
    """
    Validate enrollment chars from CVaaS Device Registration.

    Returns:
        Tuple of (is_valid, error_message, warning_message)
    """
    if value is None or not str(value).strip():
        return False, "Enrollment chars value is required", None

    cleaned = str(value).strip()
    warning = None
    if len(cleaned) < 20:
        warning = "Value seems too short (expected a JWT from the CVaaS Device Registration page)"
    return True, None, warning


def sync_enroll_chars_to_bootstrap(
    bootstrap_path: Path, enroll_chars: str
) -> Tuple[bool, Optional[str]]:
    """
    Update enrollChars in bootstrap.py to match config.yaml.

    Creates a uniquely named, owner-only (0600) backup before writing, since the
    backup holds the previous enrollment token and sits in the nginx docroot.
    """
    if not bootstrap_path.exists():
        return False, f"Bootstrap script not found: {bootstrap_path}"

    content = bootstrap_path.read_text(encoding="utf-8")
    new_line = f"enrollChars = {repr(enroll_chars)}"
    new_content, count = ENROLL_CHARS_LINE.subn(new_line, content, count=1)
    if count == 0:
        return False, "enrollChars assignment not found in bootstrap.py"

    create_unique_backup(bootstrap_path, bootstrap_path.parent, "bootstrap_backup_", ".py")
    bootstrap_path.write_text(new_content, encoding="utf-8")
    return True, None
