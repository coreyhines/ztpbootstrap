#!/bin/bash
# Restore backup from fedora1 to VM
# Usage: ./restore-backup-from-fedora1.sh

set -euo pipefail

VM_HOST="localhost"
VM_PORT="2222"
VM_USER="corey"
FEDORA1_HOST="fedora1.freeblizz.com"
FEDORA1_USER="corey"

echo "Fetching backup from ${FEDORA1_HOST}..."
BACKUP_FILE=$(ssh "${FEDORA1_USER}@${FEDORA1_HOST}" "ls -t ~corey/ztpbootstrap-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null || echo "")

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Error: No backup found on ${FEDORA1_HOST}"
    exit 1
fi

echo "Found backup: $BACKUP_FILE"
echo "Copying to VM and restoring..."

ssh -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" << RESTORE_EOF
set -e
cd ~/ztpbootstrap

# Copy backup to VM
scp "${FEDORA1_USER}@${FEDORA1_HOST}:${BACKUP_FILE}" /tmp/backup.tar.gz

# Extract and restore
mkdir -p restore-tmp
cd restore-tmp
tar -xzf /tmp/backup.tar.gz

# Restore directories
sudo mkdir -p /opt/containerdata/ztpbootstrap
sudo mkdir -p /etc/containers/systemd/ztpbootstrap

if [ -d containerdata_ztpbootstrap ]; then
    sudo cp -r containerdata_ztpbootstrap/* /opt/containerdata/ztpbootstrap/
    echo "✓ Restored /opt/containerdata/ztpbootstrap"
fi

if [ -d etc_containers_systemd_ztpbootstrap ]; then
    sudo cp -r etc_containers_systemd_ztpbootstrap/* /etc/containers/systemd/ztpbootstrap/
    echo "✓ Restored /etc/containers/systemd/ztpbootstrap"
fi

if [ -d certs_wild ]; then
    sudo mkdir -p /opt/containerdata/certs/wild
    sudo cp -r certs_wild/* /opt/containerdata/certs/wild/
    echo "✓ Restored /opt/containerdata/certs/wild"
fi

# Set permissions
sudo chown -R root:root /opt/containerdata/ztpbootstrap
sudo chown -R root:root /etc/containers/systemd/ztpbootstrap

# Cleanup
cd ~
rm -rf restore-tmp /tmp/backup.tar.gz

# Also restore nginx.conf and ztpbootstrap.env directly from fedora1 to ensure they're correct
echo "Restoring nginx.conf and ztpbootstrap.env directly from fedora1..."
ssh ${FEDORA1_USER}@${FEDORA1_HOST} 'cat /opt/containerdata/ztpbootstrap/nginx.conf' | sudo tee /opt/containerdata/ztpbootstrap/nginx.conf > /dev/null
ssh ${FEDORA1_USER}@${FEDORA1_HOST} 'cat /opt/containerdata/ztpbootstrap/ztpbootstrap.env' | sudo tee /opt/containerdata/ztpbootstrap/ztpbootstrap.env > /dev/null
ssh ${FEDORA1_USER}@${FEDORA1_HOST} 'cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container' | sudo tee /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container > /dev/null

echo "✓ Backup restored successfully"
echo ""
echo "Restored files:"
echo "  - /opt/containerdata/ztpbootstrap/"
echo "  - /etc/containers/systemd/ztpbootstrap/"
echo "  - /opt/containerdata/certs/wild/ (if present)"
RESTORE_EOF

echo ""
echo "✓ Restore complete!"
