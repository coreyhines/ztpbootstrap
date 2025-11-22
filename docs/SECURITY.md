# Security Guide

## Overview

This document outlines the security measures implemented in the ZTP Bootstrap Web UI and provides guidance for security testing and improvements.

## Current Security Measures

### Authentication & Authorization
- ✅ Password-based authentication with PBKDF2 hashing
- ✅ Session management with configurable timeout
- ✅ CSRF protection on all write operations
- ✅ Rate limiting (5 attempts per 15 minutes)
- ✅ Protected endpoints require authentication

### Input Validation
- ✅ Filename validation (must end with `.py`, must start with `bootstrap`)
- ✅ Path traversal prevention (using `Path` objects, not string concatenation)
- ✅ File upload validation (extension check, size limits via nginx)
- ✅ YAML parsing uses `safe_load()` to prevent code execution

### Security Headers (via nginx)
- ✅ Content-Security-Policy (CSP)
- ✅ Strict-Transport-Security (HSTS)
- ✅ X-Frame-Options: DENY
- ✅ X-Content-Type-Options: nosniff
- ✅ X-XSS-Protection: 1; mode=block
- ✅ Referrer-Policy: strict-origin-when-cross-origin

### Session Security
- ✅ HTTPOnly cookies
- ✅ SameSite=Lax
- ✅ Secure flag (when HTTPS enabled)
- ✅ Session expiration

### XSS Protection
- ✅ HTML escaping via `escapeHtml()` function
- ✅ CSP headers restrict inline scripts
- ✅ User input sanitized before rendering

## Security Testing Tools

### Recommended Tools

#### 1. OWASP ZAP (Zed Attack Proxy)
**Installation:**
```bash
# macOS
brew install --cask owasp-zap

# Linux
sudo apt-get install zaproxy  # or download from https://www.zaproxy.org/download/
```

**Basic Scan:**
```bash
# Start ZAP daemon
zap.sh -daemon -host 0.0.0.0 -port 8080 -config api.disablekey=true

# Run quick scan
zap-cli quick-scan --self-contained --start-options '-config api.disablekey=true' http://127.0.0.1:8080/ui/
```

**Automated Scan Script:**
```bash
#!/bin/bash
# security-scan.sh
ZAP_URL="http://127.0.0.1:8080"
TARGET_URL="http://127.0.0.1:8080/ui/"

# Start ZAP
zap.sh -daemon -host 0.0.0.0 -port 8080 -config api.disablekey=true &
ZAP_PID=$!
sleep 10

# Run spider scan
zap-cli spider $TARGET_URL

# Run active scan
zap-cli active-scan $TARGET_URL

# Generate report
zap-cli report -o security-report.html -f html

# Stop ZAP
kill $ZAP_PID
```

#### 2. Dependency Vulnerability Scanning

**pip-audit (Python dependencies):**
```bash
pip install pip-audit
pip-audit -r webui/requirements.txt
```

**Safety (alternative):**
```bash
pip install safety
safety check -r webui/requirements.txt
```

**Bandit (Python code security linter):**
```bash
pip install bandit
bandit -r webui/ -f json -o bandit-report.json
```

#### 3. Security Headers Check

**Online Tools:**
- https://securityheaders.com/
- https://observatory.mozilla.org/

**Command Line:**
```bash
curl -I https://your-domain.com/ui/ | grep -i "x-\|strict-transport\|content-security"
```

#### 4. Manual Security Testing Checklist

- [ ] **Authentication Bypass**
  - Try accessing protected endpoints without authentication
  - Test session expiration
  - Test CSRF token validation

- [ ] **Input Validation**
  - Path traversal attempts (`../../etc/passwd`)
  - XSS payloads (`<script>alert('XSS')</script>`)
  - SQL injection (if applicable)
  - Command injection (filename parameters)

- [ ] **File Upload Security**
  - Upload non-Python files
  - Upload files with malicious content
  - Test file size limits
  - Test filename sanitization

- [ ] **Session Management**
  - Session fixation
  - Session hijacking
  - Concurrent sessions

- [ ] **Rate Limiting**
  - Test lockout after 5 failed attempts
  - Test lockout duration
  - Test reset on successful login

## Security Improvements Implemented

### ✅ Path Traversal Protection
- **Status:** Implemented
- **Details:** Added `security_utils.py` with `sanitize_filename()` and `validate_path_in_directory()` functions
- **Protection:** All filename parameters are sanitized and validated before use
- **Coverage:** All endpoints that accept filename parameters now validate paths

### ✅ Input Sanitization
- **Status:** Implemented
- **Details:** Filenames are sanitized to only allow alphanumeric, dots, underscores, and hyphens
- **Pattern:** Must match `^bootstrap[a-zA-Z0-9_.-]*\.py$`
- **Protection:** Prevents path traversal (`../`), null bytes, and special characters

### ✅ Security Event Logging (NEW)
- **Status:** Implemented
- **Details:** Comprehensive security event logging to dedicated log file
- **Log Location:** `/opt/containerdata/ztpbootstrap/logs/security.log`
- **Events Logged:**
  - Login attempts (success/failure with IP address)
  - Rate limiting triggers
  - CSRF validation failures
  - File uploads (filename, size, outcome)
  - File deletions (filename, outcome)
  - File renames (old/new names, outcome)
