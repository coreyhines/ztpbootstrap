# Arista ZTP Bootstrap Service - Setup Instructions

## ✅ What's Been Created

The following components have been set up for your Arista ZTP Bootstrap service:

### Files Created:
- `/opt/containerdata/ztpbootstrap/bootstrap.py` - Enhanced bootstrap script with environment variable support
- `/opt/containerdata/ztpbootstrap/nginx.conf` - Nginx configuration for HTTPS serving
- `/opt/containerdata/ztpbootstrap/ztpbootstrap.env` - Environment configuration file
- `/opt/containerdata/ztpbootstrap/ztpbootstrap.env.template` - Template for configuration
- `/opt/containerdata/ztpbootstrap/setup.sh` - Automated setup script
- `/opt/containerdata/ztpbootstrap/test-service.sh` - Service testing script
- `/opt/containerdata/ztpbootstrap/README.md` - Complete documentation
- `/etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod` - Pod definition
- `/etc/containers/systemd/ztpbootstrap/ztpbootstrap-nginx.container` - Nginx container definition
- `/etc/containers/systemd/ztpbootstrap/ztpbootstrap-webui.container` - Web UI container definition (optional)

### Network Configuration:
- **IPv4**: `10.0.0.10`
- **IPv6**: `2001:db8::10`
- **Hostname**: `ztpboot.example.com`
- **SSL Certificates**: Using wildcard certificates from `/opt/containerdata/certs/wild/`

## 🚀 Next Steps to Complete Setup

### 1. Assign Network IPs
```bash
# Add the IPv4 address to your network interface
sudo ip addr add 10.0.0.10/24 dev <interface>

# Add the IPv6 address (if needed)
sudo ip -6 addr add 2001:db8::10/64 dev <interface>
```

### 2. Configure Environment Variables
```bash
# Edit the environment file
sudo vi /opt/containerdata/ztpbootstrap/ztpbootstrap.env

# Set your CVaaS enrollment token
ENROLLMENT_TOKEN=your_actual_enrollment_token_here
```

### 3. Run the Setup Script

**Standard HTTPS Setup (Recommended):**
```bash
sudo /opt/containerdata/ztpbootstrap/setup.sh
```

**HTTP-Only Setup (NOT RECOMMENDED - Insecure):**
```bash
sudo /opt/containerdata/ztpbootstrap/setup.sh --http-only
```

⚠️ **Warning**: HTTP-only mode is insecure and should only be used in isolated lab environments. All traffic will be unencrypted and vulnerable to interception. Let's Encrypt certificates can be fully automated with certbot and systemd timers, making HTTPS setup nearly as simple as HTTP while providing proper security.

### 4. Verify the Service
```bash
# Check pod status
sudo systemctl status ztpbootstrap-pod

# Check individual container status
sudo podman ps --filter pod=ztpbootstrap-pod

# Test the endpoints
curl -k https://ztpboot.example.com/health
curl -k https://ztpboot.example.com/bootstrap.py

# Access Web UI (if enabled)
# Navigate to: https://ztpboot.example.com/ui/
```

## 🔧 Configuration Details

### Environment Variables to Set:
- `CV_ADDR`: CVaaS address (default: `www.arista.io`)
- `ENROLLMENT_TOKEN`: **REQUIRED** - Get from CVaaS Device Registration page
- `CV_PROXY`: Optional proxy URL
- `EOS_URL`: Optional EOS image URL for upgrades
- `NTP_SERVER`: Optional NTP server (default: `ntp1.aristanetworks.com`)

### SSL Certificates:
✅ **Already configured** - Using wildcard certificates from `/opt/containerdata/certs/wild/`
- Certificate: `fullchain.pem`
- Private Key: `privkey.pem`
- Covers: `*.example.com` (includes `ztpboot.example.com`)
- Expires: October 30, 2025

## 📋 DHCP Configuration

Configure your DHCP server to point devices to the bootstrap script:

