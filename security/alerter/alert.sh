#!/bin/sh
# Security alerter — monitors Suricata and Tracee logs, sends alerts to Telegram.
# Alpine-compatible POSIX shell. No jq dependency.

set -u

# --- Configuration ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
ALERT_MAX_PER_MINUTE="${ALERT_MAX_PER_MINUTE:-10}"
DAILY_REPORT_HOUR="${DAILY_REPORT_HOUR:-0}"

SURICATA_LOG="/var/log/suricata/eve.json"
TRACEE_LOG="/tmp/tracee/out"

# --- Rate limiting state ---
ALERT_COUNT=0
LAST_RESET=$(date +%s)

rate_limit_check() {
    now=$(date +%s)
    elapsed=$((now - LAST_RESET))
    if [ "$elapsed" -ge 60 ]; then
        ALERT_COUNT=0
        LAST_RESET=$now
    fi
    if [ "$ALERT_COUNT" -ge "$ALERT_MAX_PER_MINUTE" ]; then
        return 1
    fi
    ALERT_COUNT=$((ALERT_COUNT + 1))
    return 0
}

# --- Telegram sender ---
send_telegram() {
    message="$1"
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "[alerter] $message"
        return
    fi
    if ! rate_limit_check; then
        echo "[alerter] Rate limit reached, skipping alert"
        return
    fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "text=${message}" > /dev/null 2>&1 || echo "[alerter] Failed to send Telegram message"
}

# --- Suricata alert parser ---
parse_suricata() {
    while IFS= read -r line; do
        # Only process alert events with severity 1 or 2
        case "$line" in
            *'"event_type":"alert"'*)
                case "$line" in
                    *'"severity":1'*|*'"severity":2'*)
                        severity=$(echo "$line" | sed -n 's/.*"severity":\([0-9]*\).*/\1/p')
                        signature=$(echo "$line" | sed -n 's/.*"signature":"\([^"]*\)".*/\1/p')
                        src_ip=$(echo "$line" | sed -n 's/.*"src_ip":"\([^"]*\)".*/\1/p')
                        dest_ip=$(echo "$line" | sed -n 's/.*"dest_ip":"\([^"]*\)".*/\1/p')
                        timestamp=$(echo "$line" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')

                        msg="<b>Suricata Alert</b>
<b>Severity:</b> ${severity}
<b>Signature:</b> ${signature}
<b>Source:</b> ${src_ip} -> ${dest_ip}
<b>Time:</b> ${timestamp}"

                        send_telegram "$msg"
                        ;;
                esac
                ;;
        esac
    done
}

# --- Known package manager binaries ---
PACKAGE_MANAGERS="/apt-get /dpkg /pip /pip3 /npm /apk"

is_package_manager() {
    pathname="$1"
    for pm in $PACKAGE_MANAGERS; do
        case "$pathname" in
            *"$pm") return 0 ;;
        esac
    done
    return 1
}

# --- Tracee alert parser ---
parse_tracee() {
    while IFS= read -r line; do
        # Skip empty lines
        [ -z "$line" ] && continue

        event_name=$(echo "$line" | sed -n 's/.*"eventName":"\([^"]*\)".*/\1/p')
        container_name=$(echo "$line" | sed -n 's/.*"containerName":"\([^"]*\)".*/\1/p')
        timestamp=$(echo "$line" | sed -n 's/.*"timestamp":\([0-9]*\).*/\1/p')

        # Skip if we couldn't parse the event name
        [ -z "$event_name" ] && continue

        # Detect package manager execution
        if [ "$event_name" = "sched_process_exec" ]; then
            pathname=$(echo "$line" | sed -n 's/.*"pathname":"\([^"]*\)".*/\1/p')
            if is_package_manager "$pathname"; then
                cmdline=$(echo "$line" | sed -n 's/.*"cmdline":"\([^"]*\)".*/\1/p')
                msg="<b>Package Install Detected</b>
<b>Container:</b> ${container_name}
<b>Command:</b> ${pathname} ${cmdline}
<b>Time:</b> ${timestamp}"
                send_telegram "$msg"
                continue
            fi
        fi

        msg="<b>Tracee Alert</b>
<b>Event:</b> ${event_name}
<b>Container:</b> ${container_name}
<b>Time:</b> ${timestamp}"

        send_telegram "$msg"
    done
}

# --- Main ---
echo "[alerter] Starting security alerter..."
if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "[alerter] WARNING: Telegram credentials not set — alerts will be printed to stdout"
fi

# Wait for at least one log file to appear
echo "[alerter] Waiting for log files..."
while true; do
    [ -f "$SURICATA_LOG" ] && break
    [ -f "$TRACEE_LOG" ] && break
    sleep 5
done
echo "[alerter] Log file(s) detected. Starting log monitoring..."

# Monitor both log files in parallel
# Use tail -F to follow files even if they are rotated
if [ -f "$SURICATA_LOG" ]; then
    tail -F "$SURICATA_LOG" 2>/dev/null | parse_suricata &
    echo "[alerter] Monitoring Suricata: $SURICATA_LOG"
fi

if [ -f "$TRACEE_LOG" ]; then
    tail -F "$TRACEE_LOG" 2>/dev/null | parse_tracee &
    echo "[alerter] Monitoring Tracee: $TRACEE_LOG"
fi

# Also start monitoring for log files that appear later
(
    while true; do
        sleep 10
        if [ -f "$SURICATA_LOG" ] && ! pgrep -f "tail.*$SURICATA_LOG" > /dev/null 2>&1; then
            tail -F "$SURICATA_LOG" 2>/dev/null | parse_suricata &
            echo "[alerter] Late start: monitoring Suricata"
        fi
        if [ -f "$TRACEE_LOG" ] && ! pgrep -f "tail.*$TRACEE_LOG" > /dev/null 2>&1; then
            tail -F "$TRACEE_LOG" 2>/dev/null | parse_tracee &
            echo "[alerter] Late start: monitoring Tracee"
        fi
    done
) &

# Daily report background loop
(
    while true; do
        current_hour=$(date +%H)
        if [ "$current_hour" -eq "$DAILY_REPORT_HOUR" ]; then
            echo "[alerter] Running daily security report..."
            sh /daily-report.sh
            sleep 3700  # Slightly over 1 hour to avoid double-trigger
        fi
        sleep 3600  # Check hourly
    done
) &
echo "[alerter] Daily report scheduled at hour $DAILY_REPORT_HOUR"

# Wait for all background processes
wait
