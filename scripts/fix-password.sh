#!/bin/bash
# Fix password by regenerating hash and updating config

set -euo pipefail

CONFIG_FILE="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}/config.yaml"
PASSWORD="${1:-ztpboot123}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

echo "Regenerating password hash for: $PASSWORD"
echo ""

# Generate hash using the exact same method as setup script
PASSWORD_HASH=$(echo "$PASSWORD" | python3 2>/dev/null <<'PYTHON_SCRIPT'
import sys
password = sys.stdin.read().rstrip('\n')
try:
    from werkzeug.security import generate_password_hash
    hash_value = generate_password_hash(password)
    print(hash_value)
except ImportError:
    # Werkzeug not available, fall back to hashlib
    import hashlib
    import base64
    hash_value = 'pbkdf2:sha256:' + base64.b64encode(hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)).decode()
    print(hash_value)
PYTHON_SCRIPT
)

if [[ -z "$PASSWORD_HASH" ]]; then
    echo "ERROR: Failed to generate password hash"
    exit 1
fi

echo "Generated hash: ${PASSWORD_HASH:0:50}..."
echo "Hash length: ${#PASSWORD_HASH}"
echo ""

# Backup config file
BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "Backed up config to: $BACKUP_FILE"
echo ""

# Update config using yq or Python
if command -v yq >/dev/null 2>&1; then
    echo "Updating config.yaml using yq..."
    yq eval ".auth.admin_password_hash = \"$PASSWORD_HASH\"" -i "$CONFIG_FILE"
else
    echo "Updating config.yaml using Python..."
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

print("Config updated successfully")
EOF
fi

echo ""
echo "Verifying hash was written correctly..."
if command -v yq >/dev/null 2>&1; then
    VERIFIED_HASH=$(yq eval '.auth.admin_password_hash // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ "$VERIFIED_HASH" == "$PASSWORD_HASH" ]]; then
        echo "✓ Hash verified in config.yaml"
    else
        echo "✗ Hash mismatch! Expected: ${PASSWORD_HASH:0:30}..., Got: ${VERIFIED_HASH:0:30}..."
        exit 1
    fi
fi

echo ""
echo "Testing password verification..."
# Use stdin to pass password (same as webui does)
echo "$PASSWORD" | python3 <<PYTHON_VERIFY
import sys
import hashlib
import base64

password = sys.stdin.read().rstrip('\n')
hash_value = "$PASSWORD_HASH"

print(f"Password received: '{password}' (length: {len(password)})")
print(f"Hash: {hash_value[:50]}...")

if hash_value.startswith('pbkdf2:sha256:') and '\$' not in hash_value:
    hash_part = hash_value.split(':', 2)[2]
    stored_hash = base64.b64decode(hash_part)
    computed_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)
    match = (stored_hash == computed_hash)
    print(f"Stored hash length: {len(stored_hash)}")
    print(f"Computed hash length: {len(computed_hash)}")
    print(f"Verification test: {match}")
    if not match:
        print("ERROR: Password verification failed!")
        print("This means the hash was generated with a different password.")
        sys.exit(1)
else:
    try:
        from werkzeug.security import check_password_hash
        match = check_password_hash(hash_value, password)
        print(f"Verification test: {match}")
        if not match:
            print("ERROR: Password verification failed!")
            sys.exit(1)
    except ImportError:
        print("ERROR: werkzeug not available for verification")
        sys.exit(1)

print("✓ Password verification successful!")
PYTHON_VERIFY

echo ""
echo "Password hash updated successfully!"
echo ""
echo "Next steps:"
echo "1. Restart webui service: sudo systemctl restart ztpbootstrap-webui"
echo "2. Try logging in with password: $PASSWORD"
