#!/bin/bash

# OpenClaw ~/.openclaw directory backup script
# Features:
#   - Configurable compression: zstd (fast, default), gzip, or xz (slow)
#   - Auto-rotation based on configurable retention days
#   - Telegram notifications
#   - Extensive logging with debug mode
#   - Comprehensive error handling with detailed diagnostics

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
DEBUG="${DEBUG:-false}"  # Set to "true" for verbose debug output

# Expand tilde in paths (needed when values come from .env with quotes)
BACKUP_SOURCE="${BACKUP_SOURCE/#\~/$HOME}"
BACKUP_DEST="${BACKUP_DEST/#\~/$HOME}"
LOG_FILE="${LOG_FILE/#\~/$HOME}"

# Temp file to capture command errors
ERROR_LOG=""
LAST_ERROR=""

# Cleanup function for temp files
cleanup_temp() {
    if [[ -n "$ERROR_LOG" && -f "$ERROR_LOG" ]]; then
        rm -f "$ERROR_LOG"
    fi
}
trap cleanup_temp EXIT

# Ensure directories exist
mkdir -p "$BACKUP_DEST" "$(dirname "$LOG_FILE")" 2>/dev/null || {
    echo "FATAL: Cannot create required directories" >&2
    exit 1
}

# Create temp file for error capture
ERROR_LOG=$(mktemp) || {
    echo "FATAL: Cannot create temp file for error logging" >&2
    exit 1
}

# Logging function with levels: DEBUG, INFO, WARN, ERROR
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Skip DEBUG messages unless DEBUG mode is enabled
    if [[ "$level" == "DEBUG" && "$DEBUG" != "true" ]]; then
        return 0
    fi

    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Log multiline output (for command stderr/stdout)
log_multiline() {
    local level=$1
    local prefix=$2
    shift 2
    local content="$*"

    if [[ -z "$content" ]]; then
        return 0
    fi

    while IFS= read -r line; do
        log "$level" "$prefix: $line"
    done <<< "$content"
}

