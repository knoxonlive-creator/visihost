#!/bin/bash
# ===============================================================
# Pterodactyl Panel Backup Script
# Backs up: Panel files, .env, MySQL database
# Keeps only N backups in History
# ===============================================================

# Ensure PATH covers common locations for rclone/system binaries (CRITICAL for cron)
# Ensure PATH covers common locations for rclone/system binaries (CRITICAL for cron)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Load configuration
CONFIG_FILE="/etc/pterodactyl-backup/panel.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "Please run the installer first: bash <(curl -s https://raw.githubusercontent.com/knoxonlive-creator/visihost/main/install.sh)"
    exit 1
fi

# Timestamp for this backup
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

# Temp directory for database dump
TEMP_DIR="/tmp/pterodactyl-backup-$TIMESTAMP"

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
echo "[$(date)] Cron started panel-backup.sh" >> /tmp/backup-cron-debug.log
echo "PATH=$PATH" >> /tmp/backup-cron-debug.log

# Determine Rclone flags (Progress bar if interactive, silent if cron)
if [ -t 1 ]; then
    RCLONE_FLAGS="--progress"
else
    RCLONE_FLAGS="--log-level ERROR"
fi

# =====================================================


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
    
    # Defaults
    DB_HOST=${DB_HOST:-127.0.0.1}
    DB_PORT=${DB_PORT:-3306}
    
    if [ -z "$DB_DATABASE" ] || [ -z "$DB_USERNAME" ]; then
        log_error "Could not extract database credentials from .env"
        return 1
    fi
    
    log_success "Database credentials loaded: $DB_DATABASE@$DB_HOST"
    return 0
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
    
    # Check mysqldump
    if ! command -v mysqldump &> /dev/null; then
        log_error "mysqldump not installed"
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
    
    local backup_list=$(rclone lsd "$REMOTE_HISTORY" 2>/dev/null | awk '{print $5}' | sort)
    local backup_count=$(echo "$backup_list" | grep -c . 2>/dev/null || true)
    
    log "Current backups in History: $backup_count (max: $MAX_BACKUPS)"
    
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
# BACKUP DATABASE
# =====================================================

backup_database() {
    log "🗄️ Backing up database..."
    
    mkdir -p "$TEMP_DIR"
    
    if ! get_db_credentials; then
        return 1
    fi
    
    local dump_file="$TEMP_DIR/database.sql"
    
    if mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" \
        "$DB_DATABASE" > "$dump_file" 2>/dev/null; then
        
        # Compress
        gzip "$dump_file"
        log_success "Database dumped: $dump_file.gz"
        return 0
    else
        log_error "Database dump failed"
        return 1
    fi
}

# =====================================================
# SYNC TO LIVE MIRROR
# =====================================================

sync_live_mirror() {
    log "🔄 Syncing to LIVE_MIRROR..."
    
    local errors=0
    
    # Sync database dump
    if [ -f "$TEMP_DIR/database.sql.gz" ]; then
        log "Syncing database dump..."
        rclone copy "$TEMP_DIR/database.sql.gz" "$REMOTE_LIVE/Database/" \
            $RCLONE_FLAGS 2>&1
        
        if [ $? -eq 0 ]; then
            log_success "Database synced"
        else
            log_error "Database sync failed"
            ((errors++))
        fi
    fi
    
    # Sync .env file
    if [ -f "$PANEL_DIR/.env" ]; then
        log "Syncing .env file..."
        rclone copy "$PANEL_DIR/.env" "$REMOTE_LIVE/Config/" \
            $RCLONE_FLAGS 2>&1
        
        if [ $? -eq 0 ]; then
            log_success ".env synced"
        else
            log_error ".env sync failed"
            ((errors++))
        fi
    fi
    
    # Sync Nginx config
    if [ -f "/etc/nginx/sites-available/pterodactyl.conf" ]; then
        log "Syncing Nginx config..."
        rclone copy "/etc/nginx/sites-available/pterodactyl.conf" "$REMOTE_LIVE/Config/" \
            $RCLONE_FLAGS 2>&1
        log_success "Nginx config synced"
    fi
    
    # Full panel sync if BACKUP_SCOPE is 2
    if [ "$BACKUP_SCOPE" = "2" ]; then
        log "Compressing panel files (this is much faster)..."
        
        # Create tarball
        local tarball="$TEMP_DIR/panel_files.tar.gz"
        
        # Tar excludes
        # We cd to PANEL_DIR to avoid full paths in tar
        tar -czf "$tarball" \
            --exclude="node_modules" \
            --exclude="vendor" \
            --exclude=".git" \
            --exclude="storage/logs" \
            --exclude="storage/framework/cache" \
            -C "$(dirname "$PANEL_DIR")" "$(basename "$PANEL_DIR")" 2>/dev/null
            
        if [ $? -eq 0 ]; then
            log_success "Panel compressed: $(du -sh "$tarball" | awk '{print $1}')"
            
            log "Uploading panel tarball..."
            rclone copy "$tarball" "$REMOTE_LIVE/Panel_Files/" \
                --transfers=32 \
                --bwlimit "$BANDWIDTH_LIMIT" \
                --drive-chunk-size 128M \
                $RCLONE_FLAGS 2>&1
            
            if [ $? -eq 0 ]; then
                log_success "Panel backup uploaded"
            else
                log_error "Panel upload failed"
                ((errors++))
            fi
        else
            log_error "Panel compression failed"
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
# CLEANUP
# =====================================================

cleanup_temp() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# =====================================================
# MAIN EXECUTION
# =====================================================

main() {
    local start_time=$(date +%s)
    
    log "════════════════════════════════════════════════════"
    log "🚀 Starting Panel Backup"
    log "════════════════════════════════════════════════════"
    log "Config: $CONFIG_FILE"
    log "Panel Dir: $PANEL_DIR"
    log "Backup Scope: $BACKUP_SCOPE (1=minimal, 2=full)"
    log "Remote: $REMOTE_HISTORY"
    log "Max Backups: $MAX_BACKUPS"
    log "════════════════════════════════════════════════════"
    
    # Trap for cleanup
    trap cleanup_temp EXIT
    
    # Check prerequisites
    check_prerequisites
    
    # Step 1: Backup database
    backup_database
    
    # Step 2: Delete old backups
    cleanup_old_backups
    
    # Step 3: Sync to LIVE_MIRROR
    sync_live_mirror
    local result=$?
    
    # Step 4: Create History backup
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
        
        send_discord "✅ **Panel Backup Complete**
⏱️ Duration: ${duration}s
💾 History: $final_count/$MAX_BACKUPS
🖥️ Server: $(hostname)"
        
        exit 0
    else
        log_error "Backup Completed with errors"
        log "════════════════════════════════════════════════════"
        
        send_discord "❌ **Panel Backup Failed**
🖥️ Server: $(hostname)"
        
        exit 1
    fi
}

# Execute
main
