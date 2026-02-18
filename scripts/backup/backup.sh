#!/bin/bash

# OpenClaw ~/.openclaw directory backup script
# Features:
#   - Configurable compression: zstd (fast, default), gzip, or xz (slow)
#   - Auto-rotation based on configurable retention days
#   - Telegram notifications
#   - Logging
#   - Error handling

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env file if it exists (check script directory first, then current directory)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a  # automatically export all variables
    source "$SCRIPT_DIR/.env"
    set +a
elif [[ -f ".env" ]]; then
    set -a
    source ".env"
    set +a
fi

# Configuration (can be overridden via environment variables)
BACKUP_SOURCE="${BACKUP_SOURCE:-$HOME/.openclaw}"
BACKUP_DEST="${BACKUP_DEST:-/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
LOG_FILE="${LOG_FILE:-/var/log/openclaw-backup.log}"
COMPRESSION="${COMPRESSION:-zstd}"  # Options: zstd (fast), gzip (compatible), xz (slow but smallest)

# Expand tilde in paths (needed when values come from .env with quotes)
BACKUP_SOURCE="${BACKUP_SOURCE/#\~/$HOME}"
BACKUP_DEST="${BACKUP_DEST/#\~/$HOME}"
LOG_FILE="${LOG_FILE/#\~/$HOME}"

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

    find "$BACKUP_DEST" -maxdepth 1 \( -name "openclaw-backup-*.tar.xz" -o -name "openclaw-backup-*.tar.gz" -o -name "openclaw-backup-*.tar.zst" \) -type f -mtime +${RETENTION_DAYS} | while read -r old_backup; do
        log "INFO" "Removing old backup: $old_backup"
        rm -f "$old_backup"
    done
}

# Main backup function
perform_backup() {
    local backup_timestamp=$(date +'%Y%m%d-%H%M%S')
    local size_before=$(du -sh "$BACKUP_SOURCE" 2>/dev/null | cut -f1 || echo "unknown")

    # Set compression options
    local tar_flag ext
    case "$COMPRESSION" in
        zstd)
            tar_flag="--zstd"
            ext="tar.zst"
            ;;
        gzip)
            tar_flag="-z"
            ext="tar.gz"
            ;;
        xz)
            tar_flag="-J"
            ext="tar.xz"
            ;;
        *)
            log "ERROR" "Unknown compression: $COMPRESSION"
            return 1
            ;;
    esac

    local backup_file="${BACKUP_DEST}/openclaw-backup-${backup_timestamp}.${ext}"

    log "INFO" "Starting backup of $BACKUP_SOURCE (size: $size_before, compression: $COMPRESSION)"

    # Create backup with selected compression
    if tar $tar_flag -cf "$backup_file" -C "$(dirname "$BACKUP_SOURCE")" "$(basename "$BACKUP_SOURCE")" 2>&1; then
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
