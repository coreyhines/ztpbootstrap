#!/bin/bash
# Robust password fix that ensures hash is written correctly
# This script uses Python to write the hash to avoid shell/yq escaping issues

set -euo pipefail

CONFIG_FILE="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}/config.yaml"
PASSWORD="${1:-ztpboot123}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

echo "=== Robust Password Hash Fix ==="
echo "Password: $PASSWORD"
echo ""

# Generate hash using Python (same method as webui)
PASSWORD_HASH=$(echo -n "$PASSWORD" | python3 <<'PYTHON_GEN'
import sys
import hashlib
import base64

password = sys.stdin.read()
if len(password) == 0:
    sys.stderr.write("ERROR: Empty password!\n")
    sys.exit(1)

# Generate hash using exact same method as webui fallback format
hash_bytes = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)
hash_b64 = base64.b64encode(hash_bytes).decode('utf-8')
hash_value = f'pbkdf2:sha256:{hash_b64}'

# Verify hash length
if len(hash_value) != 58:
    sys.stderr.write(f"ERROR: Hash length incorrect! Got {len(hash_value)}, expected 58\n")
    sys.exit(1)

# Verify we can decode it back
try:
    decoded = base64.b64decode(hash_b64)
    if len(decoded) != 32:
        sys.stderr.write(f"ERROR: Decoded hash length incorrect! Got {len(decoded)}, expected 32\n")
        sys.exit(1)
except Exception as e:
    sys.stderr.write(f"ERROR: Failed to decode hash: {e}\n")
    sys.exit(1)

print(hash_value)
PYTHON_GEN
)

if [[ -z "$PASSWORD_HASH" ]]; then
    echo "ERROR: Failed to generate password hash"
    exit 1
fi

echo "Generated hash: $PASSWORD_HASH"
echo "Hash length: ${#PASSWORD_HASH}"
echo ""

# Backup config file
BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "Backed up config to: $BACKUP_FILE"
echo ""

# Update config using Python (more reliable than yq for special characters)
echo "Updating config.yaml using Python..."
python3 <<PYTHON_UPDATE
import yaml
from pathlib import Path
import sys

config_file = Path("$CONFIG_FILE")
password_hash = "$PASSWORD_HASH"

# Read existing config
with open(config_file, 'r') as f:
    config = yaml.safe_load(f) or {}

# Ensure auth section exists
if 'auth' not in config:
    config['auth'] = {}

# Set password hash
config['auth']['admin_password_hash'] = password_hash

# Write back using atomic write
import tempfile
import shutil

with tempfile.NamedTemporaryFile(mode='w', delete=False, dir=config_file.parent) as tmp:
    yaml.dump(config, tmp, default_flow_style=False, sort_keys=False, allow_unicode=True)
    tmp_path = tmp.name

# Atomic replace
shutil.move(tmp_path, config_file)

print("Config updated successfully")
PYTHON_UPDATE

if [[ $? -ne 0 ]]; then
    echo "ERROR: Failed to update config.yaml"
    exit 1
fi

echo ""
echo "Verifying hash was written correctly..."
VERIFIED_HASH=$(python3 <<PYTHON_VERIFY
import yaml
from pathlib import Path

config_file = Path("$CONFIG_FILE")
with open(config_file, 'r') as f:
    config = yaml.safe_load(f) or {}

hash_value = config.get('auth', {}).get('admin_password_hash', '')
print(hash_value)
PYTHON_VERIFY
)

if [[ "$VERIFIED_HASH" != "$PASSWORD_HASH" ]]; then
    echo "✗ ERROR: Hash mismatch after writing!"
    echo "  Expected: $PASSWORD_HASH"
    echo "  Got:      $VERIFIED_HASH"
    exit 1
fi

echo "✓ Hash verified in config.yaml"
echo ""

# Test password verification
echo "Testing password verification..."
python3 <<PYTHON_TEST
import sys
import hashlib
import base64
from pathlib import Path

password = "$PASSWORD"
hash_value = "$PASSWORD_HASH"

print(f"Password: '{password}' (length: {len(password)})")
print(f"Hash: {hash_value}")

if not hash_value.startswith('pbkdf2:sha256:'):
    print("ERROR: Hash format incorrect!")
    sys.exit(1)

if '$' in hash_value:
    print("ERROR: Hash contains '$' character (should use fallback format)")
    sys.exit(1)

# Extract and decode hash
hash_part = hash_value.split(':', 2)[2]
stored_hash = base64.b64decode(hash_part)

# Compute hash
computed_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)

print(f"Stored hash: {len(stored_hash)} bytes, first 10: {stored_hash[:10].hex()}")
print(f"Computed hash: {len(computed_hash)} bytes, first 10: {computed_hash[:10].hex()}")

if stored_hash == computed_hash:
    print("✓ Password verification successful!")
else:
    print("✗ ERROR: Password verification failed!")
    print("  Stored:   {stored_hash[:10].hex()}")
    print("  Computed: {computed_hash[:10].hex()}")
    sys.exit(1)
PYTHON_TEST

if [[ $? -ne 0 ]]; then
    echo ""
    echo "ERROR: Password verification test failed!"
    exit 1
fi

echo ""
echo "=== Password hash updated successfully! ==="
echo ""
echo "Next steps:"
echo "1. Restart webui service: sudo systemctl restart ztpbootstrap-webui"
echo "2. Try logging in with password: $PASSWORD"
echo ""
