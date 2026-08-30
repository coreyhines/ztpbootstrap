#!/bin/sh
# Health probe for the ztpbootstrap-dhcp container.
#
# The container runs three daemons: kea-dhcp4 and kea-dhcp6 are backgrounded by
# start-kea.sh, and kea-ctrl-agent is exec'd as PID 1. Only the ctrl-agent keeps
# the container alive, so a DHCP daemon that dies -- or never starts, because its
# config failed to parse -- leaves `podman ps` reporting Up and
# `systemctl is-active` reporting active while that address family is dead.
# That is how a DHCPv4-only pkt4.mac expression in kea-dhcp6.conf went unnoticed.
#
# Asserting the daemon answers config-get over its control socket, rather than
# that the container is running, is what closes the gap.

set -eu

for service in dhcp4 dhcp6; do
    conf="/etc/kea/kea-${service}.conf"

    # Only require a daemon that is actually configured to run; start-kea.sh
    # starts each one only when its config file is present.
    [ -f "${conf}" ] || continue

    if ! kea-shell --service "${service}" config-get </dev/null 2>/dev/null |
        python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[0].get("result") == 0 else 1)'; then
        echo "UNHEALTHY: kea-${service} is not answering config-get" >&2
        exit 1
    fi
done

echo "healthy: all configured Kea daemons answering"
