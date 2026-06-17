#!/bin/sh
# Start Kea DHCP services (image built from kea/Containerfile, tagged ztpbootstrap-kea:3.0)
# No runtime package installation - all binaries are baked into the image

set -e

echo "Starting Kea DHCP services..."

# Wait for PostgreSQL to be ready and initialize Kea schema
if [ -n "${POSTGRES_HOST:-}" ] || grep -q '"type": *"postgresql"' /etc/kea/kea-dhcp4.conf 2>/dev/null || grep -q '"type": *"postgresql"' /etc/kea/kea-dhcp6.conf 2>/dev/null; then
    PG_HOST="${POSTGRES_HOST:-127.0.0.1}"
    PG_PORT="${POSTGRES_PORT:-5432}"
    echo "Waiting for PostgreSQL at ${PG_HOST}:${PG_PORT}..."
    RETRIES=30
    while [ $RETRIES -gt 0 ]; do
        if nc -z "${PG_HOST}" "${PG_PORT}" 2>/dev/null; then
            echo "PostgreSQL is ready"
            break
        fi
        RETRIES=$((RETRIES - 1))
        echo "Waiting for PostgreSQL... ($RETRIES retries left)"
        sleep 2
    done
    if [ $RETRIES -eq 0 ]; then
        echo "ERROR: PostgreSQL not ready after 60 seconds, starting Kea anyway..."
    fi

    # Initialize/upgrade Kea schema
    PG_USER="${POSTGRES_USER:-kea}"
    PG_DB="${POSTGRES_DB:-kea}"
    if [ -n "${POSTGRES_PASSWORD:-}" ]; then
        echo "Running Kea schema init/upgrade for PostgreSQL..."
        kea-admin db-init pgsql -h "${PG_HOST}" -p "${PG_PORT}" -u "${PG_USER}" -d "${PG_DB}" -P "${POSTGRES_PASSWORD}" 2>&1 || true
        kea-admin db-upgrade pgsql -h "${PG_HOST}" -p "${PG_PORT}" -u "${PG_USER}" -d "${PG_DB}" -P "${POSTGRES_PASSWORD}" 2>&1 || true
    fi
fi

# Start kea-dhcp4 in background if config exists
if [ -f /etc/kea/kea-dhcp4.conf ]; then
    echo "Starting kea-dhcp4..."
    /usr/sbin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf &
    DHCP4_PID=$!
    echo "Started kea-dhcp4 (PID: $DHCP4_PID)"
    sleep 1
fi

# Start kea-dhcp6 in background if config exists
if [ -f /etc/kea/kea-dhcp6.conf ]; then
    echo "Starting kea-dhcp6..."
    /usr/sbin/kea-dhcp6 -c /etc/kea/kea-dhcp6.conf &
    DHCP6_PID=$!
    echo "Started kea-dhcp6 (PID: $DHCP6_PID)"
    sleep 1
fi

# Start kea-ctrl-agent in foreground (main process keeps container alive)
if [ -f /etc/kea/kea-ctrl-agent.conf ]; then
    echo "Starting kea-ctrl-agent..."
    exec /usr/sbin/kea-ctrl-agent -c /etc/kea/kea-ctrl-agent.conf
else
    echo "No kea-ctrl-agent.conf found, waiting for background processes..."
    wait
fi
