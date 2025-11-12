#!/usr/bin/env python3
"""
Security utility functions for the ZTP Bootstrap Web UI
"""

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
    
    Args:
        file_path: The Path object to validate
        base_directory: The base directory Path
        
    Returns:
        True if path is safe, False otherwise
    """
    try:
        # Resolve both paths to absolute paths
        resolved_path = file_path.resolve()
        resolved_base = base_directory.resolve()
        
        # Check if resolved path is within base directory
        return str(resolved_path).startswith(str(resolved_base))
    except (OSError, ValueError):
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