```dhcp
subnet 10.0.0.0 netmask 255.255.255.0 {
    range 10.0.0.100 10.0.0.200;
    option routers 10.0.0.1;
    option domain-name-servers 8.8.8.8;
    option bootfile-name "https://ztpboot.example.com/bootstrap.py";
}
```

## 🛠️ Service Management

```bash
# Start service
sudo systemctl start ztpbootstrap-pod

# Stop service
sudo systemctl stop ztpbootstrap-pod

# Restart service
sudo systemctl restart ztpbootstrap-pod

# View logs
sudo journalctl -u ztpbootstrap-pod -f

# Check status
sudo systemctl status ztpbootstrap-pod

# Check individual container logs
sudo podman logs ztpbootstrap-nginx
sudo podman logs ztpbootstrap-webui
```

## 🧪 Testing

### Quick Validation Test

Run the basic test script to verify service configuration:
```bash
sudo /opt/containerdata/ztpbootstrap/test-service.sh
```

### Comprehensive Integration Test

For end-to-end testing that actually spins up a container and validates it works:
```bash
# Test HTTPS mode (requires SSL certificates)
sudo /opt/containerdata/ztpbootstrap/integration-test.sh

# Test HTTP-only mode (no certificates needed)
sudo /opt/containerdata/ztpbootstrap/integration-test.sh --http-only
```

The integration test validates:
- Container starts and runs correctly
- Health endpoint responds
- Bootstrap.py is served correctly
- Response headers are correct
- Python syntax is valid
- EOS device simulation works

### CI/CD Validation

For automated testing in CI/CD pipelines:
```bash
/opt/containerdata/ztpbootstrap/ci-test.sh
```

See the [Testing section in README.md](../README.md#testing) for more details.

## 📚 Documentation

- Complete documentation: `/opt/containerdata/ztpbootstrap/README.md`
- Arista ZTP documentation: https://www.arista.com/en/support/documentation

## 🔍 Troubleshooting

### Common Issues:

1. **Service won't start**: Check logs with `sudo journalctl -u ztpbootstrap-pod`
2. **Macvlan network missing**: Run `./check-macvlan.sh` to verify network exists
3. **SSL issues**: Verify certificates with `openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout`
4. **Network issues**: Ensure macvlan network is configured correctly
5. **Bootstrap script issues**: Verify environment variables are set correctly

### Getting Help:
- Check the logs: `sudo journalctl -u ztpbootstrap-pod -f`
- Check macvlan network: `./check-macvlan.sh`
- Run the test script: `sudo /opt/containerdata/ztpbootstrap/test-service.sh`
- Review the README: `cat /opt/containerdata/ztpbootstrap/README.md`

## 🔒 HTTP-Only Setup (Not Recommended)

<a name="http-only-setup"></a>

**⚠️ Warning: HTTP-only setup is strongly discouraged for production use.** All traffic will be unencrypted, making it vulnerable to interception and tampering. This should only be used for testing in isolated lab environments. **Let's Encrypt certificates can be fully automated** with certbot and systemd timers, making HTTPS setup nearly as simple as HTTP while providing proper security.

If you absolutely must use HTTP-only (e.g., for a completely isolated lab network with no internet access):

1. Run the setup script with the `--http-only` flag:
   ```bash
   sudo /opt/containerdata/ztpbootstrap/setup.sh --http-only
   ```

2. The script will:
   - Configure nginx to serve HTTP on port 80
   - Update the systemd quadlet configuration to remove certificate mounts
   - Back up your original configuration files

3. Update your DHCP configuration to use HTTP:
   ```dhcp
   option bootfile-name "http://ztpboot.example.com/bootstrap.py";
   ```

4. Test the service:
   ```bash
   curl http://ztpboot.example.com/health
   curl http://ztpboot.example.com/bootstrap.py
   ```

**Remember**: This configuration is insecure and should never be used in production or on networks with internet access. Consider using Let's Encrypt with automated renewal instead.

For more details, see the [HTTP-Only Setup](#http-only-setup) section in README.md.

---

**Ready to go!** Just set your enrollment token and run the setup script to start serving Arista ZTP bootstrap scripts over HTTPS (or HTTP if using insecure mode).
