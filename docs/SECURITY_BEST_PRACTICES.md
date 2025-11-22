# Security Best Practices

This document provides security best practices for deploying and operating the ZTP Bootstrap Service.

## Deployment Security

### 1. Use HTTPS in Production

**Always use HTTPS** for production deployments. HTTP-only mode should only be used in isolated lab environments.

```bash
# Use HTTPS (recommended)
./setup-interactive.sh

# Only use HTTP for testing in isolated labs
./setup-interactive.sh --http-only  # NOT for production!
```

**Why:** HTTPS encrypts all traffic between switches and the bootstrap service, protecting enrollment tokens and configuration data.

### 2. Use Valid TLS Certificates

Use certificates from a trusted Certificate Authority (CA) rather than self-signed certificates.

**Options:**
- Let's Encrypt (free, automated)
- Commercial CA certificates
- Internal PKI for enterprise environments

**Why:** Valid certificates prevent man-in-the-middle attacks and ensure switches can verify the server identity.

### 3. Set Strong Admin Password

Choose a strong admin password for the Web UI:

- Minimum 12 characters
- Mix of uppercase, lowercase, numbers, and symbols
- Avoid common words or patterns
- Use a password manager

```bash
# Interactive setup will prompt for password
./setup-interactive.sh
```

**Why:** The admin password protects sensitive operations like uploading scripts and viewing configuration.

### 4. Secure File Permissions

The setup scripts automatically set secure file permissions:

- Directories: 755 (rwxr-xr-x)
- Regular files: 644 (rw-r--r--)
- Private keys: 600 (rw-------)

**For NFS mounts:** More permissive permissions (777/666) may be required due to NFS limitations. This is documented and only used when necessary.

### 5. Protect Configuration Files

Keep sensitive configuration files secure:

```bash
# config.yaml contains enrollment tokens and password hashes
sudo chmod 600 /opt/containerdata/ztpbootstrap/config.yaml
```

**What to protect:**
- Enrollment tokens
- Password hashes
- Private keys
- API credentials (if any)

## Operational Security

### 6. Monitor Security Logs

Regularly review security logs for suspicious activity:

```bash
# View recent security events
tail -n 100 /opt/containerdata/ztpbootstrap/logs/security.log

# Look for failed login attempts
grep "outcome=failure" /opt/containerdata/ztpbootstrap/logs/security.log

# Monitor in real-time
tail -f /opt/containerdata/ztpbootstrap/logs/security.log
```

**Watch for:**
- Multiple failed login attempts from same IP
- Login attempts from unexpected IP addresses
- CSRF validation failures
- Unusual file operations

### 7. Regular Updates

Keep the system and dependencies up to date:

```bash
# Update system packages
sudo apt update && sudo apt upgrade  # Ubuntu/Debian
sudo dnf update                        # Fedora/RHEL

# Check for Python dependency vulnerabilities
pip-audit -r webui/requirements.txt
```

**Update schedule:**
- Security patches: As soon as available
- Dependency updates: Monthly
- System updates: Weekly

### 8. Limit Network Access

Restrict access to the bootstrap service:

**Firewall Rules:**
```bash
# Allow only from specific networks
sudo firewall-cmd --add-rich-rule='rule family="ipv4" source address="10.0.0.0/24" port port="443" protocol="tcp" accept'
sudo firewall-cmd --runtime-to-permanent
```

**Network Isolation:**
- Deploy in a management VLAN
- Use separate network for ZTP
- Implement network segmentation

### 9. Backup Configuration

Regularly backup configuration and keys:

```bash
# Manual backup
sudo tar czf ztpbootstrap-backup-$(date +%Y%m%d).tar.gz \
    /opt/containerdata/ztpbootstrap/ \
    /etc/containers/systemd/ztpbootstrap/

# Automated backup (add to cron)
0 2 * * * tar czf /backup/ztpbootstrap-$(date +\%Y\%m\%d).tar.gz /opt/containerdata/ztpbootstrap/
```

**What to backup:**
- Configuration files (config.yaml)
- Bootstrap scripts
- TLS certificates and keys
- Security logs
- Systemd unit files

### 10. Rotate Credentials Regularly

Change passwords and rotate tokens periodically:

**Admin Password:**
```bash
# Change admin password
./setup-interactive.sh
# Select option to reset password
```

**Enrollment Tokens:**
- Rotate enrollment tokens from CloudVision portal
- Update config.yaml with new token
- Test with a non-production device first

## Web UI Security

### 11. Session Management

Configure appropriate session timeouts in `config.yaml`:

```yaml
auth:
  session_timeout: 3600  # 1 hour (default)
```

**Recommendations:**
- Production: 1-2 hours (3600-7200 seconds)
- High-security: 30 minutes (1800 seconds)
- Lab: Can be longer for convenience