- **Format:** Timestamp | Level | IP | Event | Outcome | Details
- **Example:** `2025-11-22 02:43:15 | WARNING | IP=192.168.1.100 | event=login | outcome=failure | user=admin reason=invalid_password`

### ✅ Improved File Permissions (NEW)
- **Status:** Implemented
- **Details:** Reduced file permissions from overly permissive 777/666 to secure 775/644
- **Changes:**
  - Logs directory: 777 → 775 (group-writable but not world-writable)
  - Private key files: 644 → 600 (readable only by owner)
  - Certificate files: 644 (world-readable, appropriate for certificates)
  - Script directory: 775/664 for local filesystems
  - NFS mounts: 777/666 (necessary due to NFS limitations, documented with security notes)

### ✅ Permissions-Policy Header (NEW)
- **Status:** Implemented
- **Details:** Added `Permissions-Policy` header to all nginx location blocks
- **Protection:** Blocks access to browser features that aren't needed
- **Policy:** `geolocation=(), microphone=(), camera=(), payment=(), usb=(), interest-cohort=()`
- **Benefit:** Reduces attack surface by preventing potential misuse of browser APIs

## Security Improvements Needed

### Medium Priority

1. **File Upload Content Validation**
   - Current: Extension check only
   - Needed: Content-type validation, file signature checking
   - Risk: Medium

2. **Security Logging**
   - Current: No security event logging
   - Needed: Log failed authentication attempts, CSRF failures, rate limiting events
   - Risk: Low

### Medium Priority

4. **Security Headers Enhancement** ✅ IMPLEMENTED
   - ✅ Added `Permissions-Policy` header
   - Consider stricter CSP (remove `unsafe-eval` if possible) - Requires Alpine.js migration
   - Risk: Low

5. **Logging & Monitoring** ✅ IMPLEMENTED
   - ✅ Log failed authentication attempts
   - ✅ Log security events (CSRF failures, rate limiting)
   - ✅ Log file operations (upload, delete, rename)
   - Risk: Low

6. **Dependency Updates**
   - Regular dependency vulnerability scanning
   - Automated updates via Dependabot
   - Risk: Medium

### Low Priority

7. **Additional Security Headers**
   - `X-Permitted-Cross-Domain-Policies`
   - `Cross-Origin-Embedder-Policy`
   - Risk: Low

8. **Password Policy**
   - Enforce minimum complexity
   - Password history
   - Risk: Low

## Security Logging

### Log Files

The Web UI maintains detailed security logs for audit and compliance:

**Location:** `/opt/containerdata/ztpbootstrap/logs/security.log`

### Events Logged

All security-relevant events are logged with timestamp, IP address, event type, outcome, and details:

1. **Authentication Events**
   - Successful logins
   - Failed login attempts (with reason)
   - Rate limiting triggers

2. **CSRF Protection**
   - CSRF token validation failures
   - Endpoint and method information

3. **File Operations** (Authenticated Actions)
   - File uploads (filename, size)
   - File deletions (filename)
   - File renames (old/new names)

### Log Format

```
YYYY-MM-DD HH:MM:SS | LEVEL | IP=<address> | event=<type> | outcome=<success|failure> | details
```

### Example Log Entries

```
2025-11-22 02:43:15 | INFO | IP=192.168.1.100 | event=login | outcome=success | user=admin
2025-11-22 02:43:20 | WARNING | IP=192.168.1.101 | event=login | outcome=failure | user=admin reason=invalid_password
2025-11-22 02:43:25 | WARNING | IP=192.168.1.102 | event=login | outcome=failure | reason=rate_limited
2025-11-22 02:44:00 | INFO | IP=192.168.1.100 | event=file_upload | outcome=success | filename=bootstrap_test.py size=20480
2025-11-22 02:45:00 | WARNING | IP=192.168.1.103 | event=csrf_validation | outcome=failure | endpoint=upload_bootstrap_script method=POST
```

### Monitoring Security Logs

View security logs in real-time:
```bash
tail -f /opt/containerdata/ztpbootstrap/logs/security.log
```

Filter for failed events:
```bash
grep "outcome=failure" /opt/containerdata/ztpbootstrap/logs/security.log
```

Filter for specific event types:
```bash
grep "event=login" /opt/containerdata/ztpbootstrap/logs/security.log
```

### Log Rotation

Consider implementing log rotation to manage log file size:

```bash
# Example logrotate configuration
/opt/containerdata/ztpbootstrap/logs/security.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
```

## Security Testing Workflow

### Pre-Deployment Checklist

1. Run dependency scan (`pip-audit`)
2. Run code security scan (`bandit`)
3. Run OWASP ZAP baseline scan
4. Manual security header verification
5. Test authentication flows
6. Test input validation
7. Review error messages (no information leakage)
8. Review security logs for anomalies

### Regular Security Maintenance

- **Weekly**: Dependency vulnerability scan
- **Monthly**: Full security scan with OWASP ZAP
- **Quarterly**: Security audit and penetration testing
- **On Release**: Full security testing suite

## Reporting Security Issues

If you discover a security vulnerability, please:
1. Do not open a public issue
2. Email security concerns to the repository maintainer
3. Provide detailed information about the vulnerability
4. Allow reasonable time for fixes before disclosure

## References

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [OWASP Web Security Testing Guide](https://owasp.org/www-project-web-security-testing-guide/)
- [Flask Security Best Practices](https://flask.palletsprojects.com/en/latest/security/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
