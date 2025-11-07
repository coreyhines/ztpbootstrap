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
- `/etc/containers/systemd/ztpbootstrap/ztpbootstrap.container` - Systemd quadlet configuration

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
```bash
sudo /opt/containerdata/ztpbootstrap/setup.sh
```

### 4. Verify the Service
```bash
# Check service status
sudo systemctl status ztpbootstrap.container

# Test the endpoints
curl -k https://ztpboot.example.com/health
curl -k https://ztpboot.example.com/bootstrap.py
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
sudo systemctl start ztpbootstrap.container

# Stop service
sudo systemctl stop ztpbootstrap.container

# Restart service
sudo systemctl restart ztpbootstrap.container

# View logs
sudo journalctl -u ztpbootstrap.container -f

# Check status
sudo systemctl status ztpbootstrap.container
```

## 🧪 Testing

Run the test script to verify everything is working:
```bash
sudo /opt/containerdata/ztpbootstrap/test-service.sh
```

## 📚 Documentation

- Complete documentation: `/opt/containerdata/ztpbootstrap/README.md`
- Arista ZTP documentation: https://www.arista.com/en/support/documentation

## 🔍 Troubleshooting

### Common Issues:

1. **Service won't start**: Check logs with `sudo journalctl -u ztpbootstrap.container`
2. **SSL issues**: Verify certificates with `openssl x509 -in /opt/containerdata/certs/wild/fullchain.pem -text -noout`
3. **Network issues**: Ensure IPs are assigned with `ip addr show`
4. **Bootstrap script issues**: Verify environment variables are set correctly

### Getting Help:
- Check the logs: `sudo journalctl -u ztpbootstrap.container -f`
- Run the test script: `sudo /opt/containerdata/ztpbootstrap/test-service.sh`
- Review the README: `cat /opt/containerdata/ztpbootstrap/README.md`

---

**Ready to go!** Just set your enrollment token and run the setup script to start serving Arista ZTP bootstrap scripts over HTTPS.
