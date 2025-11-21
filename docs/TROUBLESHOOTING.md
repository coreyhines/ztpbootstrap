# Troubleshooting Guide

Common issues and solutions for the Arista ZTP Bootstrap Service.

## Table of Contents

- [Service Won't Start](#service-wont-start)
- [Container Issues](#container-issues)
- [Network Connectivity](#network-connectivity)
- [SSL Certificate Problems](#ssl-certificate-problems)
- [Bootstrap Script Issues](#bootstrap-script-issues)
- [Device Enrollment Failures](#device-enrollment-failures)
- [Configuration Problems](#configuration-problems)
- [Performance Issues](#performance-issues)

## Service Won't Start

### Symptoms
- Container fails to start
- Systemd service shows failed status
- Error messages in logs

### Diagnosis

```bash
# Check container status
podman ps -a | grep ztpbootstrap

# Check systemd status
systemctl status ztpbootstrap

# View logs
podman logs ztpbootstrap
# Or
journalctl -u ztpbootstrap -n 50
```

### Solutions

**Issue: Port already in use**
```bash
# Check what's using the port
sudo ss -tlnp | grep 443
sudo ss -tlnp | grep 80

# Stop conflicting service or change port in config
```

**Issue: SSL certificate files missing or unreadable**
```bash
# Check certificate files exist
ls -la /opt/containerdata/certs/wild/

# Check permissions
sudo chmod 644 /opt/containerdata/certs/wild/fullchain.pem
sudo chmod 600 /opt/containerdata/certs/wild/privkey.pem

# Verify files are readable
sudo cat /opt/containerdata/certs/wild/fullchain.pem
```

**Issue: Nginx configuration syntax error**
```bash
# Test nginx config
sudo podman run --rm -v /opt/containerdata/ztpbootstrap/nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t

# Check for syntax errors in nginx.conf
```

**Issue: Missing directories**
```bash
# Create required directories
sudo mkdir -p /opt/containerdata/ztpbootstrap
sudo mkdir -p /opt/containerdata/certs/wild

# Set correct permissions
sudo chown -R root:root /opt/containerdata/ztpbootstrap
```

## Container Issues

### Symptoms
- Container exits immediately
- Container won't start
- Container restarts repeatedly

### Diagnosis

```bash
# Check container logs
podman logs ztpbootstrap

# Check container status
podman inspect ztpbootstrap | grep -A 10 State

# Check resource usage
podman stats ztpbootstrap
```

### Solutions

**Issue: Container exits with code 1**
- Usually indicates nginx configuration error
- Check nginx.conf syntax
- Verify volume mounts are correct

**Issue: Permission denied errors**
```bash
# Check file permissions
ls -la /opt/containerdata/ztpbootstrap/
ls -la /opt/containerdata/certs/wild/

# Fix permissions if needed
sudo chmod 644 /opt/containerdata/ztpbootstrap/nginx.conf
sudo chmod 644 /opt/containerdata/ztpbootstrap/bootstrap.py
```

**Issue: Volume mount failures**
```bash
# Verify paths exist
test -d /opt/containerdata/ztpbootstrap && echo "OK" || echo "Missing"
test -f /opt/containerdata/ztpbootstrap/nginx.conf && echo "OK" || echo "Missing"

# Check systemd quadlet file paths
cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container | grep Volume
```

## Network Connectivity

### Symptoms
- Devices can't reach bootstrap script
- curl fails to connect
- Timeout errors

### Diagnosis

```bash
# Test from server
curl -k https://ztpboot.example.com/health
curl -k https://ztpboot.example.com/bootstrap.py

# Test from device network
# (Run from a device on the same network)
curl -k https://ztpboot.example.com/health

# Check DNS resolution
nslookup ztpboot.example.com
dig ztpboot.example.com

# Check firewall
sudo iptables -L -n
sudo firewall-cmd --list-all  # firewalld
```

### Solutions

**Issue: Firewall blocking ports**
```bash
# Allow HTTPS (443)
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

# Or allow specific port
sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --reload

# For iptables
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

**Issue: DNS not resolving**
```bash
# Add to /etc/hosts (temporary fix)
echo "10.0.0.10 ztpboot.example.com" | sudo tee -a /etc/hosts

# Or configure proper DNS
# Update your DNS server with A record for ztpboot.example.com
```

**Issue: IP address not assigned**
```bash
# Check IP assignment
ip addr show

# Assign IP if missing
sudo ip addr add 10.0.0.10/24 dev eth0

# Make persistent (example)
sudo nmcli connection modify <connection> ipv4.addresses 10.0.0.10/24
sudo nmcli connection up <connection>
```

**Issue: Wrong network interface**
```bash
# List interfaces
ip addr show

# Update nginx.conf or systemd quadlet to use correct interface
# Or use host network mode (already default)
```

## SSL Certificate Problems

### Symptoms
- Certificate errors
- Browser/device rejects certificate
- Certificate expired warnings

### Diagnosis

```bash
# Check certificate validity
openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout

# Check expiration
openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -noout -dates

# Verify certificate matches domain
openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout | grep -A 1 "Subject Alternative Name"

# Test certificate
openssl s_client -connect ztpboot.example.com:443 -servername ztpboot.example.com < /dev/null
```

### Solutions

**Issue: Certificate expired**
```bash
# Renew Let's Encrypt certificate
sudo certbot renew

# Copy renewed certificate
sudo cp /etc/letsencrypt/live/ztpboot.example.com/fullchain.pem /opt/containerdata/certs/wild/
sudo cp /etc/letsencrypt/live/ztpboot.example.com/privkey.pem /opt/containerdata/certs/wild/

# Restart service
sudo systemctl restart ztpbootstrap
```

**Issue: Certificate doesn't match domain**
- Obtain new certificate with correct domain
- Or update domain in configuration to match certificate

**Issue: Self-signed certificate rejected**
- For production: Use Let's Encrypt or organization CA
- For testing: Devices may need to accept self-signed certs
- Consider using HTTP-only mode for lab environments

**Issue: Certificate chain incomplete**
```bash
# Verify full chain
openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout | grep -c "BEGIN CERTIFICATE"
# Should show 2 or more certificates (leaf + chain)

# If missing, download intermediate certificates
# and append to fullchain.pem
```

## Bootstrap Script Issues

### Symptoms
- Script not served correctly
- Script syntax errors
- Script doesn't execute on device

### Diagnosis

```bash
# Download and check script
curl -k https://ztpboot.example.com/bootstrap.py > /tmp/test-bootstrap.py

# Check Python syntax
python3 -m py_compile /tmp/test-bootstrap.py

# Check file content
head -50 /tmp/test-bootstrap.py

# Check response headers
curl -k -I https://ztpboot.example.com/bootstrap.py
```

### Solutions

**Issue: Script not found (404)**
```bash
# Verify file exists
ls -la /opt/containerdata/ztpbootstrap/bootstrap.py

# Check nginx root directory
grep "root" /opt/containerdata/ztpbootstrap/nginx.conf

# Verify volume mount
podman inspect ztpbootstrap | grep -A 5 Mounts
```

**Issue: Script has wrong content-type**
- Check nginx.conf location blocks
- Verify Content-Type headers are set correctly
- Should be: `text/plain; charset=utf-8`

**Issue: Script not executable**
```bash
# Script doesn't need to be executable (served as text)
# But check file permissions
ls -la /opt/containerdata/ztpbootstrap/bootstrap.py
```

**Issue: Script configuration incorrect**
```bash
# Check CVaaS settings in bootstrap.py
grep -A 5 "cvAddr\|enrollmentToken" /opt/containerdata/ztpbootstrap/bootstrap.py

# Verify enrollment token is set
# Token should be a JWT (starts with eyJ...)
```

## Device Enrollment Failures

### Symptoms
- Device boots but doesn't enroll
- Device can't reach CVaaS
- Enrollment token errors

### Diagnosis

```bash
# Check device can reach bootstrap script
# (From device console)
curl -k https://ztpboot.example.com/bootstrap.py

# Check device can reach CVaaS
# (From device console)
ping www.arista.io

# Check bootstrap script execution
# (From device console - check logs)
show logging | grep -i bootstrap
```

### Solutions

**Issue: Device can't download bootstrap script**
- Verify DHCP Option 67 is configured correctly
- Check URL matches exactly (including https://)
- Verify network connectivity from device
- Check firewall rules

**Issue: Enrollment token invalid**
- Verify token in bootstrap.py matches CVaaS
- Check token hasn't expired
- Regenerate token in CVaaS if needed
- Token format should be JWT (starts with eyJ...)

**Issue: Device can't reach CVaaS**
- Check network connectivity
- Verify proxy settings if behind proxy
- Check DNS resolution
- Verify firewall allows outbound HTTPS

**Issue: Wrong CVaaS address**
- Verify cvAddr in bootstrap.py
- Use www.arista.io for automatic redirection
- Or use specific regional URL if needed

## Configuration Problems

### Symptoms
- Configuration not applied
- Wrong values in files
- Validation errors

### Diagnosis

```bash
# Validate configuration
./validate-config.sh config.yaml

# Check config diff
./dev/scripts/config-diff.sh config.yaml

# Verify file contents
grep -r "cvAddr" /opt/containerdata/ztpbootstrap/
```

### Solutions

**Issue: Configuration not updating files**
```bash
# Manually run update script
./update-config.sh config.yaml

# Check for errors
./validate-config.sh config.yaml

# Verify yq is installed
command -v yq
```

**Issue: Validation errors**
- Fix errors shown by validate-config.sh
- Common issues: invalid IPs, ports out of range, missing required fields
- Review config.yaml.template for correct format

**Issue: Paths incorrect**
- Verify all paths in config.yaml are absolute
- Check directories exist or can be created
- Verify permissions on parent directories

## Performance Issues

### Symptoms
- Slow response times
- Timeouts
- High resource usage

### Diagnosis

```bash
# Check container resources
podman stats ztpbootstrap

# Check system resources
top
htop

# Check nginx access logs
podman exec ztpbootstrap tail -f /var/log/nginx/ztpbootstrap_access.log

# Test response time
time curl -k https://ztpboot.example.com/bootstrap.py
```

### Solutions

**Issue: High CPU usage**
- Check for excessive requests
- Review nginx worker processes
- Consider rate limiting

**Issue: High memory usage**
- Check container memory limits
- Review nginx configuration
- Consider increasing container memory

**Issue: Slow response times**
- Check network latency
- Verify DNS resolution speed
- Check for network congestion
- Review nginx caching settings

## Getting More Help

### Enable Debug Logging

```bash
# Increase nginx log level
# Edit nginx.conf and change:
error_log /var/log/nginx/ztpbootstrap_error.log debug;

# Restart service
sudo systemctl restart ztpbootstrap

# View detailed logs
journalctl -u ztpbootstrap -f
```

### Run Diagnostic Scripts

```bash
# Run all tests
./ci-test.sh
sudo ./integration-test.sh
sudo ./test-service.sh

# Check configuration
./validate-config.sh config.yaml
```

### Collect Information for Support

```bash
# Create diagnostic package
mkdir -p /tmp/ztpbootstrap-diagnostics
cp /opt/containerdata/ztpbootstrap/*.conf /tmp/ztpbootstrap-diagnostics/
cp /opt/containerdata/ztpbootstrap/*.py /tmp/ztpbootstrap-diagnostics/
podman logs ztpbootstrap > /tmp/ztpbootstrap-diagnostics/container.log
journalctl -u ztpbootstrap > /tmp/ztpbootstrap-diagnostics/systemd.log
systemctl status ztpbootstrap > /tmp/ztpbootstrap-diagnostics/status.txt
tar -czf ztpbootstrap-diagnostics.tar.gz -C /tmp ztpbootstrap-diagnostics
```

## Prevention

### Best Practices

1. **Regular Monitoring**
   - Set up health checks
   - Monitor certificate expiration
   - Check logs regularly

2. **Backup Configuration**
   - Keep backups of config.yaml
   - Document custom configurations
   - Version control configuration files

3. **Test Before Production**
   - Use integration tests
   - Test in lab environment first
   - Verify with test devices

4. **Keep Updated**
   - Update dependencies regularly
   - Renew certificates before expiration
   - Review security updates

5. **Documentation**
   - Document custom configurations
   - Keep network diagrams
   - Maintain change logs
