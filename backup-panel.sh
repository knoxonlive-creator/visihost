#!/bin/bash

# --- CONFIG (Storage VPS) ---
DB_USER="pterodactyl"
DB_PASS="sparkle"
DB_NAME="panel"

# Panel kahan install hai?
PANEL_DIR="/var/www/pterodactyl"

# Backup Kahan jayega?
REMOTE_HISTORY="gdrive:Server_Backups/History"
DATE=$(date +%Y-%m-%d_%H-%M)
TEMP_DIR="/root/temp_panel_backup"
# ----------------------------

echo "🚀 [Panel] Starting Full Backup: $DATE"

mkdir -p $TEMP_DIR

# 1. DATABASE BACKUP
echo "📦 Dumping Database..."
mysqldump -u $DB_USER -p"$DB_PASS" $DB_NAME > $TEMP_DIR/db_dump.sql

# 2. ZIP EVERYTHING (Database + Panel Files)
echo "🗜️ Zipping Panel Files & Database..."
# Hum Panel folder aur SQL file dono ko ek hi zip me daal rahe hain
# .env file zaroor honi chahiye, wo sabse important hai
tar -czf $TEMP_DIR/panel_full_$DATE.tar.gz \
    -C /var/www/pterodactyl . \
    -C $TEMP_DIR db_dump.sql

# 3. UPLOAD TO GOOGLE DRIVE
echo "☁️ Uploading to History..."
rclone copy $TEMP_DIR/panel_full_$DATE.tar.gz "$REMOTE_HISTORY/$DATE/Panel_Full"

# 4. CLEANUP (Local)
echo "🧹 Cleaning Local Temp..."
rm -rf $TEMP_DIR

# 5. OLD BACKUP DELETE (3 Days)
echo "🗑️ Removing Old Backups from Drive..."
rclone delete "$REMOTE_HISTORY" --min-age 3d --include "/Panel_Full/**" --rmdirs

echo "✅ Full Panel Backup Done!"
