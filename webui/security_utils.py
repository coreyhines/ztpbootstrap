#!/usr/bin/env python3
"""
Security utility functions for the ZTP Bootstrap Web UI
"""

import os
import re
from pathlib import Path


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
    filename = filename.replace('\x00', '')
    
    # Only allow alphanumeric, dots, underscores, and hyphens
    # Must start with 'bootstrap' and end with '.py'
    if not re.match(r'^bootstrap[a-zA-Z0-9_.-]*\.py$', filename):
        return None
    
    # Prevent dangerous patterns
    dangerous_patterns = ['..', '/', '\\', '\0']
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
    if not filename.endswith('.py'):
        return False, None
    
    # Sanitize
    sanitized = sanitize_filename(filename)
    if not sanitized:
        return False, None
    
    return True, sanitized
