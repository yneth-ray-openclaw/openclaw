#!/bin/sh
set -e

echo "[suricata-ips] Setting up NFQUEUE on FORWARD chain..."
iptables -I FORWARD -j NFQUEUE --queue-num 0
ip6tables -I FORWARD -j NFQUEUE --queue-num 0 2>/dev/null || true

cleanup() {
    echo "[suricata-ips] Removing NFQUEUE rules..."
    iptables -D FORWARD -j NFQUEUE --queue-num 0 2>/dev/null || true
    ip6tables -D FORWARD -j NFQUEUE --queue-num 0 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[suricata-ips] Starting Suricata in IPS mode (NFQUEUE 0)..."
exec suricata -q 0 -v
