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

4. **Security Headers Enhancement**
   - Add `Permissions-Policy` header
   - Consider stricter CSP (remove `unsafe-eval` if possible)
   - Risk: Low

5. **Logging & Monitoring**
   - Log failed authentication attempts
   - Log security events (CSRF failures, rate limiting)
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

## Security Testing Workflow

### Pre-Deployment Checklist

1. Run dependency scan (`pip-audit`)
2. Run code security scan (`bandit`)
3. Run OWASP ZAP baseline scan
4. Manual security header verification
5. Test authentication flows
6. Test input validation
7. Review error messages (no information leakage)

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
