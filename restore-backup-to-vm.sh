#!/bin/bash
# Quick script to restore fedora1 backup to an existing VM
# Usage: ./restore-backup-to-vm.sh [vm-ssh-connection-string]

set -euo pipefail

BACKUP_HOST="${BACKUP_HOST:-fedora1}"
BACKUP_USER="${BACKUP_USER:-corey}"
VM_SSH="${1:-fedora@localhost -p 2222}"

# Extract host and port from VM_SSH
VM_HOST=$(echo "$VM_SSH" | awk '{print $1}' | cut -d@ -f2)
VM_USER=$(echo "$VM_SSH" | awk '{print $1}' | cut -d@ -f1)
VM_PORT=$(echo "$VM_SSH" | grep -oP '\-p\s+\K\d+' || echo "22")

echo "=========================================="
echo "Restore Backup to VM"
echo "=========================================="
echo "Backup source: ${BACKUP_USER}@${BACKUP_HOST}"
echo "VM target: ${VM_USER}@${VM_HOST}:${VM_PORT}"
echo ""

# Get backup
echo "Getting backup from ${BACKUP_HOST}..."
BACKUP_FILE=$(ssh "${BACKUP_USER}@${BACKUP_HOST}" "ls -t ~corey/ztpbootstrap-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null || echo "")

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Error: No backup found"
    exit 1
fi

echo "Found: $BACKUP_FILE"
LOCAL_BACKUP="/tmp/$(basename "$BACKUP_FILE")"
scp "${BACKUP_USER}@${BACKUP_HOST}:${BACKUP_FILE}" "$LOCAL_BACKUP" 2>/dev/null || {
    echo "Error: Failed to copy backup"
    exit 1
}

# Copy to VM and restore
echo "Copying to VM..."
scp -P "$VM_PORT" "$LOCAL_BACKUP" "${VM_USER}@${VM_HOST}:~/backup.tar.gz" 2>&1

echo "Restoring in VM..."
ssh -p "$VM_PORT" "${VM_USER}@${VM_HOST}" << 'RESTORE_EOF'
set -e
cd ~
mkdir -p restore-tmp
cd restore-tmp
tar -xzf ../backup.tar.gz

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

sudo chown -R root:root /opt/containerdata/ztpbootstrap
sudo chown -R root:root /etc/containers/systemd/ztpbootstrap

cd ~
rm -rf restore-tmp backup.tar.gz

echo "✓ Backup restored successfully"
RESTORE_EOF

rm -f "$LOCAL_BACKUP"
echo ""
echo "✅ Backup restored to VM!"
echo ""
echo "Next: SSH into VM and run interactive setup:"
echo "  ssh -p $VM_PORT ${VM_USER}@${VM_HOST}"
echo "  cd ~/ztpbootstrap"
echo "  ./setup-interactive.sh"
