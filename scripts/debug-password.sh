#!/bin/bash
# Comprehensive password debugging script

set -euo pipefail

CONFIG_FILE="${ZTP_CONFIG_DIR:-/opt/containerdata/ztpbootstrap}/config.yaml"
PASSWORD="${1:-ztpboot123}"

echo "=== Comprehensive Password Debug ==="
echo ""

# 1. Check config file hash
echo "1. Hash in config.yaml:"
if command -v yq >/dev/null 2>&1; then
    HASH_FROM_CONFIG=$(yq eval '.auth.admin_password_hash // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    echo "   Hash: $HASH_FROM_CONFIG"
    echo "   Length: ${#HASH_FROM_CONFIG}"
    echo "   Starts with pbkdf2:sha256:: $([ "${HASH_FROM_CONFIG#pbkdf2:sha256:}" != "$HASH_FROM_CONFIG" ] && echo "yes" || echo "no")"
    echo "   Contains \$: $([ "\$" in "$HASH_FROM_CONFIG" ] && echo "yes" || echo "no")"
    echo "   Ends with =: $([ "${HASH_FROM_CONFIG: -1}" == "=" ] && echo "yes" || echo "no")"
else
    echo "   ERROR: yq not found"
    exit 1
fi

echo ""

# 2. Generate a fresh hash for comparison
echo "2. Generating fresh hash for '$PASSWORD':"
FRESH_HASH=$(echo "$PASSWORD" | python3 2>/dev/null <<'PYTHON'
import sys
import hashlib
import base64
password = sys.stdin.read().rstrip('\n')
hash_value = 'pbkdf2:sha256:' + base64.b64encode(hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)).decode()
print(hash_value)
PYTHON
)
echo "   Fresh hash: $FRESH_HASH"
echo "   Length: ${#FRESH_HASH}"
echo "   Matches config: $([ "$FRESH_HASH" == "$HASH_FROM_CONFIG" ] && echo "yes" || echo "no")"

echo ""

# 3. Test verification with config hash
echo "3. Testing password verification with hash from config:"
VERIFY_RESULT=$(echo "$PASSWORD" | python3 2>/dev/null <<PYTHON_VERIFY
import sys
import hashlib
import base64

password = sys.stdin.read().rstrip('\n')
hash_value = "$HASH_FROM_CONFIG"

print(f"   Password: '{password}' (length: {len(password)})")
print(f"   Hash: {hash_value[:50]}... (length: {len(hash_value)})")

if hash_value.startswith('pbkdf2:sha256:') and '\$' not in hash_value:
    hash_part = hash_value.split(':', 2)[2]
    print(f"   Hash part (base64): {hash_part[:30]}... (length: {len(hash_part)})")
    try:
        stored_hash = base64.b64decode(hash_part)
        print(f"   Decoded stored hash length: {len(stored_hash)} bytes")
        computed_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)
        print(f"   Computed hash length: {len(computed_hash)} bytes")
        match = (stored_hash == computed_hash)
        print(f"   Verification result: {match}")
        if not match:
            print("   ERROR: Hashes don't match!")
            # Show first few bytes for debugging
            print(f"   Stored (first 8 bytes): {stored_hash[:8].hex()}")
            print(f"   Computed (first 8 bytes): {computed_hash[:8].hex()}")
    except Exception as e:
        print(f"   ERROR during verification: {type(e).__name__}: {e}")
else:
    print("   Hash format doesn't match expected pbkdf2:sha256: format")
PYTHON_VERIFY
)
echo "$VERIFY_RESULT"

echo ""

# 4. Check what webui container sees
echo "4. Checking what webui container sees:"
WEBUI_HASH=$(sudo podman exec ztpbootstrap-webui python3 2>/dev/null <<'PYTHON_WEBUI'
import yaml
from pathlib import Path

config_file = Path('/opt/containerdata/ztpbootstrap/config.yaml')
if config_file.exists():
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
    hash_value = config.get('auth', {}).get('admin_password_hash', 'NOT FOUND')
    print(hash_value)
    print(f"LENGTH:{len(hash_value)}")
else:
    print("CONFIG_FILE_NOT_FOUND")
PYTHON_WEBUI
2>/dev/null || echo "ERROR_ACCESSING_CONTAINER")

if [[ "$WEBUI_HASH" == *"LENGTH:"* ]]; then
    WEBUI_HASH_VALUE=$(echo "$WEBUI_HASH" | head -1)
    WEBUI_HASH_LENGTH=$(echo "$WEBUI_HASH" | grep "LENGTH:" | cut -d: -f2)
    echo "   Hash in container: ${WEBUI_HASH_VALUE:0:50}..."
    echo "   Length in container: $WEBUI_HASH_LENGTH"
    echo "   Matches config file: $([ "$WEBUI_HASH_VALUE" == "$HASH_FROM_CONFIG" ] && echo "yes" || echo "no")"
else
    echo "   ERROR: Could not access webui container or read config"
    echo "   Output: $WEBUI_HASH"
fi

echo ""

# 5. Test verification in webui container
echo "5. Testing verification in webui container:"
WEBUI_VERIFY=$(echo "$PASSWORD" | sudo podman exec -i ztpbootstrap-webui python3 2>/dev/null <<'PYTHON_WEBUI_VERIFY'
import sys
import yaml
import hashlib
import base64
from pathlib import Path

password = sys.stdin.read().rstrip('\n')
config_file = Path('/opt/containerdata/ztpbootstrap/config.yaml')

if config_file.exists():
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
    hash_value = config.get('auth', {}).get('admin_password_hash', '')
    
    if hash_value.startswith('pbkdf2:sha256:') and '$' not in hash_value:
        hash_part = hash_value.split(':', 2)[2]
        stored_hash = base64.b64decode(hash_part)
        computed_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), b'ztpbootstrap', 100000)
        match = (stored_hash == computed_hash)
        print(f"MATCH:{match}")
        print(f"STORED_LEN:{len(stored_hash)}")
        print(f"COMPUTED_LEN:{len(computed_hash)}")
    else:
        print("FORMAT_ERROR")
else:
    print("CONFIG_NOT_FOUND")
PYTHON_WEBUI_VERIFY
2>/dev/null || echo "ERROR")

if [[ "$WEBUI_VERIFY" == *"MATCH:"* ]]; then
    MATCH_RESULT=$(echo "$WEBUI_VERIFY" | grep "MATCH:" | cut -d: -f2)
    STORED_LEN=$(echo "$WEBUI_VERIFY" | grep "STORED_LEN:" | cut -d: -f2)
    COMPUTED_LEN=$(echo "$WEBUI_VERIFY" | grep "COMPUTED_LEN:" | cut -d: -f2)
    echo "   Verification in container: $MATCH_RESULT"
    echo "   Stored hash length: $STORED_LEN bytes"
    echo "   Computed hash length: $COMPUTED_LEN bytes"
else
    echo "   ERROR: Could not test verification in container"
    echo "   Output: $WEBUI_VERIFY"
fi

echo ""
echo "=== Debug Complete ==="

