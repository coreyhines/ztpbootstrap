#!/bin/sh
# Start all Kea services (dhcp4, dhcp6, ctrl-agent)
# This script runs the entrypoint first to initialize the database,
# then starts all three services
# If kea-ctrl-agent is not found, it will attempt to install it

# Don't exit on error - we want to handle errors gracefully
set +e

echo "Starting Kea services..."

# First, run the entrypoint to initialize/upgrade the database
# This is necessary for PostgreSQL backends
# The official ISC image uses kea-db-init-upgrade for schema management
if [ -f /usr/local/bin/entrypoint.sh ]; then
    echo "Running database initialization/upgrade..."
    # Run entrypoint with a dummy command to trigger DB upgrade
    /usr/local/bin/entrypoint.sh /bin/true 2>&1 || {
        echo "Database initialization completed (exit code may be non-zero, continuing)..."
    }
fi

# Try to install kea-ctrl-agent if not found
if ! command -v kea-ctrl-agent >/dev/null 2>&1 && \
   [ ! -f /usr/sbin/kea-ctrl-agent ] && \
   [ ! -f /usr/bin/kea-ctrl-agent ]; then
    echo "kea-ctrl-agent not found, attempting to install..."

    # Try different package managers
    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing kea-ctrl-agent via apt-get..."
        apt-get update -qq && apt-get install -y -qq isc-kea-ctrl-agent || echo "Failed to install via apt-get"
    elif command -v yum >/dev/null 2>&1; then
        echo "Installing kea-ctrl-agent via yum..."
        yum install -y -q isc-kea-ctrl-agent || echo "Failed to install via yum"
    elif command -v dnf >/dev/null 2>&1; then
        echo "Installing kea-ctrl-agent via dnf..."
        dnf install -y -q isc-kea-ctrl-agent || echo "Failed to install via dnf"
    elif command -v apk >/dev/null 2>&1; then
        echo "Installing kea-ctrl-agent via apk..."
        apk add --no-cache -q isc-kea-ctrl-agent || echo "Failed to install via apk"
    else
        echo "No package manager found, cannot install kea-ctrl-agent"
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

# Start kea-ctrl-agent in foreground (main process)
if [ -f /etc/kea/kea-ctrl-agent.conf ]; then
    echo "Starting kea-ctrl-agent..."
    # Try different possible paths for kea-ctrl-agent
    CTRL_AGENT=""
    if command -v kea-ctrl-agent >/dev/null 2>&1; then
        CTRL_AGENT=$(command -v kea-ctrl-agent)
    elif [ -f /usr/sbin/kea-ctrl-agent ]; then
        CTRL_AGENT=/usr/sbin/kea-ctrl-agent
    elif [ -f /usr/bin/kea-ctrl-agent ]; then
        CTRL_AGENT=/usr/bin/kea-ctrl-agent
    elif [ -f /usr/local/sbin/kea-ctrl-agent ]; then
        CTRL_AGENT=/usr/local/sbin/kea-ctrl-agent
    elif [ -f /usr/local/bin/kea-ctrl-agent ]; then
        CTRL_AGENT=/usr/local/bin/kea-ctrl-agent
    fi

    if [ -n "$CTRL_AGENT" ]; then
        echo "Found kea-ctrl-agent at: $CTRL_AGENT"
        exec "$CTRL_AGENT" -c /etc/kea/kea-ctrl-agent.conf
    else
        # If ctrl-agent not found, log a warning but keep the container running
        # The DHCP servers (dhcp4/dhcp6) will still work, just without API access
        echo "WARNING: kea-ctrl-agent not found. DHCP servers will run but API access will be unavailable."
        echo "DHCP servers are running in the background. Container will stay alive."
        # Keep container running by waiting for background processes
        wait
    fi
else
    # If no ctrl-agent config, just wait for background processes
    echo "No kea-ctrl-agent.conf found, waiting for background processes..."
    wait
fi
