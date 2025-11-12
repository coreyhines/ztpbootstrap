#!/bin/bash
# Reset admin password hash in config.yaml
# Usage: ./reset-password.sh [new_password]

set -euo pipefail

CONFIG_DIR="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Get password from argument or prompt
if [ $# -ge 1 ]; then
    NEW_PASSWORD="$1"
else
    echo "Enter new admin password:"
    read -s NEW_PASSWORD
    echo ""
    echo "Confirm new admin password:"
    read -s CONFIRM_PASSWORD
    echo ""
    if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
        echo "Error: Passwords do not match"
        exit 1
    fi
fi

# Validate password length
if [ ${#NEW_PASSWORD} -lt 8 ]; then
    echo "Error: Password must be at least 8 characters long"
    exit 1
fi

# Generate password hash using Python
echo "Generating password hash..."
PASSWORD_HASH=$(python3 <<EOF
from werkzeug.security import generate_password_hash
import sys
password = sys.argv[1]
hash_value = generate_password_hash(password)
print(hash_value)
EOF
"$NEW_PASSWORD")

if [ -z "$PASSWORD_HASH" ]; then
    echo "Error: Failed to generate password hash"
    exit 1
fi

echo "Generated hash: ${PASSWORD_HASH:0:50}..."

# Check if yq is available
if command -v yq &> /dev/null; then
    echo "Updating config.yaml using yq..."
    # Backup original
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Update password hash
    yq eval ".auth.admin_password_hash = \"$PASSWORD_HASH\"" -i "$CONFIG_FILE"
    
    echo "Password hash updated successfully!"
    echo "Config file: $CONFIG_FILE"
    echo "Backup created: ${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
else
    echo "yq not found. Using Python to update config..."
    
    # Backup original
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Update using Python
    python3 <<EOF
import yaml
from pathlib import Path

config_file = Path("$CONFIG_FILE")
with open(config_file, 'r') as f:
    config = yaml.safe_load(f) or {}

if 'auth' not in config:
    config['auth'] = {}

config['auth']['admin_password_hash'] = "$PASSWORD_HASH"

with open(config_file, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print("Password hash updated successfully!")
EOF
    
    echo "Config file: $CONFIG_FILE"
    echo "Backup created: ${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
fi

echo ""
echo "Next steps:"
echo "1. Restart the webui service to reload the config:"
echo "   sudo systemctl restart ztpbootstrap-webui"
echo ""
echo "2. Or restart the entire pod:"
echo "   sudo systemctl restart ztpbootstrap-pod"
echo ""
echo "3. Log in with your new password"
