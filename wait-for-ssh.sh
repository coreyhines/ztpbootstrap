#!/bin/bash
# Optimized SSH wait script
# Checks port availability first, then SSH connection

HOST="${1:-localhost}"
PORT="${2:-2222}"
USER="${3:-fedora}"
TIMEOUT="${4:-300}"
INTERVAL="${5:-2}"

echo "Waiting for SSH on ${USER}@${HOST}:${PORT}..."
echo "Timeout: ${TIMEOUT}s, Check interval: ${INTERVAL}s"
echo ""

start_time=$(date +%s)
elapsed=0

# Phase 1: Wait for port to be open (faster check)
echo "Phase 1: Waiting for port ${PORT} to be open..."
while [ $elapsed -lt $TIMEOUT ]; do
    if timeout 1 bash -c "echo > /dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
        echo "✓ Port ${PORT} is open (${elapsed}s)"
        break
    fi
    sleep $INTERVAL
    elapsed=$(($(date +%s) - start_time))
    if [ $((elapsed % 10)) -eq 0 ]; then
        echo "  Still waiting... (${elapsed}s)"
    fi
done

if [ $elapsed -ge $TIMEOUT ]; then
    echo "✗ Timeout: Port ${PORT} did not open within ${TIMEOUT}s"
    exit 1
fi

# Phase 2: Wait for SSH to accept connections (with key auth)
echo ""
echo "Phase 2: Waiting for SSH to accept connections..."
ssh_ready=false
while [ $elapsed -lt $TIMEOUT ]; do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p "$PORT" "${USER}@${HOST}" "echo 'SSH ready'" 2>/dev/null; then
        echo "✓ SSH is ready and accepting connections (${elapsed}s)"
        ssh_ready=true
        break
    fi
    sleep $INTERVAL
    elapsed=$(($(date +%s) - start_time))
    if [ $((elapsed % 10)) -eq 0 ]; then
        echo "  Still waiting for SSH... (${elapsed}s)"
    fi
done

if [ "$ssh_ready" != "true" ]; then
    echo "✗ Timeout: SSH did not become ready within ${TIMEOUT}s"
    exit 1
fi

echo ""
echo "✓ SSH is fully ready! Total wait time: ${elapsed}s"
exit 0
