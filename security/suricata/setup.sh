#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="$SCRIPT_DIR/etc"
RULES_DIR="$SCRIPT_DIR/rules"
LOGS_DIR="$SCRIPT_DIR/logs"

echo "[Suricata] Creating directories..."
mkdir -p "$ETC_DIR" "$RULES_DIR" "$LOGS_DIR"

echo "[Suricata] Extracting default configuration from Suricata image..."
docker run --rm jasonish/suricata:latest cat /etc/suricata/suricata.yaml > "$ETC_DIR/suricata.yaml"

echo "[Suricata] Patching configuration..."

CONFIG="$ETC_DIR/suricata.yaml"

# Set HOME_NET
sed 's|HOME_NET:.*".*"|HOME_NET: "[172.16.0.0/12]"|' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

# Set default-log-dir
sed 's|default-log-dir:.*|default-log-dir: /var/log/suricata/|' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

echo "[Suricata] Updating rules via suricata-update..."
docker run --rm \
  -v "$RULES_DIR:/var/lib/suricata/rules" \
  jasonish/suricata:latest \
  suricata-update

echo "[Suricata] Setup complete."
echo "  Config: $ETC_DIR/suricata.yaml"
echo "  Rules:  $RULES_DIR/"
echo "  Logs:   $LOGS_DIR/"
