#!/bin/bash
# ===============================================================
# Pterodactyl Wings Backup Script
# Keeps only N backups in History - deletes oldest when limit reached
# LIVE_MIRROR = always latest state
# ===============================================================

# Ensure PATH covers common locations for rclone/system binaries (CRITICAL for cron)
# Ensure PATH covers common locations for rclone/system binaries (CRITICAL for cron)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Load configuration
CONFIG_FILE="/etc/pterodactyl-backup/wings.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "Please run the installer first: bash <(curl -s https://raw.githubusercontent.com/knoxonlive-creator/visihost/main/install.sh)"
    exit 1
fi

# Timestamp for this backup
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
TEMP_DIR="/tmp/wings-backup-$TIMESTAMP"

# Rclone config path (auto-detect)
RCLONE_CONFIG=""
for cfg in /root/.config/rclone/rclone.conf /home/*/.config/rclone/rclone.conf; do
    if [ -f "$cfg" ]; then
        RCLONE_CONFIG="$cfg"
        break
    fi
done

if [ -n "$RCLONE_CONFIG" ]; then
    export RCLONE_CONFIG
fi

# Fallback for LOG_FILE if not set in config
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="/var/log/pterodactyl-backup.log"
fi

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Debug logging for Cron
echo "[$(date)] Cron started wings-backup.sh" >> /tmp/backup-cron-debug.log
echo "PATH=$PATH" >> /tmp/backup-cron-debug.log

# Determine Rclone flags (Progress bar if interactive, silent if cron)
if [ -t 1 ]; then
    RCLONE_FLAGS="--progress"
else
    RCLONE_FLAGS="--log-level ERROR"
fi

# =====================================================


# =====================================================
# LOCKING
# =====================================================

LOCK_FILE="/var/run/pterodactyl-wings-backup.lock"

# Check Lock
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps -p "$PID" > /dev/null; then
        echo "⚠️  Backup ready running (PID: $PID). Exiting."
        exit 1
    else
        echo "⚠️  Stale lock file found. Removing."
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock
echo $$ > "$LOCK_FILE"

# =====================================================
# LOGGING FUNCTIONS
# =====================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERROR: $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1" | tee -a "$LOG_FILE"
}

send_discord() {
    local message="$1"
    if [ -n "$DISCORD_WEBHOOK" ]; then
        curl -s -H "Content-Type: application/json" \
             -d "{\"content\":\"$message\"}" \
             "$DISCORD_WEBHOOK" > /dev/null 2>&1
    fi
}

# =====================================================
# PREREQUISITES CHECK
# =====================================================

check_prerequisites() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        log_error "Must run as root"
        exit 1
    fi
    
    # Check rclone
    if ! command -v rclone &> /dev/null; then
        log_error "rclone not installed"
        exit 1
    fi
    
    # Check remote connection
    if ! rclone lsd "gdrive:" &> /dev/null; then
        log_error "Cannot connect to Google Drive"
        exit 1
    fi
    
    log_success "Connected to Google Drive"
}

# =====================================================
# CLEANUP OLD BACKUPS
# =====================================================

cleanup_old_backups() {
    # Cleanup temp dir
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi

    log "🗑️ Checking History backup count..."
    
    # Get list of all backups sorted by name (oldest first)
    local backup_list=$(rclone lsd "$REMOTE_HISTORY" 2>/dev/null | awk '{print $5}' | sort)
    local backup_count=$(echo "$backup_list" | grep -c . 2>/dev/null || true)
    
    log "Current backups in History: $backup_count (max: $MAX_BACKUPS)"
    
    # If we have MAX_BACKUPS or more, delete oldest ones
    if [ "$backup_count" -ge "$MAX_BACKUPS" ]; then
        local to_delete=$((backup_count - MAX_BACKUPS + 1))
        log "Deleting $to_delete old backup(s)..."
        
        echo "$backup_list" | head -n "$to_delete" | while read -r old_backup; do
            if [ -n "$old_backup" ]; then
                log "Deleting: $old_backup"
                rclone purge "$REMOTE_HISTORY/$old_backup" --log-level ERROR 2>/dev/null
                log_success "Deleted: $old_backup"
            fi
        done
    fi
}

# =====================================================
# SYNC TO LIVE MIRROR
# =====================================================

sync_live_mirror() {
    log "🔄 Syncing to LIVE_MIRROR..."
    
    local errors=0
    
    # Sync Wings Config
    if [ -d "$WINGS_CONFIG" ]; then
        log "Syncing Wings config..."
        rclone sync "$WINGS_CONFIG" "$REMOTE_LIVE/Wings_Config" \
            --transfers=32 \
            --checkers=64 \
            --bwlimit "$BANDWIDTH_LIMIT" \
            $RCLONE_FLAGS 2>&1
        
        if [ $? -eq 0 ]; then
            log_success "Wings config synced"
        else
            log_error "Wings config sync failed"
            ((errors++))
        fi
    fi
    
    # Sync Game Data
    if [ -d "$GAME_DATA" ]; then
        log "Syncing game data..."
        
        # Purge legacy folders if they exist
        if rclone lsf "$REMOTE_LIVE/Game_Data/" --dirs-only >/dev/null 2>&1; then
            log "Cleaning old legacy files..."
            rclone purge "$REMOTE_LIVE/Game_Data/" --log-level ERROR 2>/dev/null || true
        fi
        rclone purge "$REMOTE_LIVE/Game_Data_Files/" --log-level ERROR 2>/dev/null || true

        # HYBRID STRATEGY: Check disk space for safe local backup
        local game_size=$(du -sb "$GAME_DATA" | awk '{print $1}')
        local available_space=$(df -k /tmp | tail -1 | awk '{print $4}') # 1K blocks
        local available_bytes=$((available_space * 1024))
        local required_bytes=$((game_size + 1073741824)) # Size + 1GB buffer
        
        local use_local_backup=false
        
        if [ "$available_bytes" -gt "$required_bytes" ]; then
            use_local_backup=true
        fi
        
        API_FLAGS="--tpslimit 2 --drive-pacer-min-sleep 100ms --retries 5"

        if [ "$use_local_backup" = true ]; then
            log "Method: Local Compression (Stable & Resumable)"
            local local_tar="$TEMP_DIR/game_data.tar.gz"
            mkdir -p "$TEMP_DIR"
            
            # Create local tarball
            # Note: We allow exit code 1 because game files often change during backup
            local tar_log="$TEMP_DIR/tar_error.log"
            tar -czf "$local_tar" -C "$(dirname "$GAME_DATA")" "$(basename "$GAME_DATA")" \
                --exclude="*.log" \
                --exclude="**/.cache" \
                --exclude="**/cache" \
                --exclude="**/tmp" \
                --exclude="**/temp" \
                --exclude="**/node_modules" \
                --exclude="**/.git" \
                --exclude="**/.npm" 2> "$tar_log"
            
            local tar_status=$?
            if [ $tar_status -eq 0 ] || [ $tar_status -eq 1 ]; then
                [ $tar_status -eq 1 ] && log "⚠️  Some files changed during compression (ignoring)"
                
                log "Uploading local tarball..."
                rclone copy "$local_tar" "$REMOTE_LIVE/" \
                    $RCLONE_FLAGS $API_FLAGS \
                    --transfers=4 \
                    --drive-chunk-size=64M 2>&1
                    
                local upload_status=$?
                rm -f "$local_tar"
                rm -f "$tar_log"
                
                if [ $upload_status -eq 0 ]; then
                    log_success "Game data uploaded via Local method"
                else
                    log_error "Game data upload failed"
                    ((errors++))
                    return 1
                fi
            else
                log_error "Local compression failed (Exit Code: $tar_status)"
                log_error "Tar Errors:"
                cat "$tar_log" | tee -a "$LOG_FILE"
                rm -f "$tar_log"
                ((errors++))
                return 1
            fi
            
        else
            log "Method: Streaming Upload (Low Disk Space Mode)"
            
            # Stream tar directly
            tar -cf - -C "$(dirname "$GAME_DATA")" "$(basename "$GAME_DATA")" \
                --exclude="*.log" \
                --exclude="**/.cache" \
                --exclude="**/cache" \
                --exclude="**/tmp" \
                --exclude="**/temp" \
                --exclude="**/node_modules" \
                --exclude="**/.git" \
                --exclude="**/.npm" \
                2>/dev/null | gzip -1 | \
                rclone rcat "$REMOTE_LIVE/game_data.tar.gz" \
                $RCLONE_FLAGS $API_FLAGS \
                --drive-chunk-size=64M 2>&1
            
            local rcat_status=${PIPESTATUS[2]}
            if [ $rcat_status -eq 0 ] || [ $rcat_status -eq 1 ] || [ ${PIPESTATUS[0]} -eq 1 ]; then
                log_success "Game data uploaded via Streaming method"
            else
                log_error "Game data upload failed"
                ((errors++))
                return 1
            fi
        fi
    fi
    
    return $errors
}

