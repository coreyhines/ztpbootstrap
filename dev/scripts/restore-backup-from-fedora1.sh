#!/bin/bash
# Restore backup from fedora1 to VM
# Usage: ./restore-backup-from-fedora1.sh
# Can be run from host machine (SSH into VM) or from inside the VM

set -euo pipefail

VM_HOST="localhost"
VM_PORT="2222"
VM_USER="corey"
FEDORA1_HOST="fedora1.freeblizz.com"
FEDORA1_USER="corey"

# Detect if we're running inside the VM (check if we can't connect to localhost:2222)
RUNNING_IN_VM=false
if ! timeout 2 bash -c "echo > /dev/tcp/localhost/2222" 2>/dev/null; then
    RUNNING_IN_VM=true
fi

echo "Fetching backup from ${FEDORA1_HOST}..."
BACKUP_FILE=$(ssh "${FEDORA1_USER}@${FEDORA1_HOST}" "ls -t ~corey/ztpbootstrap-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null || echo "")

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Error: No backup found on ${FEDORA1_HOST}"
    exit 1
fi

echo "Found backup: $BACKUP_FILE"

# Function to perform the restore
do_restore() {
    set -e
    cd ~/ztpbootstrap

    # Copy backup (if not already here)
    if [[ ! -f "/tmp/backup.tar.gz" ]]; then
        echo "Copying backup from ${FEDORA1_HOST}..."
        scp "${FEDORA1_USER}@${FEDORA1_HOST}:${BACKUP_FILE}" /tmp/backup.tar.gz
    fi

    # Extract and restore
    echo "Extracting and restoring backup..."
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

    # Also restore key files directly from fedora1 to ensure they're correct
    echo "Restoring configuration files directly from fedora1..."
    ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'cat /opt/containerdata/ztpbootstrap/nginx.conf' | sudo tee /opt/containerdata/ztpbootstrap/nginx.conf > /dev/null
    ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'cat /opt/containerdata/ztpbootstrap/ztpbootstrap.env' | sudo tee /opt/containerdata/ztpbootstrap/ztpbootstrap.env > /dev/null
    
    # Detect if fedora1 has pod-based or single-container setup
    echo "Detecting container architecture on fedora1..."
    if ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'test -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod'; then
        echo "Detected: Pod-based architecture (ztpbootstrap.pod)"
        ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod' | sudo tee /etc/containers/systemd/ztpbootstrap/ztpbootstrap.pod > /dev/null
        ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap-nginx.container' | sudo tee /etc/containers/systemd/ztpbootstrap/ztpbootstrap-nginx.container > /dev/null
        ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap-webui.container' | sudo tee /etc/containers/systemd/ztpbootstrap/ztpbootstrap-webui.container > /dev/null
        echo "✓ Restored pod and container files"
    elif ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'test -f /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container'; then
        echo "Detected: Single-container architecture (ztpbootstrap.container)"
        ssh "${FEDORA1_USER}@${FEDORA1_HOST}" 'cat /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container' | sudo tee /etc/containers/systemd/ztpbootstrap/ztpbootstrap.container > /dev/null
        echo "✓ Restored single container file"
    else
        echo "Warning: Could not detect container architecture on fedora1"
    fi

    echo "✓ Backup restored successfully"
    echo ""
    echo "Restored files:"
    echo "  - /opt/containerdata/ztpbootstrap/"
    echo "  - /etc/containers/systemd/ztpbootstrap/"
    echo "  - /opt/containerdata/certs/wild/ (if present)"
}

# If running inside VM, execute directly
if [[ "$RUNNING_IN_VM" == "true" ]]; then
    echo "Detected: Running inside VM, restoring directly..."
    do_restore
else
    # Running from host, SSH into VM
    echo "Detected: Running from host, connecting to VM..."
    ssh -p "${VM_PORT}" "${VM_USER}@${VM_HOST}" "$(declare -f do_restore); BACKUP_FILE='${BACKUP_FILE}'; FEDORA1_USER='${FEDORA1_USER}'; FEDORA1_HOST='${FEDORA1_HOST}'; do_restore"
fi

echo ""
echo "✓ Restore complete!"
