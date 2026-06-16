#!/usr/bin/env bash
# Integration test: DHCP end-to-end via isolated Podman bridge
#
# Topology:
#   ztpbootstrap-test-net (bridge, --internal, 192.168.253.0/24)
#     kea-test-server  (192.168.253.2) — Kea DHCPv4 + Control Agent
#     dhcp-test-client (dynamic)      — Alpine udhcpc
#
# Assertions:
#   1. Client receives an IP in 192.168.253.100–200
#   2. Lease is visible via Kea's lease4-get-all API command
#
# Usage:
#   sudo ./tests/integration/test_dhcp_e2e.sh
#
# The test exits 0 on success, 1 on failure, and 77 (skip) when the
# runtime prerequisites are not met (Podman unavailable, etc.).

set -euo pipefail

SKIP=77

# ---------------------------------------------------------------------------
# Guard: skip if Podman is not available
# ---------------------------------------------------------------------------
if ! command -v podman >/dev/null 2>&1; then
    echo "SKIP: podman not found — skipping DHCP integration test" >&2
    exit "$SKIP"
fi

# Podman requires root for bridge networking with --internal on most distros
if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: must run as root for Podman bridge network tests" >&2
    exit "$SKIP"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_NET="ztpbootstrap-test-net"
TEST_SUBNET="192.168.253.0/24"
KEA_SERVER="kea-test-server"
KEA_CLIENT="dhcp-test-client"
# ISC does not publish free public Kea images; we build from kea/Containerfile.
# Allow override via KEA_IMAGE env var for CI environments that pre-build.
KEA_IMAGE="${KEA_IMAGE:-ztpbootstrap-kea:3.0}"
CLIENT_IMAGE="docker.io/alpine:3.19"
KEA_IP="192.168.253.2"
RANGE_START="192.168.253.100"
RANGE_END="192.168.253.200"
CTRL_PORT="8000"

TMPDIR_TEST=""

# ---------------------------------------------------------------------------
# Cleanup: always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    echo "==> Cleanup"
    podman rm -f "$KEA_SERVER"  2>/dev/null || true
    podman rm -f "$KEA_CLIENT"  2>/dev/null || true
    podman network rm "$TEST_NET" 2>/dev/null || true
    [[ -n "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

wait_for_port() {
    local container="$1"
    local port="$2"
    local retries="${3:-20}"
    local i
    for i in $(seq 1 "$retries"); do
        if podman exec "$container" \
               sh -c "nc -z 127.0.0.1 $port 2>/dev/null" 2>/dev/null; then
            echo "    ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Step 0: Ensure Kea image is available (build locally if needed)
# ---------------------------------------------------------------------------
if ! podman image exists "$KEA_IMAGE" 2>/dev/null; then
    echo "==> Kea image '$KEA_IMAGE' not found — building from kea/Containerfile"
    podman build -t "$KEA_IMAGE" -f "${REPO_DIR}/kea/Containerfile" "${REPO_DIR}" 2>&1
fi

# ---------------------------------------------------------------------------
# Step 1: Create isolated bridge network
# ---------------------------------------------------------------------------
echo "==> Creating isolated bridge network $TEST_NET ($TEST_SUBNET)"
podman network create \
    --driver bridge \
    --internal \
    --subnet "$TEST_SUBNET" \
    "$TEST_NET"

# ---------------------------------------------------------------------------
# Step 2: Write Kea configuration files into a temp directory
# ---------------------------------------------------------------------------
TMPDIR_TEST="$(mktemp -d /tmp/tmp_dhcp_e2e_XXXXXX)"
mkdir -p "$TMPDIR_TEST/kea" "$TMPDIR_TEST/leases" "$TMPDIR_TEST/run-kea"

# Kea 2.6+ requires control socket path to be under /run/kea (not /tmp)
cat > "$TMPDIR_TEST/kea/kea-dhcp4.conf" << 'KEATPL'
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["eth0"],
      "dhcp-socket-type": "udp"
    },
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/run/kea/kea4-ctrl.sock"
    },
    "lease-database": {
      "type": "memfile",
      "lfc-interval": 0,
      "name": "/leases/dhcp4.leases"
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "192.168.253.0/24",
        "pools": [
          { "pool": "192.168.253.100 - 192.168.253.200" }
        ],
        "option-data": [
          { "name": "routers",     "data": "192.168.253.1" },
          { "name": "subnet-mask", "data": "255.255.255.0" }
        ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [{ "output": "stdout" }],
        "severity": "INFO"
      }
    ]
  }
}
KEATPL

