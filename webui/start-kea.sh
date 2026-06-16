#!/bin/sh
# Start Kea DHCP services using the official ISC Kea image (docker.io/iscorg/kea:2.6.1)
# No runtime package installation - all binaries are baked into the image

set -e

echo "Starting Kea DHCP services..."

# Initialize/upgrade database schema if using PostgreSQL backend
# The official ISC entrypoint handles db-init and db-upgrade idempotently
if [ -f /usr/local/bin/entrypoint.sh ]; then
    echo "Running database initialization..."
    /usr/local/bin/entrypoint.sh /bin/true 2>&1 || true
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
