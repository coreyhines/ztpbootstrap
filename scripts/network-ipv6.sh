#!/bin/bash
# IPv6 helpers for Podman macvlan networks.
# When an ISP/prefix changes, remap configured addresses onto the current
# network prefix while preserving the host suffix (e.g. ::10).

ip_in_subnet() {
    local ip="$1"
    local subnet="$2"

    python3 - "$ip" "$subnet" <<'PY' 2>/dev/null
import ipaddress, sys
ip_s, subnet_s = sys.argv[1], sys.argv[2]
try:
    addr = ipaddress.ip_address(ip_s)
    net = ipaddress.ip_network(subnet_s, strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if addr in net else 1)
PY
}

get_podman_network_ipv6_subnet() {
    local network_name="$1"
    local podman_cmd="${2:-podman}"
    local subnet=""

    [[ -n "$network_name" ]] || return 1

    subnet=$($podman_cmd network inspect "$network_name" --format '{{range .Subnets}}{{.Subnet}} {{end}}' 2>/dev/null \
        | tr ' ' '\n' | grep ':' | head -1)
    if [[ -n "$subnet" ]] && [[ "$subnet" != "<no value>" ]]; then
        echo "$subnet"
        return 0
    fi

    subnet=$($podman_cmd network inspect "$network_name" 2>/dev/null \
        | grep -ioE '"subnet"[[:space:]]*:[[:space:]]*"[0-9a-fA-F:]+/[0-9]+"' \
        | sed -E 's/.*"([^"]+)"/\1/' | grep ':' | head -1)
    if [[ -n "$subnet" ]]; then
        echo "$subnet"
        return 0
    fi

    return 1
}

# Preserve host suffix; map old prefix onto subnet_cidr (e.g. ::10 -> current /64).
remap_ipv6_to_subnet() {
    local candidate="$1"
    local subnet_cidr="$2"

    python3 - "$candidate" "$subnet_cidr" <<'PY' 2>/dev/null
import ipaddress, sys

candidate, subnet_s = sys.argv[1], sys.argv[2]
try:
    old = ipaddress.ip_address(candidate)
    net = ipaddress.ip_network(subnet_s, strict=False)
except ValueError:
    raise SystemExit(1)

if old in net:
    print(old)
    raise SystemExit(0)

host_bits = 128 - net.prefixlen
if host_bits <= 0:
    raise SystemExit(1)

host_mask = (1 << host_bits) - 1
host_part = int(old) & host_mask
new_ip = ipaddress.ip_address(int(net.network_address) | host_part)
if new_ip not in net:
    raise SystemExit(1)

print(new_ip)
PY
}

# Validate or remap candidate IPv6 for a Podman network. Prints resolved address.
resolve_ipv6_for_podman_network() {
    local candidate="$1"
    local network_name="$2"
    local podman_cmd="${3:-podman}"
    local subnet resolved=""

    [[ -n "$candidate" ]] || return 1
    [[ "$candidate" == "null" ]] && return 1
    [[ -n "$network_name" ]] || return 1
    [[ "$network_name" == "host" ]] && return 1

    subnet=$(get_podman_network_ipv6_subnet "$network_name" "$podman_cmd" 2>/dev/null || echo "")
    [[ -n "$subnet" ]] || return 1

    resolved=$(remap_ipv6_to_subnet "$candidate" "$subnet" 2>/dev/null || echo "")
    [[ -n "$resolved" ]] || return 1
    printf '%s' "$resolved"
}

# If config IPv6 uses an old prefix, rewrite config.yaml with the remapped address.
normalize_config_ipv6_for_network() {
    local config_file="$1"
    local ipv6 network resolved podman_cmd

    [[ -f "$config_file" ]] || return 0

    if ! command -v get_config_yaml_value >/dev/null 2>&1; then
        return 0
    fi

    ipv6=$(get_config_yaml_value "$config_file" "network.ipv6" "")
    network=$(get_config_yaml_value "$config_file" "network.network" "")
    [[ -n "$ipv6" ]] || return 0
    [[ "$ipv6" == "null" ]] && return 0
    [[ -n "$network" ]] || return 0
    [[ "$network" == "host" ]] && return 0

    podman_cmd="podman"
    if ! podman network exists "$network" 2>/dev/null && command -v sudo >/dev/null 2>&1; then
        podman_cmd="sudo podman"
    fi

    resolved=$(resolve_ipv6_for_podman_network "$ipv6" "$network" "$podman_cmd" 2>/dev/null || echo "")
    [[ -n "$resolved" ]] || return 0
    [[ "$resolved" == "$ipv6" ]] && return 0

    if grep -qE '^[[:space:]]+ipv6:' "$config_file" 2>/dev/null; then
        sed -i.tmp -E "s|^([[:space:]]*ipv6:[[:space:]]*).*$|\\1\"${resolved}\"|" "$config_file"
        rm -f "${config_file}.tmp" 2>/dev/null || true
    fi
}
