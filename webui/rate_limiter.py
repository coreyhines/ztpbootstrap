#!/usr/bin/env python3
"""
Rate Limiting for API Endpoints
Addresses COMPREHENSIVE_AUDIT_REPORT.md Issue #9 (Missing Rate Limiting)
and Issue #17 (Memory Leak in Login Attempts Dictionary)
"""

import random
import time
from collections import OrderedDict
from functools import wraps
from typing import Callable

from flask import jsonify, request


class RateLimiter:
    """
    Rate limiter for API endpoints.
    
    Features:
    - Per-IP and per-endpoint rate limiting
    - Automatic cleanup of old entries
    - Memory bounded (max tracked IPs)
    - LRU eviction when memory limit reached
    """
    
    def __init__(self, max_tracked_ips: int = 10000):
        """
        Initialize RateLimiter.
        
        Args:
            max_tracked_ips: Maximum number of IP addresses to track
        """
        self.rate_limits = OrderedDict()
        self.max_tracked_ips = max_tracked_ips
        self.cleanup_counter = 0
        
    def _get_client_identifier(self) -> str:
        """Get unique identifier for the client."""
        # Use X-Forwarded-For if behind proxy, otherwise use remote_addr
        client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
        if ',' in client_ip:
            # X-Forwarded-For can contain multiple IPs, use the first one
            client_ip = client_ip.split(',')[0].strip()
        endpoint = request.endpoint or 'unknown'
        return f"{client_ip}:{endpoint}"
    
    def _cleanup_old_entries(self, window: int) -> None:
        """
        Remove entries older than the window.
        
        Args:
            window: Time window in seconds
        """
        cutoff = time.time() - window
        to_remove = [
            key for key, data in self.rate_limits.items()
            if data["reset"] < cutoff
        ]
        for key in to_remove:
            del self.rate_limits[key]
    
    def _enforce_memory_limit(self) -> None:
        """Enforce maximum number of tracked IPs using LRU eviction."""
        while len(self.rate_limits) > self.max_tracked_ips:
            # Remove oldest entry (LRU)
            self.rate_limits.popitem(last=False)
    
    def _periodic_cleanup(self, window: int) -> None:
        """
        Periodically cleanup old entries (probabilistic).
        
        Args:
            window: Time window in seconds
        """
        self.cleanup_counter += 1
        
        # Run cleanup on 1% of requests or every 100 requests
        if random.random() < 0.01 or self.cleanup_counter >= 100:
            self._cleanup_old_entries(window)
            self.cleanup_counter = 0
    
    def check_rate_limit(
        self,
        max_calls: int,
        window: int,
        identifier: str = None
    ) -> tuple[bool, dict]:
        """
        Check if rate limit is exceeded.
        
        Args:
            max_calls: Maximum number of calls allowed in window
            window: Time window in seconds
            identifier: Optional custom identifier (defaults to IP:endpoint)
            
        Returns:
            Tuple of (is_allowed, info_dict)
        """
        if identifier is None:
            identifier = self._get_client_identifier()
        
        current_time = time.time()
        
        # Periodic cleanup
        self._periodic_cleanup(window)
        
        # Check if identifier exists
        if identifier in self.rate_limits:
            data = self.rate_limits[identifier]
            
            # Check if window has expired
            if current_time > data["reset"]:
                # Reset the counter
                data["count"] = 1
                data["reset"] = current_time + window
                data["first_call"] = current_time
                self.rate_limits[identifier] = data
                return True, {
                    "limit": max_calls,
                    "remaining": max_calls - 1,
                    "reset": int(data["reset"])
                }
            
            # Check if limit exceeded
            if data["count"] >= max_calls:
                return False, {
                    "limit": max_calls,
                    "remaining": 0,
                    "reset": int(data["reset"]),
                    "retry_after": int(data["reset"] - current_time)
                }
            
            # Increment counter
            data["count"] += 1
            # Move to end (LRU)
            self.rate_limits.move_to_end(identifier)
            
            return True, {
                "limit": max_calls,
                "remaining": max_calls - data["count"],
                "reset": int(data["reset"])
            }
        else:
            # New identifier
            self.rate_limits[identifier] = {
                "count": 1,
                "reset": current_time + window,
                "first_call": current_time
            }
            
            # Enforce memory limit
            self._enforce_memory_limit()
            
            return True, {
                "limit": max_calls,
                "remaining": max_calls - 1,
                "reset": int(current_time + window)
            }
    
    def rate_limit(
        self,
        max_calls: int = 10,
        window: int = 60,
        error_message: str = "Rate limit exceeded. Please try again later."
    ) -> Callable:
        """
        Decorator for rate limiting Flask routes.
        
        Args:
            max_calls: Maximum number of calls allowed in window
            window: Time window in seconds
            error_message: Custom error message to return
            
        Returns:
            Decorator function
            
        Example:
            @app.route("/api/endpoint")
            @rate_limiter.rate_limit(max_calls=5, window=60)
            def endpoint():
                return jsonify({"status": "ok"})
        """
        def decorator(f: Callable) -> Callable:
            @wraps(f)
            def wrapped(*args, **kwargs):
                is_allowed, info = self.check_rate_limit(max_calls, window)
                
                if not is_allowed:
                    response = jsonify({
                        "error": error_message,
                        "code": "RATE_LIMIT_EXCEEDED",
                        "retry_after": info.get("retry_after", window)
                    })
                    response.status_code = 429
                    # Add rate limit headers
                    response.headers["X-RateLimit-Limit"] = str(info["limit"])
                    response.headers["X-RateLimit-Remaining"] = str(info["remaining"])
                    response.headers["X-RateLimit-Reset"] = str(info["reset"])
                    response.headers["Retry-After"] = str(info.get("retry_after", window))
                    return response
                
                # Call the original function
                result = f(*args, **kwargs)
                
                # Add rate limit headers to successful response
                if hasattr(result, 'headers'):
                    result.headers["X-RateLimit-Limit"] = str(info["limit"])
                    result.headers["X-RateLimit-Remaining"] = str(info["remaining"])
                    result.headers["X-RateLimit-Reset"] = str(info["reset"])
                
                return result
            
            return wrapped
        return decorator


# Global rate limiter instance
rate_limiter = RateLimiter()
