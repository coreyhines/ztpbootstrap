#!/bin/bash
# Script to fix SSH password authentication in Fedora Cloud VM via console
# Run these commands in the VM console (after logging in as root or existing user)

cat << 'EOF'
========================================
SSH Password Authentication Fix
========================================

If you can access the VM console, run these commands:

1. Login as root (or existing user with sudo):
   - If prompted, try: root (no password) or ec2-user

2. Run these commands to fix SSH:

# Enable password authentication
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

# Create fedora user if it doesn't exist
if ! id fedora &>/dev/null; then
  useradd -m -G wheel -s /bin/bash fedora
fi

# Set password for fedora user
echo 'fedora:fedora' | chpasswd

# Restart SSH
systemctl restart sshd

# Verify SSH is running
systemctl status sshd

3. Then try SSH from host:
   ssh fedora@localhost -p 2222
   Password: fedora

========================================
EOF
