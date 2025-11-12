#!/bin/bash
# Diagnostic script to troubleshoot password login issues

set -euo pipefail

CONFIG_FILE="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}/config.yaml"
PASSWORD="${1:-ztpboot123}"

echo "=== Password Login Diagnostic ==="
echo ""

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

echo "1. Reading hash from config.yaml..."
if command -v yq >/dev/null 2>&1; then
    HASH_FROM_CONFIG=$(yq eval '.auth.admin_password_hash // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
else
    echo "ERROR: yq not found. Cannot read config.yaml"
    exit 1
fi

if [[ -z "$HASH_FROM_CONFIG" ]]; then
    echo "ERROR: No password hash found in config.yaml!"
    exit 1
fi

echo "   Hash found: ${HASH_FROM_CONFIG:0:50}..."
echo "   Hash length: ${#HASH_FROM_CONFIG}"
echo "   Hash format: $(echo "$HASH_FROM_CONFIG" | cut -d: -f1)"
echo ""

# Test password verification
echo "2. Testing password verification..."
python3 <<EOF
import sys
import hashlib
import base64
from pathlib import Path

password = "$PASSWORD"
hash_from_config = "$HASH_FROM_CONFIG"

print(f"   Testing password: {password}")
print(f"   Hash from config: {hash_from_config[:50]}...")
print(f"   Hash starts with pbkdf2:sha256:: {hash_from_config.startswith('pbkdf2:sha256:')}")
print(f"   Hash contains \$: {'\$' in hash_from_config}")
print()

# Check if this is the fallback format
if hash_from_config.startswith('pbkdf2:sha256:') and '\$' not in hash_from_config:
    print("   Using fallback format verification (pbkdf2:sha256: without \$)")
    try:
        hash_part = hash_from_config.split(':', 2)[2]
        stored_hash = base64.b64decode(hash_part)
        computed_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)
        match = (stored_hash == computed_hash)
        print(f"   Stored hash length: {len(stored_hash)}")
        print(f"   Computed hash length: {len(computed_hash)}")
        print(f"   Verification result: {match}")
        if not match:
            print("   ERROR: Password verification failed!")
            print("   This means the password does not match the hash.")
    except Exception as e:
        print(f"   ERROR during verification: {type(e).__name__}: {e}")
else:
    print("   Using Werkzeug format verification")
    try:
        from werkzeug.security import check_password_hash
        match = check_password_hash(hash_from_config, password)
        print(f"   Verification result: {match}")
        if not match:
            print("   ERROR: Password verification failed!")
    except ImportError:
        print("   ERROR: werkzeug not available for verification")
    except Exception as e:
        print(f"   ERROR during verification: {type(e).__name__}: {e}")

EOF

echo ""
echo "3. Checking webui container status..."
if systemctl is-active --quiet ztpbootstrap-webui.service 2>/dev/null; then
    echo "   ✓ Webui service is running"
else
    echo "   ✗ Webui service is NOT running"
fi

echo ""
echo "4. Checking webui container access to config file..."
sudo podman exec ztpbootstrap-webui python3 <<'PYTHON_SCRIPT' 2>/dev/null || echo "   ERROR: Could not access webui container"
import yaml
from pathlib import Path

config_file = Path('/opt/containerdata/ztpbootstrap/config.yaml')
if config_file.exists():
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
    hash_value = config.get('auth', {}).get('admin_password_hash', 'NOT FOUND')
    print(f"   Hash from webui container: {hash_value[:50] if hash_value != 'NOT FOUND' else 'NOT FOUND'}...")
    print(f"   Hash length: {len(hash_value) if hash_value != 'NOT FOUND' else 0}")
    if hash_value != 'NOT FOUND':
        print(f"   Hash matches config file: {hash_value == '$HASH_FROM_CONFIG'}")
else:
    print("   ERROR: Config file not found in container")
PYTHON_SCRIPT

echo ""
echo "5. Recent webui logs (last 20 lines)..."
sudo podman logs ztpbootstrap-webui 2>&1 | tail -20 | grep -i "password\|auth\|error\|exception" || echo "   No relevant log entries found"

echo ""
echo "=== Diagnostic Complete ==="

