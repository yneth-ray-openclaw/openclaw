#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="$SCRIPT_DIR/etc"
RULES_DIR="$SCRIPT_DIR/rules"
LOGS_DIR="$SCRIPT_DIR/logs"

echo "[Suricata] Creating directories..."
mkdir -p "$ETC_DIR" "$RULES_DIR" "$LOGS_DIR"

echo "[Suricata] Extracting default configuration from Suricata image..."
docker run --rm jasonish/suricata:7.0 cat /etc/suricata/suricata.yaml > "$ETC_DIR/suricata.yaml"

echo "[Suricata] Patching configuration..."

CONFIG="$ETC_DIR/suricata.yaml"

# Set HOME_NET
sed 's|HOME_NET:.*".*"|HOME_NET: "[172.16.0.0/12]"|' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

# Set default-log-dir
sed 's|default-log-dir:.*|default-log-dir: /var/log/suricata/|' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"

# Enable IPS mode (NFQUEUE) — fail-closed: block traffic if Suricata is down
sed -i 's/# *nfq:/nfq:/' "$CONFIG"
sed -i '/nfq:/,/fail-open:/ s/fail-open: .*/fail-open: no/' "$CONFIG"

# Enable stream inline so Suricata honors drop rules in IPS mode
sed -i '/^stream:/,/^[^ ]/ s/inline: .*/inline: auto/' "$CONFIG"

# Enable DNS, HTTP, and TLS logging in eve-log output
# These are needed for the daily traffic summary
sed -i '/- dns:/,/^[[:space:]]*-/ s/enabled: no/enabled: yes/' "$CONFIG"
sed -i '/- http:/,/^[[:space:]]*-/ s/enabled: no/enabled: yes/' "$CONFIG"
sed -i '/- tls:/,/^[[:space:]]*-/ s/enabled: no/enabled: yes/' "$CONFIG"

echo "[Suricata] Creating modify.conf for drop rules..."
cat > "$RULES_DIR/modify.conf" << 'EOF'
# Convert critical threat categories from alert to drop
re:classtype:trojan-activity  alert -> drop
re:classtype:command-and-control  alert -> drop
re:classtype:exploit-kit  alert -> drop
re:classtype:web-application-attack  alert -> drop
re:classtype:attempted-admin  alert -> drop
re:classtype:shellcode-detect  alert -> drop
re:classtype:successful-admin  alert -> drop
re:classtype:successful-recon-limited  alert -> drop
EOF

echo "[Suricata] Updating rules via suricata-update..."
docker run --rm \
  -v "$RULES_DIR:/var/lib/suricata/rules" \
  jasonish/suricata:7.0 \
  suricata-update --modify-conf /var/lib/suricata/rules/modify.conf

echo "[Suricata] Enabling additional threat feeds..."
docker run --rm \
  -v "$RULES_DIR:/var/lib/suricata/rules" \
  jasonish/suricata:7.0 \
  sh -c "
    suricata-update enable-source sslbl/ssl-fp-blacklist && \
    suricata-update enable-source sslbl/ja3-fingerprints && \
    suricata-update enable-source etnetera/aggressive && \
    suricata-update --modify-conf /var/lib/suricata/rules/modify.conf
  "

echo "[Suricata] Setup complete."
echo "  Config: $ETC_DIR/suricata.yaml"
echo "  Rules:  $RULES_DIR/"
echo "  Logs:   $LOGS_DIR/"
echo "  Feeds:  ET Open + SSLBL (ssl-fp-blacklist, ja3-fingerprints) + etnetera/aggressive"
echo "  Drop:   trojan-activity, command-and-control, exploit-kit, web-application-attack,"
echo "          attempted-admin, shellcode-detect, successful-admin, successful-recon-limited"
