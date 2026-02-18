#!/bin/bash

# OpenClaw ~/.openclaw directory backup script
# Features:
#   - Max compression (tar.xz with ultra compression)
#   - Auto-rotation based on configurable retention days
#   - Telegram notifications
#   - Logging
#   - Error handling

set -euo pipefail

# Configuration (can be overridden via environment variables)
BACKUP_SOURCE="${BACKUP_SOURCE:-$HOME/.openclaw}"
BACKUP_DEST="${BACKUP_DEST:-/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
LOG_FILE="${LOG_FILE:-/var/log/openclaw-backup.log}"

# Ensure directories exist
mkdir -p "$BACKUP_DEST" "$(dirname "$LOG_FILE")"

# Logging function
log() {
    local level=$1
    shift
    local message="$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Telegram notification function
notify_telegram() {
    local message=$1
    local status=${2:-info}  # info, success, error
    
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log "WARN" "Telegram not configured, skipping notification"
        return 0
    fi
    
    local emoji="ℹ️"
    [[ "$status" == "success" ]] && emoji="✅"
    [[ "$status" == "error" ]] && emoji="❌"
    
    local full_message="${emoji} OpenClaw Backup: ${message}"
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${full_message}" \
        -d "parse_mode=HTML" > /dev/null || log "WARN" "Failed to send Telegram notification"
}

# Cleanup old backups
cleanup_old_backups() {
    log "INFO" "Cleaning up backups older than ${RETENTION_DAYS} days"
    
    find "$BACKUP_DEST" -maxdepth 1 -name "openclaw-backup-*.tar.xz" -type f -mtime +${RETENTION_DAYS} | while read -r old_backup; do
        log "INFO" "Removing old backup: $old_backup"
        rm -f "$old_backup"
    done
}

# Main backup function
perform_backup() {
    local backup_timestamp=$(date +'%Y%m%d-%H%M%S')
    local backup_file="${BACKUP_DEST}/openclaw-backup-${backup_timestamp}.tar.xz"
    local size_before=$(du -sh "$BACKUP_SOURCE" 2>/dev/null | cut -f1 || echo "unknown")
    
    log "INFO" "Starting backup of $BACKUP_SOURCE (size: $size_before)"
    
    # Create backup with maximum compression
    if tar --xz --extreme -cf "$backup_file" -C "$(dirname "$BACKUP_SOURCE")" "$(basename "$BACKUP_SOURCE")" 2>/dev/null; then
        local backup_size=$(du -h "$backup_file" | cut -f1)
        log "INFO" "Backup completed successfully"
        log "INFO" "Backup file: $backup_file"
        log "INFO" "Compressed size: $backup_size"
        
        notify_telegram "Backup successful (${backup_size})" "success"
        return 0
    else
        log "ERROR" "Backup failed for $BACKUP_SOURCE"
        notify_telegram "Backup FAILED" "error"
        return 1
    fi
}

# Main execution
main() {
    log "INFO" "=== OpenClaw Backup Started ==="
    
    # Validate source exists
    if [[ ! -d "$BACKUP_SOURCE" ]]; then
        log "ERROR" "Source directory not found: $BACKUP_SOURCE"
        notify_telegram "Backup FAILED: source not found" "error"
        exit 1
    fi
    
    # Perform backup
    if perform_backup; then
        # Cleanup old backups
        cleanup_old_backups
        log "INFO" "=== OpenClaw Backup Completed Successfully ==="
        exit 0
    else
        log "ERROR" "=== OpenClaw Backup Failed ==="
        exit 1
    fi
}

main "$@"