# Telegram notification function with detailed error reporting
notify_telegram() {
    local message=$1
    local status=${2:-info}  # info, success, error

    log "DEBUG" "Preparing Telegram notification: status=$status"

    if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
        log "DEBUG" "TELEGRAM_BOT_TOKEN is not set"
        log "WARN" "Telegram not configured (missing bot token), skipping notification"
        return 0
    fi

    if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        log "DEBUG" "TELEGRAM_CHAT_ID is not set"
        log "WARN" "Telegram not configured (missing chat ID), skipping notification"
        return 0
    fi

    log "DEBUG" "Telegram configured: chat_id=$TELEGRAM_CHAT_ID, token_length=${#TELEGRAM_BOT_TOKEN}"

    local emoji="ℹ️"
    [[ "$status" == "success" ]] && emoji="✅"
    [[ "$status" == "error" ]] && emoji="❌"

    local full_message="${emoji} OpenClaw Backup: ${message}"
    log "DEBUG" "Sending Telegram message: $full_message"

    local curl_response
    local curl_exit_code
    local http_code

    # Capture both response body and HTTP status code
    curl_response=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${full_message}" \
        -d "parse_mode=HTML" 2>"$ERROR_LOG")
    curl_exit_code=$?

    # Extract HTTP code from last line
    http_code=$(echo "$curl_response" | tail -n1)
    local response_body=$(echo "$curl_response" | sed '$d')

    if [[ $curl_exit_code -ne 0 ]]; then
        local curl_error=$(cat "$ERROR_LOG" 2>/dev/null)
        log "ERROR" "Telegram curl failed with exit code $curl_exit_code"
        log "ERROR" "Curl error: ${curl_error:-unknown}"
        log "DEBUG" "Curl response: $response_body"
        return 1
    fi

    if [[ "$http_code" != "200" ]]; then
        log "ERROR" "Telegram API returned HTTP $http_code"
        log "ERROR" "Telegram API response: $response_body"
        return 1
    fi

    # Check if Telegram API returned ok:false
    if echo "$response_body" | grep -q '"ok":false'; then
        local error_desc=$(echo "$response_body" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
        log "ERROR" "Telegram API error: ${error_desc:-unknown}"
        log "DEBUG" "Full response: $response_body"
        return 1
    fi

    log "DEBUG" "Telegram notification sent successfully"
    return 0
}

# Cleanup old backups with detailed logging
cleanup_old_backups() {
    log "INFO" "Cleaning up backups older than ${RETENTION_DAYS} days"
    log "DEBUG" "Searching in: $BACKUP_DEST"

    local removed_count=0
    local failed_count=0
    local find_output
    local find_exit_code

    # Run find and capture any errors
    find_output=$(find "$BACKUP_DEST" -maxdepth 1 \( -name "openclaw-backup-*.tar.xz" -o -name "openclaw-backup-*.tar.gz" -o -name "openclaw-backup-*.tar.zst" \) -type f -mtime +${RETENTION_DAYS} 2>"$ERROR_LOG")
    find_exit_code=$?

    if [[ $find_exit_code -ne 0 ]]; then
        local find_error=$(cat "$ERROR_LOG" 2>/dev/null)
        log "ERROR" "Find command failed with exit code $find_exit_code"
        log "ERROR" "Find error: ${find_error:-unknown}"
        return 1
    fi

    if [[ -z "$find_output" ]]; then
        log "INFO" "No old backups found to clean up"
        return 0
    fi

    log "DEBUG" "Found old backups to remove:"
    log_multiline "DEBUG" "  " "$find_output"

    while IFS= read -r old_backup; do
        if [[ -n "$old_backup" ]]; then
            local file_info=$(ls -lh "$old_backup" 2>/dev/null | awk '{print $5, $6, $7, $8}')
            log "INFO" "Removing old backup: $old_backup ($file_info)"

            if rm -f "$old_backup" 2>"$ERROR_LOG"; then
                log "DEBUG" "Successfully removed: $old_backup"
                ((removed_count++))
            else
                local rm_error=$(cat "$ERROR_LOG" 2>/dev/null)
                log "ERROR" "Failed to remove: $old_backup - ${rm_error:-unknown error}"
                ((failed_count++))
            fi
        fi
    done <<< "$find_output"

    log "INFO" "Cleanup complete: removed $removed_count backup(s), failed $failed_count"

    if [[ $failed_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Check if required compression tool is available
check_compression_tool() {
    local compression=$1

    case "$compression" in
        zstd)
            if ! command -v zstd &>/dev/null; then
                log "ERROR" "zstd compression tool not found"
                log "ERROR" "Install with: apt-get install zstd / brew install zstd"
                return 1
            fi
            local version=$(zstd --version 2>&1 | head -n1)
            log "DEBUG" "Using zstd: $version"
            ;;
        gzip)
            if ! command -v gzip &>/dev/null; then
                log "ERROR" "gzip compression tool not found"
                return 1
            fi
            local version=$(gzip --version 2>&1 | head -n1)
            log "DEBUG" "Using gzip: $version"
            ;;
        xz)
            if ! command -v xz &>/dev/null; then
                log "ERROR" "xz compression tool not found"
                log "ERROR" "Install with: apt-get install xz-utils / brew install xz"
                return 1
            fi
            local version=$(xz --version 2>&1 | head -n1)
            log "DEBUG" "Using xz: $version"
            ;;
    esac
    return 0
}

# Check disk space availability
check_disk_space() {
    local dest_dir=$1
    local source_dir=$2

    log "DEBUG" "Checking disk space..."

    # Get source size in KB
    local source_size_kb=$(du -sk "$source_dir" 2>/dev/null | cut -f1)
    if [[ -z "$source_size_kb" ]]; then
        log "WARN" "Could not determine source size"
        return 0
    fi

    # Get available space in destination (in KB)
    local available_kb=$(df -k "$dest_dir" 2>/dev/null | tail -n1 | awk '{print $4}')
    if [[ -z "$available_kb" ]]; then
        log "WARN" "Could not determine available disk space"
        return 0
    fi

    local source_mb=$((source_size_kb / 1024))
    local available_mb=$((available_kb / 1024))

    log "DEBUG" "Source size: ${source_mb}MB, Available space: ${available_mb}MB"

    # Warn if available space is less than 2x source (accounting for temp files during compression)
    if [[ $available_kb -lt $((source_size_kb * 2)) ]]; then
        log "WARN" "Low disk space! Source: ${source_mb}MB, Available: ${available_mb}MB"
        log "WARN" "Backup may fail if there isn't enough space for compression"
    fi

    return 0
}

# Main backup function with comprehensive error handling
perform_backup() {
    local backup_timestamp=$(date +'%Y%m%d-%H%M%S')
    local start_time=$(date +%s)

    log "DEBUG" "Backup timestamp: $backup_timestamp"

    # Get source size with error handling
    local size_before
    if ! size_before=$(du -sh "$BACKUP_SOURCE" 2>"$ERROR_LOG"); then
        local du_error=$(cat "$ERROR_LOG" 2>/dev/null)
        log "WARN" "Could not determine source size: ${du_error:-unknown}"
        size_before="unknown"
    else
        size_before=$(echo "$size_before" | cut -f1)
    fi

    # Set compression options
    local tar_flag ext compress_cmd
    case "$COMPRESSION" in
        zstd)
            tar_flag="--zstd"
            ext="tar.zst"
            compress_cmd="zstd"
            ;;
        gzip)
            tar_flag="-z"
            ext="tar.gz"
            compress_cmd="gzip"
            ;;
        xz)
            tar_flag="-J"
            ext="tar.xz"
            compress_cmd="xz"
            ;;
        *)
            log "ERROR" "Unknown compression method: '$COMPRESSION'"
            log "ERROR" "Valid options: zstd, gzip, xz"
            LAST_ERROR="Invalid compression method: $COMPRESSION"
            return 1
            ;;
    esac

    # Check compression tool availability
    if ! check_compression_tool "$COMPRESSION"; then
        LAST_ERROR="Compression tool '$compress_cmd' not available"
        return 1
    fi

    # Check disk space
    check_disk_space "$BACKUP_DEST" "$BACKUP_SOURCE"

    local backup_file="${BACKUP_DEST}/openclaw-backup-${backup_timestamp}.${ext}"

    log "INFO" "Starting backup of $BACKUP_SOURCE"
    log "INFO" "  Source size: $size_before"
    log "INFO" "  Compression: $COMPRESSION"
    log "INFO" "  Destination: $backup_file"

    # Log file count and structure
    local file_count=$(find "$BACKUP_SOURCE" -type f 2>/dev/null | wc -l | tr -d ' ')
    local dir_count=$(find "$BACKUP_SOURCE" -type d 2>/dev/null | wc -l | tr -d ' ')
    log "DEBUG" "Source contains: $file_count files, $dir_count directories"

    # Check source directory permissions
    if [[ ! -r "$BACKUP_SOURCE" ]]; then
        log "ERROR" "Cannot read source directory: $BACKUP_SOURCE"
        log "ERROR" "Permission denied - check directory permissions"
        LAST_ERROR="Cannot read source directory (permission denied)"
        return 1
    fi

    # Check destination directory permissions
    if [[ ! -w "$BACKUP_DEST" ]]; then
        log "ERROR" "Cannot write to destination directory: $BACKUP_DEST"
        log "ERROR" "Permission denied - check directory permissions"
        local dest_perms=$(ls -ld "$BACKUP_DEST" 2>/dev/null)
        log "DEBUG" "Destination permissions: $dest_perms"
        LAST_ERROR="Cannot write to destination directory (permission denied)"
        return 1
    fi

    # Construct tar command for logging
    local tar_cmd="tar $tar_flag -cf \"$backup_file\" -C \"$(dirname "$BACKUP_SOURCE")\" \"$(basename "$BACKUP_SOURCE")\""
    log "DEBUG" "Executing: $tar_cmd"

    # Create backup with selected compression, capturing all output
    local tar_output
    local tar_exit_code

    # Use verbose mode in debug to see files being archived
    local verbose_flag=""
    [[ "$DEBUG" == "true" ]] && verbose_flag="-v"

    tar_output=$(tar $tar_flag $verbose_flag -cf "$backup_file" -C "$(dirname "$BACKUP_SOURCE")" "$(basename "$BACKUP_SOURCE")" 2>&1)
    tar_exit_code=$?

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $tar_exit_code -ne 0 ]]; then
        log "ERROR" "tar command failed with exit code: $tar_exit_code"

        # Parse and log the actual error
        if [[ -n "$tar_output" ]]; then
            log "ERROR" "tar error output:"
            log_multiline "ERROR" "  " "$tar_output"
        fi

        # Common tar exit codes
        case $tar_exit_code in
            1)
                log "ERROR" "tar: Some files differ (changed during archive)"
                LAST_ERROR="Files changed during backup"
                ;;
            2)
                log "ERROR" "tar: Fatal error (usually permission or I/O error)"
                LAST_ERROR="tar fatal error - check permissions or disk"
                ;;
            *)
                LAST_ERROR="tar failed with exit code $tar_exit_code: ${tar_output:-unknown error}"
                ;;
        esac

        # Check if partial file was created
        if [[ -f "$backup_file" ]]; then
            local partial_size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
            log "WARN" "Partial backup file exists: $backup_file ($partial_size)"
            log "INFO" "Removing partial backup file"
            rm -f "$backup_file" || log "WARN" "Could not remove partial backup file"
        fi

        notify_telegram "Backup FAILED: $LAST_ERROR" "error"
        return 1
    fi

    # Verify backup file was created
    if [[ ! -f "$backup_file" ]]; then
        log "ERROR" "Backup file was not created: $backup_file"
        LAST_ERROR="Backup file not created despite tar success"
        notify_telegram "Backup FAILED: file not created" "error"
        return 1
    fi

    # Get backup file size
    local backup_size
    if ! backup_size=$(du -h "$backup_file" 2>"$ERROR_LOG" | cut -f1); then
        local du_error=$(cat "$ERROR_LOG" 2>/dev/null)
        log "WARN" "Could not determine backup size: ${du_error:-unknown}"
        backup_size="unknown"
    fi

    # Verify backup file is not empty
    local backup_bytes=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
    if [[ "$backup_bytes" -eq 0 ]]; then
        log "ERROR" "Backup file is empty (0 bytes): $backup_file"
        LAST_ERROR="Backup file is empty"
        rm -f "$backup_file"
        notify_telegram "Backup FAILED: empty file created" "error"
        return 1
    fi

    # Calculate compression ratio
    local source_kb=$(du -sk "$BACKUP_SOURCE" 2>/dev/null | cut -f1)
    local backup_kb=$(du -sk "$backup_file" 2>/dev/null | cut -f1)
    local ratio="N/A"
    if [[ -n "$source_kb" && -n "$backup_kb" && "$source_kb" -gt 0 ]]; then
        ratio=$(awk "BEGIN {printf \"%.1f\", ($source_kb / $backup_kb)}")
    fi

    log "INFO" "Backup completed successfully"
    log "INFO" "  Backup file: $backup_file"
    log "INFO" "  Original size: $size_before"
    log "INFO" "  Compressed size: $backup_size"
    log "INFO" "  Compression ratio: ${ratio}x"
    log "INFO" "  Duration: ${duration}s"

    # Log verbose tar output in debug mode
    if [[ "$DEBUG" == "true" && -n "$tar_output" ]]; then
        local archived_count=$(echo "$tar_output" | wc -l | tr -d ' ')
        log "DEBUG" "Archived $archived_count items"
    fi

    notify_telegram "Backup successful ($backup_size, ${ratio}x compression, ${duration}s)" "success"
    return 0
}