### 12. Rate Limiting

The service includes built-in rate limiting:
- Maximum 5 failed login attempts per 15 minutes
- Automatic lockout for 15 minutes

**This protects against:**
- Brute force password attacks
- Credential stuffing
- Automated attacks

### 13. CSRF Protection

All write operations require CSRF tokens. This is automatic but ensure:
- Don't disable CSRF protection
- Use the Web UI normally (tokens are handled automatically)
- If using API directly, include `X-CSRF-Token` header

## Network Security

### 14. Use Macvlan Networking

For production, use macvlan networking for isolation:

```bash
# Check if macvlan is available
./check-macvlan.sh

# Setup with macvlan (recommended)
./setup-interactive.sh
# Choose macvlan when prompted
```

**Benefits:**
- Dedicated IP address for service
- Network isolation from host
- Separate from other containers

### 15. Firewall Configuration

Enable and configure firewall:

```bash
# Ubuntu/Debian (ufw)
sudo ufw allow 443/tcp
sudo ufw enable

# Fedora/RHEL (firewalld)
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

### 16. Disable Unnecessary Services

Minimize attack surface by disabling unused services:

```bash
# List running services
sudo systemctl list-units --type=service --state=running

# Disable unused services
sudo systemctl disable <service-name>
```

## Container Security

### 17. SELinux/AppArmor

Keep security modules enabled:

**SELinux (Fedora/RHEL):**
```bash
# Check SELinux status
getenforce  # Should show "Enforcing"

# If disabled, enable it
sudo setenforce 1
```

**AppArmor (Ubuntu/Debian):**
```bash
# Check AppArmor status
sudo apparmor_status

# Should show profiles loaded and enforced
```

### 18. Container Isolation

Podman provides good isolation by default:
- Rootless containers where possible
- No privileged containers
- Limited capabilities

**Verify container security:**
```bash
# Check running containers
sudo podman ps

# Inspect container security
sudo podman inspect ztpbootstrap-nginx | grep -i security
```

## Incident Response

### 19. Responding to Security Events

If you detect suspicious activity:

1. **Immediate Actions:**
   - Check security logs for details
   - Identify affected systems
   - Block malicious IP addresses if needed

2. **Investigation:**
   - Review all security logs
   - Check for unauthorized file changes
   - Verify configuration integrity

3. **Remediation:**
   - Change admin password
   - Rotate enrollment token if compromised
   - Update affected bootstrap scripts
   - Patch any vulnerabilities

4. **Prevention:**
   - Implement additional monitoring
   - Tighten access controls
   - Update security policies

### 20. Security Checklist

Use this checklist for regular security reviews:

- [ ] HTTPS enabled with valid certificate
- [ ] Strong admin password set
- [ ] Security logs reviewed (no anomalies)
- [ ] System packages up to date
- [ ] Python dependencies up to date (no vulnerabilities)
- [ ] Firewall configured and active
- [ ] Network access restricted appropriately
- [ ] Configuration backed up
- [ ] SELinux/AppArmor enabled
- [ ] No unnecessary services running
- [ ] Session timeout configured appropriately
- [ ] Enrollment token rotated (if scheduled)
- [ ] TLS certificate not expired

## Compliance Considerations

### Data Protection

- **Enrollment Tokens:** Treat as credentials, store securely
- **Configuration Data:** May contain sensitive network information
- **Logs:** May contain IP addresses and user activity (consider data retention policies)

### Access Control

- **Role-Based Access:** Currently single admin role (suitable for small deployments)
- **Audit Trail:** Security logs provide complete audit trail
- **Authentication:** Password-based with rate limiting

### Network Requirements

- **Encryption:** TLS 1.2+ for all traffic
- **Isolation:** Separate network segment recommended
- **Monitoring:** Security event logging enabled by default

## Getting Help

### Security Questions

For security-related questions:
1. Check this document first
2. Review [SECURITY.md](SECURITY.md) for technical details
3. Check [SECURITY_AUDIT.md](../SECURITY_AUDIT.md) for known issues
4. Open a GitHub issue (for non-sensitive questions)

### Reporting Vulnerabilities

If you discover a security vulnerability:
1. **DO NOT** open a public GitHub issue
2. Email the repository maintainer directly
3. Provide detailed information about the vulnerability
4. Allow reasonable time for fixes before public disclosure

## Additional Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [CIS Security Benchmarks](https://www.cisecurity.org/cis-benchmarks/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [Podman Security Guide](https://docs.podman.io/en/latest/markdown/podman-security.1.html)

---

**Remember:** Security is an ongoing process, not a one-time setup. Regular monitoring, updates, and reviews are essential for maintaining a secure deployment.
