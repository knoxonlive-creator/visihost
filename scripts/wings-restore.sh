#!/bin/bash
# ===============================================================
# Pterodactyl Wings Restore Script
# Restore from LIVE_MIRROR or History backups
# ===============================================================

# Load configuration
CONFIG_FILE="/etc/pterodactyl-backup/wings.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "Please run the installer first."
    exit 1
fi

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1" | tee -a "$LOG_FILE"
}

# =====================================================
# SHOW MENU
# =====================================================

show_menu() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "🔄 Pterodactyl Wings Restore"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo "Config: $CONFIG_FILE"
    echo "Remote: $REMOTE_HISTORY"
    echo ""
    echo "Restore Options:"
    echo ""
    echo "  1) LIVE_MIRROR  - Restore latest state"
    echo "  2) History      - Restore from backup history"
    echo ""
    echo "  0) Exit"
    echo ""
}

# =====================================================
# LIST HISTORY BACKUPS
# =====================================================

list_history() {
    log "📋 Fetching History backups..."
    echo ""
    
    local backups=$(timeout 30 rclone lsd "$REMOTE_HISTORY" 2>/dev/null | awk '{print $5}' | sort -r)
    
    if [ -z "$backups" ]; then
        log_error "No backups found in History"
        return 1
    fi
    
    echo "Available backups (newest first):"
    echo "════════════════════════════════════════"
    
    local i=1
    while IFS= read -r backup; do
        echo "  $i) $backup"
        ((i++))
    done <<< "$backups"
    
    echo "════════════════════════════════════════"
    echo "  0) Go back"
    echo ""
    
    echo "$backups"
}

# =====================================================
# CONFIRM RESTORE
# =====================================================

confirm_restore() {
    local source="$1"
    
    echo ""
    echo "⚠️  WARNING: This will OVERWRITE current data!"
    echo ""
    echo "Source: $source"
    echo ""
    echo "Destinations:"
    echo "  - Game Data:    $GAME_DATA"
    echo "  - Wings Config: $WINGS_CONFIG"
    echo ""
    
    read -p "Type 'yes' to confirm: " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "Cancelled"
        return 1
    fi
    return 0
}

# =====================================================
# WINGS SERVICE CONTROL
# =====================================================

stop_wings() {
    log "🛑 Stopping Wings..."
    if systemctl is-active --quiet wings 2>/dev/null; then
        systemctl stop wings
        sleep 2
        log_success "Wings stopped"
    else
        log "Wings not running"
    fi
}

start_wings() {
    log "🚀 Starting Wings..."
    systemctl start wings 2>/dev/null
    sleep 2
    if systemctl is-active --quiet wings 2>/dev/null; then
        log_success "Wings started"
    else
        log_error "Wings failed to start"
    fi
}

# =====================================================
# DO RESTORE
# =====================================================

do_restore() {
    local source="$1"
    local errors=0
    
    log "⬇️ Restoring from: $source"
    
    # Restore Wings Config
    log "Restoring Wings config..."
    if rclone copy "$source/Wings_Config" "$WINGS_CONFIG" \
        --transfers=$TRANSFERS \
        --bwlimit "$BANDWIDTH_LIMIT" 2>&1; then
        log_success "Wings config restored"
    else
        log_error "Wings config restore failed"
        ((errors++))
    fi
    
    # Restore Game Data
    log "Restoring game data..."
    
    # Check for streaming tarball first (Fast method)
    if rclone lsf "$source/game_data.tar.gz" >/dev/null 2>&1; then
        log "Detected streaming backup (Fast Restore)..."
        
        # Ensure destination exists
        mkdir -p "$(dirname "$GAME_DATA")"
        
        # Stream download and untar directly (No local temp space!)
        rclone cat "$source/game_data.tar.gz" $RCLONE_FLAGS | \
        tar -xzf - -C "$(dirname "$GAME_DATA")" 2>&1
        
        if [ ${PIPESTATUS[1]} -eq 0 ]; then
            log_success "Game data restored from stream"
        else
            log_error "Game data stream restore failed"
            ((errors++))
        fi
    else
        # Legacy fallback (Slow method)
        log "Detected legacy backup (Standard Restore)..."
        if rclone copy "$source/Game_Data" "$GAME_DATA" \
            --transfers=$TRANSFERS \
            --bwlimit "$BANDWIDTH_LIMIT" \
            --progress 2>&1; then
            log_success "Game data restored"
        else
            log_error "Game data restore failed"
            ((errors++))
        fi
    fi
    
    return $errors
}

# =====================================================
# MAIN
# =====================================================

main() {
    # Check root
    if [ "$EUID" -ne 0 ]; then 
        echo "❌ Run as root: sudo $0"
        exit 1
    fi
    
    # Check rclone
    if ! command -v rclone &> /dev/null; then
        echo "❌ rclone not installed"
        exit 1
    fi
    
    show_menu
    read -p "Select option [0-2]: " choice
    
    local source=""
    
    case $choice in
        0)
            echo "Bye!"
            exit 0
            ;;
        1)
            source="$REMOTE_LIVE"
            ;;
        2)
            local backups=$(list_history)
            if [ $? -ne 0 ]; then
                exit 1
            fi
            
            local backup_array=()
            while IFS= read -r line; do
                [ -n "$line" ] && backup_array+=("$line")
            done <<< "$backups"
            
            read -p "Select backup [1-${#backup_array[@]}]: " bchoice
            
            if [ "$bchoice" = "0" ]; then
                main
                return
            fi
            
            if [ "$bchoice" -ge 1 ] 2>/dev/null && [ "$bchoice" -le "${#backup_array[@]}" ] 2>/dev/null; then
                local selected="${backup_array[$((bchoice-1))]}"
                source="$REMOTE_HISTORY/$selected"
            else
                log_error "Invalid selection"
                exit 1
            fi
            ;;
        *)
            echo "Invalid option"
            exit 1
            ;;
    esac
    
    # Confirm
    if ! confirm_restore "$source"; then
        exit 0
    fi
    
    # Stop Wings
    stop_wings
    
    # Restore
    local start_time=$(date +%s)
    do_restore "$source"
    local result=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Start Wings
    start_wings
    
    # Done
    log "════════════════════════════════════════════════════"
    if [ $result -eq 0 ]; then
        log_success "Restore Completed! Duration: ${duration}s"
    else
        log_error "Restore completed with errors"
    fi
    log "════════════════════════════════════════════════════"
}

main
