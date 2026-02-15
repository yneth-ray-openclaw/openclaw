#!/bin/sh
# daily-report.sh — Parses the last 24h of Suricata eve.json and sends
# a traffic summary to Telegram.

set -u

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
SURICATA_LOG="/var/log/suricata/eve.json"

send_telegram() {
    message="$1"
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "$message"
        return
    fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${message}" > /dev/null 2>&1
}

if [ ! -f "$SURICATA_LOG" ]; then
    echo "[daily-report] No eve.json found, skipping"
    exit 0
fi

TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "@$(($(date -u +%s) - 86400))" +%Y-%m-%d 2>/dev/null || \
            date -u -r "$(($(date -u +%s) - 86400))" +%Y-%m-%d 2>/dev/null || \
            echo "$TODAY")

# Extract last 24h of events (match by date prefix in timestamp)
# Suricata timestamps look like: "2026-02-10T12:34:56.789012+0000"

DNS_SUMMARY=$(jq -r "
    select(.timestamp[:10] == \"$TODAY\" or .timestamp[:10] == \"$YESTERDAY\") |
    select(.event_type == \"dns\" and .dns.type == \"query\") |
    .dns.rrname
" "$SURICATA_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -15)

DNS_COUNT=$(echo "$DNS_SUMMARY" | grep -c '[^ ]' 2>/dev/null || echo "0")

HTTP_TLS_SUMMARY=$(jq -r "
    select(.timestamp[:10] == \"$TODAY\" or .timestamp[:10] == \"$YESTERDAY\") |
    select(.event_type == \"http\" or .event_type == \"tls\") |
    .dest_ip + \" (\" + (.http.hostname // .tls.sni // \"unknown\") + \")\"
" "$SURICATA_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -15)

DEST_COUNT=$(echo "$HTTP_TLS_SUMMARY" | grep -c '[^ ]' 2>/dev/null || echo "0")

ALERT_SUMMARY=$(jq -r "
    select(.timestamp[:10] == \"$TODAY\" or .timestamp[:10] == \"$YESTERDAY\") |
    select(.event_type == \"alert\") |
    \"[\" + (.alert.action // \"ALERT\") + \"] \" + .alert.signature
" "$SURICATA_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -15)

ALERT_COUNT=$(echo "$ALERT_SUMMARY" | grep -c '[^ ]' 2>/dev/null || echo "0")

DROP_COUNT=$(jq -r "
    select(.timestamp[:10] == \"$TODAY\" or .timestamp[:10] == \"$YESTERDAY\") |
    select(.event_type == \"alert\" and .alert.action == \"blocked\") |
    .alert.signature
" "$SURICATA_LOG" 2>/dev/null | wc -l | tr -d ' ')

# Format message
MSG="<b>Daily Security Report ($TODAY)</b>

<b>DNS Queries</b> (unique domains): ${DNS_COUNT}"

if [ -n "$DNS_SUMMARY" ] && [ "$DNS_COUNT" -gt 0 ]; then
    MSG="${MSG}
<pre>$(echo "$DNS_SUMMARY" | head -10)</pre>"
fi

MSG="${MSG}

<b>HTTP/TLS Destinations</b> (unique): ${DEST_COUNT}"

if [ -n "$HTTP_TLS_SUMMARY" ] && [ "$DEST_COUNT" -gt 0 ]; then
    MSG="${MSG}
<pre>$(echo "$HTTP_TLS_SUMMARY" | head -10)</pre>"
fi

MSG="${MSG}

<b>Alerts:</b> ${ALERT_COUNT}"

if [ -n "$ALERT_SUMMARY" ] && [ "$ALERT_COUNT" -gt 0 ]; then
    MSG="${MSG}
<pre>$(echo "$ALERT_SUMMARY" | head -10)</pre>"
fi

MSG="${MSG}

<b>Blocked:</b> ${DROP_COUNT}"

send_telegram "$MSG"
echo "[daily-report] Report sent for $TODAY"
