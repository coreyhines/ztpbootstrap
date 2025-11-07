# Sanitization Notes

This repository has been sanitized to remove environment-specific values and secrets.

## Changes Made

### Secrets Removed:
- Enrollment tokens replaced with `YOUR_ENROLLMENT_TOKEN_HERE` placeholder
- All JWT tokens removed from bootstrap scripts and environment files

### Environment-Specific Values Replaced:

1. **Domain Names:**
   - `ztpboot.freeblizz.com` → `ztpboot.example.com`
   - `*.freeblizz.com` → `*.example.com`

2. **IP Addresses:**
   - IPv4: `10.0.10.10` → `10.0.0.10` (example)
   - IPv6: `2601:441:8400:b7e1::10` → `2001:db8::10` (example/documentation IP)

3. **CVaaS Address:**
   - `www.cv-staging.corp.arista.io` → `www.arista.io` (production default)

4. **NTP Server:**
   - `10.0.10.11`, `10.0.2.10` → `time.nist.gov` (public NIST server)

5. **Email Addresses:**
   - `admin@freeblizz.com` → `admin@example.com`

6. **Timezone:**
   - `America/Central` → `UTC`

7. **DNS Servers:**
   - Internal DNS servers → `8.8.8.8`, `8.8.4.4` (Google DNS, commented out)

8. **Network Configuration:**
   - Custom network `net-10` → `host` network mode (more generic)

## Files Excluded from Git

The following files are in `.gitignore` and should not be committed:
- `ztpbootstrap.env` - Contains actual secrets and environment-specific values
- `bootstrap_configured.py` - Generated file with substituted values
- `*.backup`, `*.bak` - Backup files
- `*.pem`, `*.key`, `*.crt` - SSL certificates

## Before Using This Repository

1. Copy `ztpbootstrap.env.template` to `ztpbootstrap.env`
2. Update `ztpbootstrap.env` with your actual values:
   - Enrollment token
   - Domain name
   - IP addresses
   - NTP server (if different)
   - Timezone
3. Update `bootstrap.py` with your enrollment token
4. Update `nginx.conf` with your domain and IP addresses
5. Update systemd quadlet file with your network configuration
6. Obtain SSL certificates for your domain

## Nested Git Repository

This repository is nested within a parent git repository. This is generally fine, but be aware:
- The parent repo will show this directory as a submodule or untracked
- You may want to add this directory to the parent's `.gitignore` if you don't want it tracked there
- Alternatively, you can use git submodules if you want the parent to track this repo