# Log system information for diagnostics
log_system_info() {
    log "DEBUG" "=== System Information ==="
    log "DEBUG" "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
    log "DEBUG" "User: $(whoami 2>/dev/null || echo 'unknown')"
    log "DEBUG" "Shell: $SHELL"
    log "DEBUG" "Bash version: ${BASH_VERSION:-unknown}"
    log "DEBUG" "Working directory: $(pwd)"
    log "DEBUG" "Script directory: $SCRIPT_DIR"
    log "DEBUG" "OS: $(uname -s 2>/dev/null || echo 'unknown') $(uname -r 2>/dev/null || echo '')"

    # Log tar version
    local tar_version=$(tar --version 2>&1 | head -n1)
    log "DEBUG" "tar version: $tar_version"

    # Log disk usage
    local dest_df=$(df -h "$BACKUP_DEST" 2>/dev/null | tail -n1)
    log "DEBUG" "Destination disk: $dest_df"
}

# Log current configuration
log_configuration() {
    log "DEBUG" "=== Configuration ==="
    log "DEBUG" "BACKUP_SOURCE: $BACKUP_SOURCE"
    log "DEBUG" "BACKUP_DEST: $BACKUP_DEST"
    log "DEBUG" "COMPRESSION: $COMPRESSION"
    log "DEBUG" "RETENTION_DAYS: $RETENTION_DAYS"
    log "DEBUG" "LOG_FILE: $LOG_FILE"
    log "DEBUG" "DEBUG mode: $DEBUG"

    if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
        log "DEBUG" "Telegram: configured (token length: ${#TELEGRAM_BOT_TOKEN})"
    else
        log "DEBUG" "Telegram: not configured"
    fi
}

