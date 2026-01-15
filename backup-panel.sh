# === INSTALLATION COMMAND (Run on Panel VPS) ===

cat << 'EOF' > /usr/local/bin/panel-backup.sh
#!/bin/bash

# ================= CONFIGURATION =================
# Panel Location
PANEL_DIR="/var/www/pterodactyl"
DB_NAME="panel"

# Remote Folders
REMOTE_HISTORY="gdrive:Server_Backups/History"
DATE=$(date +%Y-%m-%d_%H-%M)

# FIX: Use /tmp to avoid Permission Denied errors
TEMP_DIR="/tmp/temp_panel_backup"
# =================================================

echo "🚀 [Panel] Starting Backup: $DATE"

# Clean start
rm -rf $TEMP_DIR
mkdir -p $TEMP_DIR

# 1. DATABASE BACKUP (Master Key Method)
echo "📦 Dumping Database..."

# Try 1: Debian System Config (No password needed)
if [ -f /etc/mysql/debian.cnf ]; then
    sudo mysqldump --defaults-extra-file=/etc/mysql/debian.cnf $DB_NAME > $TEMP_DIR/db_dump.sql
else
    # Try 2: Root fallback
    sudo mysqldump -u root $DB_NAME > $TEMP_DIR/db_dump.sql
fi

# Validation
if [ ! -s "$TEMP_DIR/db_dump.sql" ]; then
    echo "❌ CRITICAL: Database dump failed or empty!"
    exit 1
fi

# 2. ZIP EVERYTHING (Force Sudo)
echo "🗜️ Zipping Panel Files & Database..."
sudo tar -czf $TEMP_DIR/panel_full_$DATE.tar.gz \
    -C $PANEL_DIR . \
    -C $TEMP_DIR db_dump.sql

# Validation
if [ ! -f "$TEMP_DIR/panel_full_$DATE.tar.gz" ]; then
    echo "❌ CRITICAL: Zip file creation failed!"
    exit 1
fi

# 3. UPLOAD TO GOOGLE DRIVE
echo "☁️ Uploading to History..."
rclone copy $TEMP_DIR/panel_full_$DATE.tar.gz "$REMOTE_HISTORY/$DATE/Panel_Full" --drive-use-trash=false

# 4. CLEANUP (Local)
echo "🧹 Cleaning Local Temp..."
sudo rm -rf $TEMP_DIR

# 5. AGGRESSIVE CLEANUP (Cloud - 1 Hour Rule)
echo "🗑️ Removing Old Backups..."
rclone delete "$REMOTE_HISTORY" --min-age 1h --include "/Panel_Full/**" --drive-use-trash=false --ignore-errors
rclone rmdirs "$REMOTE_HISTORY" --min-age 1h --leave-root --drive-use-trash=false --ignore-errors 2>/dev/null

echo "✅ Full Panel Backup Successful!"
EOF

chmod +x /usr/local/bin/panel-backup.sh
