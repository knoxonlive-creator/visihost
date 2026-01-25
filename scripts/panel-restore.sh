#!/bin/bash
# ===============================================================
# Pterodactyl Panel Restore Script
# Restores: Panel files, .env, MySQL database
# ===============================================================

# Load configuration
CONFIG_FILE="/etc/pterodactyl-backup/panel.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "Please run the installer first."
    exit 1
fi

# Temp directory for database restore
TEMP_DIR="/tmp/pterodactyl-restore-$(date +%s)"

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
# GET DATABASE CREDENTIALS FROM .ENV
# =====================================================

get_db_credentials() {
    local env_file="$PANEL_DIR/.env"
    
    if [ ! -f "$env_file" ]; then
        log_error ".env file not found at $env_file"
        return 1
    fi
    
    DB_HOST=$(grep -E "^DB_HOST=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PORT=$(grep -E "^DB_PORT=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_DATABASE=$(grep -E "^DB_DATABASE=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_USERNAME=$(grep -E "^DB_USERNAME=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PASSWORD=$(grep -E "^DB_PASSWORD=" "$env_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    
    DB_HOST=${DB_HOST:-127.0.0.1}
    DB_PORT=${DB_PORT:-3306}
    
    if [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ]; then
        log_error "Could not extract database credentials from .env"
        return 1
    fi
    
    return 0
}

# =====================================================
# SHOW MENU
# =====================================================

show_menu() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "🔄 Pterodactyl Panel Restore"
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
    echo "What will be restored:"
    echo "  - .env file"
    echo "  - MySQL database"
    if [ "$BACKUP_SCOPE" = "2" ]; then
        echo "  - Panel files"
    fi
    echo ""
    echo "Panel Directory: $PANEL_DIR"
    echo ""
    
    read -p "Type 'yes' to confirm: " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "Cancelled"
        return 1
    fi
    return 0
}

# =====================================================
# DO RESTORE
# =====================================================

do_restore() {
    local source="$1"
    local errors=0
    
    mkdir -p "$TEMP_DIR"
    
    log "⬇️ Restoring from: $source"
    
    # Step 1: Restore .env first (we need DB credentials)
    log "Restoring .env file..."
    if rclone copy "$source/Config/.env" "$PANEL_DIR/" 2>&1; then
        log_success ".env restored"
    else
        log_error ".env restore failed"
        ((errors++))
    fi
    
    # Step 2: Restore database
    log "Downloading database dump..."
    if rclone copy "$source/Database/database.sql.gz" "$TEMP_DIR/" 2>&1; then
        log_success "Database dump downloaded"
        
        # Decompress
        gunzip "$TEMP_DIR/database.sql.gz" 2>/dev/null
        
        # Get credentials
        if get_db_credentials; then
            log "Restoring database..."
            
            # Stop panel services
            systemctl stop pteroq 2>/dev/null
            
            if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" \
                "$DB_DATABASE" < "$TEMP_DIR/database.sql" 2>/dev/null; then
                log_success "Database restored"
            else
                log_error "Database restore failed"
                ((errors++))
            fi
        else
            log_error "Could not get database credentials"
            ((errors++))
        fi
    else
        log_error "Database download failed"
        ((errors++))
    fi
    
    # Step 3: Restore nginx config if exists
    log "Checking for nginx config..."
    if rclone copy "$source/Config/pterodactyl.conf" "/etc/nginx/sites-available/" 2>&1; then
        log_success "Nginx config restored"
    fi
    
    # Step 4: Restore panel files if full backup
    if [ "$BACKUP_SCOPE" = "2" ]; then
        log "Restoring panel files..."
        
        # Check if we have a tarball backup or legacy folder
        if rclone lsf "$source/Panel_Files/panel_files.tar.gz" >/dev/null 2>&1; then
            log "Detected compressed backup (Fast Restore)..."
            
            # Download tarball
            if rclone copy "$source/Panel_Files/panel_files.tar.gz" "$TEMP_DIR/" 2>&1; then
                log "Extracting panel files..."
                
                # Extract to panel dir
                tar -xzf "$TEMP_DIR/panel_files.tar.gz" -C "$(dirname "$PANEL_DIR")" 2>&1
                
                if [ $? -eq 0 ]; then
                    log_success "Panel files restored from tarball"
                else
                    log_error "Panel extraction failed"
                    ((errors++))
                fi
            else
                log_error "Panel tarball download failed"
                ((errors++))
            fi
        else
            # Legacy fallback
            log "Detected legacy backup (Standard Restore)..."
            if rclone copy "$source/Panel_Files" "$PANEL_DIR" \
                --transfers=$TRANSFERS \
                --bwlimit "$BANDWIDTH_LIMIT" \
                --progress 2>&1; then
                log_success "Panel files restored"
            else
                log_error "Panel files restore failed"
                ((errors++))
            fi
        fi
    fi
    
    return $errors
}

# =====================================================
# CLEANUP
# =====================================================

cleanup_temp() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# =====================================================
# RESTART SERVICES
# =====================================================

restart_services() {
    log "🔄 Restarting services..."
    
    # Clear cache
    if [ -d "$PANEL_DIR" ]; then
        cd "$PANEL_DIR"
        php artisan config:clear 2>/dev/null
        php artisan cache:clear 2>/dev/null
        php artisan view:clear 2>/dev/null
    fi
    
    # Restart queue worker
    systemctl restart pteroq 2>/dev/null && log_success "pteroq restarted"
    
    # Reload nginx
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null && log_success "nginx reloaded"
    
    # Restart PHP-FPM
    systemctl restart php8.1-fpm 2>/dev/null || systemctl restart php8.0-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null
    log_success "PHP-FPM restarted"
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
    
    # Trap for cleanup
    trap cleanup_temp EXIT
    
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
    
    # Restore
    local start_time=$(date +%s)
    do_restore "$source"
    local result=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Restart services
    restart_services
    
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
