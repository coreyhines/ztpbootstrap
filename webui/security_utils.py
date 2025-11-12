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
    
    This function ensures that the resolved absolute path of file_path is strictly
    within the resolved absolute path of base_directory, preventing directory traversal attacks.
    
    Args:
        file_path: The Path object to validate
        base_directory: The base directory Path
        
    Returns:
        True if path is safe, False otherwise
    """
    try:
        # Resolve both paths to absolute paths (this normalizes .. and . components)
        resolved_path = file_path.resolve().absolute()
        resolved_base = base_directory.resolve().absolute()
        
        # Ensure resolved_base ends with separator for proper comparison
        base_str = str(resolved_base)
        if not base_str.endswith(os.sep):
            base_str += os.sep
        
        path_str = str(resolved_path)
        
        # Check if resolved path is strictly within base directory
        # Using os.path.commonpath for additional safety check
        try:
            common_path = os.path.commonpath([path_str, base_str])
            return common_path == base_str.rstrip(os.sep)
        except ValueError:
            # Paths are on different drives (Windows) or invalid
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
