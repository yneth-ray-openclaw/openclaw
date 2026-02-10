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

# Background rule update loop
RULE_UPDATE_HOUR="${RULE_UPDATE_HOUR:-3}"
(
    while true; do
        current_hour=$(date +%H)
        if [ "$current_hour" -eq "$RULE_UPDATE_HOUR" ]; then
            echo "[suricata-ips] Updating rules..."
            suricata-update --modify-conf /var/lib/suricata/rules/modify.conf && \
                suricatasc -c reload-rules && \
                echo "[suricata-ips] Rules reloaded"
            sleep 3700  # Slightly over 1 hour to avoid double-trigger
        fi
        sleep 3600  # Check hourly
    done
) &

echo "[suricata-ips] Starting Suricata in IPS mode (NFQUEUE 0)..."
exec suricata -q 0 -v