cat > "$TMPDIR_TEST/kea/kea-ctrl-agent.conf" << 'CTLCFG'
{
  "Control-agent": {
    "http-host": "0.0.0.0",
    "http-port": 8000,
    "control-sockets": {
      "dhcp4": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea4-ctrl.sock"
      }
    },
    "loggers": [
      {
        "name": "kea-ctrl-agent",
        "output_options": [{ "output": "stdout" }],
        "severity": "INFO"
      }
    ]
  }
}
CTLCFG

# Startup script: runs kea-dhcp4 in background, then kea-ctrl-agent in foreground
cat > "$TMPDIR_TEST/kea/start.sh" << 'STARTSH'
#!/bin/sh
set -e
mkdir -p /run/kea && chmod 750 /run/kea
kea-dhcp4 -c /etc/kea/kea-dhcp4.conf &
echo "kea-dhcp4 started (PID $!)"
# wait for control socket under /run/kea before starting control agent
for i in $(seq 1 20); do
    [ -S /run/kea/kea4-ctrl.sock ] && break
    sleep 1
done
exec kea-ctrl-agent -c /etc/kea/kea-ctrl-agent.conf
STARTSH
chmod +x "$TMPDIR_TEST/kea/start.sh"

# ---------------------------------------------------------------------------
# Step 3: Start the Kea server container
# ---------------------------------------------------------------------------
echo "==> Starting Kea server ($KEA_IMAGE) at $KEA_IP"
podman run -d \
    --name "$KEA_SERVER" \
    --network "$TEST_NET:ip=$KEA_IP" \
    --cap-add NET_BIND_SERVICE \
    --cap-add NET_RAW \
    -v "$TMPDIR_TEST/kea:/etc/kea:ro,z" \
    -v "$TMPDIR_TEST/leases:/leases:rw,z" \
    -v "$TMPDIR_TEST/run-kea:/run/kea:rw,z" \
    --entrypoint "/etc/kea/start.sh" \
    "$KEA_IMAGE"

echo "==> Waiting for Kea Control Agent to become ready on port $CTRL_PORT..."
if ! wait_for_port "$KEA_SERVER" "$CTRL_PORT" 30; then
    podman logs "$KEA_SERVER" >&2 || true
    fail "Kea Control Agent did not start within 30s"
fi

# ---------------------------------------------------------------------------
# Step 4: Run the DHCP client (Alpine + busybox udhcpc)
# ---------------------------------------------------------------------------
echo "==> Starting DHCP client"
podman run -d \
    --name "$KEA_CLIENT" \
    --network "$TEST_NET" \
    --cap-add NET_ADMIN \
    "$CLIENT_IMAGE" \
    sh -c "udhcpc -i eth0 -n -q 2>&1 | tee /tmp/udhcpc.log; sleep 60"

echo "==> Waiting for client to obtain a lease..."
sleep 8

# ---------------------------------------------------------------------------
# Step 5 & 6: Query Kea Control Agent for issued leases; assert range + count
# ---------------------------------------------------------------------------
# podman inspect returns the IP Podman assigned at container-create time (.3),
# not the DHCP-assigned address udhcpc received from Kea. Instead, query Kea
# directly: any lease in .100-.200 proves Kea served a real DHCP request.
echo "==> Querying Kea Control Agent (lease4-get-all)"
LEASE_JSON=$(podman exec "$KEA_SERVER" \
    curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"command":"lease4-get-all","service":["dhcp4"]}' \
    "http://127.0.0.1:${CTRL_PORT}" 2>/dev/null || echo "")

if [[ -z "$LEASE_JSON" ]]; then
    fail "no response from Kea Control Agent at http://127.0.0.1:${CTRL_PORT}"
fi

if ! echo "$LEASE_JSON" | grep -q '"result":0'; then
    fail "lease4-get-all returned non-zero result. Response: $LEASE_JSON"
fi

# Extract first ip-address value from the lease list
LEASED_IP=$(echo "$LEASE_JSON" | grep -o '"ip-address":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$LEASED_IP" ]]; then
    fail "no leases found in Kea response — DHCP client did not receive an address. Response: $LEASE_JSON"
fi

echo "    Kea issued lease: $LEASED_IP"

IFS='.' read -r o1 o2 o3 o4 <<< "$LEASED_IP"
if [[ "$o1.$o2.$o3" == "192.168.253" && "$o4" -ge 100 && "$o4" -le 200 ]]; then
    pass "Kea issued $LEASED_IP which is in 192.168.253.100–200"
else
    fail "Kea issued $LEASED_IP which is NOT in expected range 192.168.253.100–200"
fi

# ---------------------------------------------------------------------------
echo "==> All DHCP integration tests passed"