# Validate prerequisites before backup
validate_prerequisites() {
    local errors=0

    log "DEBUG" "Validating prerequisites..."

    # Check tar is available
    if ! command -v tar &>/dev/null; then
        log "ERROR" "tar command not found"
        ((errors++))
    fi

    # Check curl for telegram (optional)
    if [[ -n "$TELEGRAM_BOT_TOKEN" ]] && ! command -v curl &>/dev/null; then
        log "WARN" "curl not found - Telegram notifications will not work"
    fi

    # Check source directory
    if [[ ! -e "$BACKUP_SOURCE" ]]; then
        log "ERROR" "Source does not exist: $BACKUP_SOURCE"
        ((errors++))
    elif [[ ! -d "$BACKUP_SOURCE" ]]; then
        log "ERROR" "Source is not a directory: $BACKUP_SOURCE"
        local source_type=$(file "$BACKUP_SOURCE" 2>/dev/null)
        log "DEBUG" "Source type: $source_type"
        ((errors++))
    elif [[ ! -r "$BACKUP_SOURCE" ]]; then
        log "ERROR" "Source is not readable: $BACKUP_SOURCE"
        local source_perms=$(ls -ld "$BACKUP_SOURCE" 2>/dev/null)
        log "DEBUG" "Source permissions: $source_perms"
        ((errors++))
    fi

    # Check source is not empty
    if [[ -d "$BACKUP_SOURCE" ]]; then
        local item_count=$(ls -A "$BACKUP_SOURCE" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$item_count" -eq 0 ]]; then
            log "WARN" "Source directory is empty: $BACKUP_SOURCE"
        else
            log "DEBUG" "Source contains $item_count items at top level"
        fi
    fi

    # Check destination directory
    if [[ ! -d "$BACKUP_DEST" ]]; then
        log "ERROR" "Destination directory does not exist: $BACKUP_DEST"
        ((errors++))
    elif [[ ! -w "$BACKUP_DEST" ]]; then
        log "ERROR" "Destination is not writable: $BACKUP_DEST"
        local dest_perms=$(ls -ld "$BACKUP_DEST" 2>/dev/null)
        log "DEBUG" "Destination permissions: $dest_perms"
        ((errors++))
    fi

    # List existing backups
    local existing_backups=$(find "$BACKUP_DEST" -maxdepth 1 \( -name "openclaw-backup-*.tar.*" \) -type f 2>/dev/null | wc -l | tr -d ' ')
    log "DEBUG" "Existing backups in destination: $existing_backups"

    return $errors
}

# Main execution with comprehensive logging
main() {
    log "INFO" "========================================="
    log "INFO" "=== OpenClaw Backup Started ==="
    log "INFO" "========================================="

    # Log system info and configuration in debug mode
    log_system_info
    log_configuration

    # Validate all prerequisites
    if ! validate_prerequisites; then
        log "ERROR" "Prerequisite validation failed"
        notify_telegram "Backup FAILED: prerequisite check failed" "error"
        exit 1
    fi

    log "DEBUG" "All prerequisites validated successfully"

    # Perform backup
    local backup_result=0
    if perform_backup; then
        log "DEBUG" "Backup function completed successfully"

        # Cleanup old backups (non-fatal if fails)
        if ! cleanup_old_backups; then
            log "WARN" "Cleanup had some failures, but backup succeeded"
        fi

        log "INFO" "========================================="
        log "INFO" "=== OpenClaw Backup Completed Successfully ==="
        log "INFO" "========================================="
    else
        log "ERROR" "Backup function failed"
        if [[ -n "$LAST_ERROR" ]]; then
            log "ERROR" "Last error: $LAST_ERROR"
        fi
        log "INFO" "========================================="
        log "ERROR" "=== OpenClaw Backup Failed ==="
        log "INFO" "========================================="
        backup_result=1
    fi

    # Log final summary
    log "DEBUG" "Exit code: $backup_result"
    exit $backup_result
}

main "$@"
