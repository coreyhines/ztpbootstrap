# Security Quick Reference

Quick reference card for security features in the ZTP Bootstrap Service.

---

## 🔒 Security Features at a Glance

| Feature | Status | Details |
|---------|--------|---------|
| **HTTPS/TLS** | ✅ Enabled | TLS 1.2/1.3, strong ciphers |
| **Authentication** | ✅ Password-based | PBKDF2 hashing, session management |
| **Rate Limiting** | ✅ Active | 5 attempts per 15 min |
| **CSRF Protection** | ✅ Active | All write operations |
| **Security Logging** | ✅ Active | Comprehensive audit trail |
| **Security Headers** | ✅ 6 headers | HSTS, CSP, X-Frame-Options, etc. |
| **File Permissions** | ✅ Hardened | 775/644 (600 for keys) |
| **Input Validation** | ✅ Active | Filename sanitization |

---

## 📊 Security Logs

**Location:** `/opt/containerdata/ztpbootstrap/logs/security.log`

**Quick Commands:**
```bash
# View recent events
tail -n 50 /opt/containerdata/ztpbootstrap/logs/security.log

# Failed logins
grep "outcome=failure" /opt/containerdata/ztpbootstrap/logs/security.log

# Monitor live
tail -f /opt/containerdata/ztpbootstrap/logs/security.log
```

---

## 🔐 File Permissions

| Type | Permission | Reason |
|------|-----------|--------|
| Directories | 755 or 775 | Owner/group write |
| Regular files | 644 | World-readable, owner-writable |
| Private keys | 600 | Owner-only read/write |
| Config file | 600 | Contains sensitive data |

---

## 🛡️ Security Headers

All requests include:
1. **HSTS** - Force HTTPS for 1 year
2. **X-Frame-Options** - Prevent clickjacking
3. **X-Content-Type-Options** - Prevent MIME sniffing
4. **X-XSS-Protection** - Enable XSS filter
5. **Referrer-Policy** - Control referrer info
6. **Permissions-Policy** - Block browser features
7. **CSP** - Control resource loading

---

## 🚨 Common Security Tasks

### Check Login Attempts
```bash
grep "event=login" /opt/containerdata/ztpbootstrap/logs/security.log | tail -20
```

### Check File Operations
```bash
grep "event=file_" /opt/containerdata/ztpbootstrap/logs/security.log
```

### Find Rate-Limited IPs
```bash
grep "rate_limited" /opt/containerdata/ztpbootstrap/logs/security.log | awk '{print $5}' | sort | uniq
```

### Change Admin Password
```bash
./setup-interactive.sh
# Choose password reset option
```

### Verify File Permissions
```bash
# Check key files
ls -la /opt/containerdata/certs/wild/*.key

# Check script directory
ls -la /opt/containerdata/ztpbootstrap/
```

---

## 📋 Security Checklist

Daily:
- [ ] Check security logs for anomalies
- [ ] Verify service is running

Weekly:
- [ ] Review failed login attempts
- [ ] Check for system updates
- [ ] Verify certificates not expiring soon

Monthly:
- [ ] Review all security logs
- [ ] Update Python dependencies
- [ ] Rotate admin password (if policy requires)
- [ ] Backup configuration

Quarterly:
- [ ] Full security audit
- [ ] Rotate enrollment token
- [ ] Review access controls

---

## 📖 Documentation Links

- **[SECURITY_AUDIT.md](SECURITY_AUDIT.md)** - Complete audit report
- **[SECURITY_BEST_PRACTICES.md](docs/SECURITY_BEST_PRACTICES.md)** - Deployment guide
- **[SECURITY.md](docs/SECURITY.md)** - Technical security details
- **[SECURITY_FIXES_SUMMARY.md](SECURITY_FIXES_SUMMARY.md)** - What was fixed

---

## 🆘 Security Incident Response

If you detect suspicious activity:

1. **Immediate:**
   - Check security logs: `tail -100 /opt/containerdata/ztpbootstrap/logs/security.log`
   - Identify source IP
   - Block if needed: `sudo firewall-cmd --add-rich-rule='rule family="ipv4" source address="<IP>" reject'`

2. **Investigation:**
   - Review all recent security events
   - Check for unauthorized file changes
   - Verify configuration integrity

3. **Remediation:**
   - Change admin password
   - Rotate enrollment token (if compromised)
   - Update affected files
   - Patch vulnerabilities

4. **Prevention:**
   - Implement additional monitoring
   - Tighten access controls
   - Update security policies

---

## 💡 Quick Tips

- **Always use HTTPS** in production
- **Monitor security logs** regularly
- **Keep system updated** weekly
- **Use strong passwords** (12+ chars)
- **Backup config** before changes
- **Test in lab** before production
- **Document changes** for audit trail

---

**For detailed information, see the complete security documentation.**