# =====================================================
# CREATE HISTORY BACKUP
# =====================================================

create_history_backup() {
    log "📦 Creating History backup: $TIMESTAMP"
    
    # Copy from LIVE_MIRROR to History (server-side copy, fast!)
    if rclone copy "$REMOTE_LIVE" "$REMOTE_HISTORY/$TIMESTAMP" \
        $RCLONE_FLAGS 2>&1; then
        log_success "History backup created: $TIMESTAMP"
        return 0
    else
        log_error "History backup failed"
        return 1
    fi
}

# =====================================================
# MAIN EXECUTION
# =====================================================

main() {
    local start_time=$(date +%s)
    
    log "════════════════════════════════════════════════════"
    log "🚀 Starting Wings Backup"
    log "════════════════════════════════════════════════════"
    log "Config: $CONFIG_FILE"
    log "Game Data: $GAME_DATA"
    log "Wings Config: $WINGS_CONFIG"
    log "Remote: $REMOTE_HISTORY"
    log "Max Backups: $MAX_BACKUPS"
    log "════════════════════════════════════════════════════"
    
    # Check prerequisites
    check_prerequisites
    
    # Step 1: Delete old backups FIRST (to save space)
    cleanup_old_backups
    
    # Step 2: Sync to LIVE_MIRROR
    sync_live_mirror
    local result=$?
    
    # Step 3: Create History backup (ONLY if sync succeeded and not skipped)
    if [ $result -eq 0 ]; then
        if [ "$SKIP_HISTORY" = "true" ] || [ "$SKIP_HISTORY" = "1" ]; then
            log "⏭️  Skipping History backup (as requested)"
        else
            create_history_backup
        fi
    else
        log_error "Skipping History backup due to sync failures"
    fi
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Get final backup count
    local final_count=$(rclone lsd "$REMOTE_HISTORY" 2>/dev/null | wc -l)
    
    # Final report
    log "════════════════════════════════════════════════════"
    if [ $result -eq 0 ]; then
        log_success "Backup Completed Successfully"
        rm -f "$LOCK_FILE"
        log "Duration: ${duration}s"
        log "History Backups: $final_count/$MAX_BACKUPS"
        log "════════════════════════════════════════════════════"
        
        send_discord "✅ **Wings Backup Complete**
⏱️ Duration: ${duration}s
💾 History: $final_count/$MAX_BACKUPS
🖥️ Server: $(hostname)"
        
        exit 0
    else
        log_error "Backup Completed with errors"
        rm -f "$LOCK_FILE"
        log "════════════════════════════════════════════════════"
        
        send_discord "❌ **Wings Backup Failed**
🖥️ Server: $(hostname)"
        
        exit 1
    fi
}

# Execute
main
