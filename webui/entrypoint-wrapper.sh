#!/bin/sh
# Wrapper for Kea entrypoint that skips DB init for memfile backends

# Check if config uses memfile (no database init needed)
if [ -f /etc/kea/kea-dhcp4.conf ]; then
    # Try to extract database type from config
    DB_TYPE=$(jq -r '.Dhcp4."hosts-database".type // .Dhcp4."lease-database".type // "memfile"' /etc/kea/kea-dhcp4.conf 2>/dev/null || echo "memfile")

    if [ "$DB_TYPE" = "memfile" ]; then
        echo "[+] Using memfile backend, skipping database initialization"
        # Skip the entrypoint's db-init and go straight to exec
        exec "$@"
    fi
fi

# For PostgreSQL/MySQL, run the original entrypoint
exec /usr/local/bin/entrypoint.sh "$@"
