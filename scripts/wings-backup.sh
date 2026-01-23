#!/bin/bash
# ===============================================================
# Pterodactyl Wings Backup Script
# Keeps only N backups in History - deletes oldest when limit reached
# LIVE_MIRROR = always latest state
# ===============================================================

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
            --transfers=$TRANSFERS \
            --bwlimit "$BANDWIDTH_LIMIT" \
            --log-level ERROR 2>&1
        
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
        rclone sync "$GAME_DATA" "$REMOTE_LIVE/Game_Data" \
            --transfers=$TRANSFERS \
            --bwlimit "$BANDWIDTH_LIMIT" \
            --exclude "*.log" \
            --exclude "**/.cache/**" \
            --exclude "**/cache/**" \
            --exclude "**/tmp/**" \
            --exclude "**/temp/**" \
            --exclude "**/node_modules/**" \
            --exclude "**/.git/**" \
            --exclude "**/.npm/**" \
            --log-level ERROR 2>&1
        
        if [ $? -eq 0 ]; then
            log_success "Game data synced"
        else
            log_error "Game data sync failed"
            ((errors++))
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
        --log-level ERROR 2>&1; then
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
    
    # Step 3: Create History backup (copy from LIVE_MIRROR)
    create_history_backup
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Get final backup count
    local final_count=$(rclone lsd "$REMOTE_HISTORY" 2>/dev/null | wc -l)
    
    # Final report
    log "════════════════════════════════════════════════════"
    if [ $result -eq 0 ]; then
        log_success "Backup Completed Successfully"
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
        log "════════════════════════════════════════════════════"
        
        send_discord "❌ **Wings Backup Failed**
🖥️ Server: $(hostname)"
        
        exit 1
    fi
}

# Execute
main
