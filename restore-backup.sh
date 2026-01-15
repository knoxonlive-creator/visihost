#!/bin/bash

# --- CONFIG ---
DB_USER="pterodactyl"
DB_PASS="sparkle"
DB_NAME="panel"
REMOTE_HISTORY="gdrive:Server_Backups/History"
TEMP_DIR="/root/restore_temp"
# --------------

echo "🛑 STOPPING PANEL SERVICES..."
# Queue worker rokte hain taake beech me koi error na aaye
php /var/www/pterodactyl/artisan down 2>/dev/null

echo "📂 AVAILABLE BACKUPS ON GOOGLE DRIVE:"
echo "-------------------------------------"
# Sirf folders dikhaye taake user date choose kar sake
rclone lsd "$REMOTE_HISTORY" | tail -n 10
echo "-------------------------------------"

echo "❓ Enter the DATE folder name to restore (e.g., 2026-01-15_21-45):"
read BACKUP_DATE

if [ -z "$BACKUP_DATE" ]; then
    echo "❌ Error: Date cannot be empty."
    exit 1
fi

REMOTE_PATH="$REMOTE_HISTORY/$BACKUP_DATE/Panel_Full"

echo "🔍 Checking if backup exists..."
# Check karte hain ki us date me file hai ya nahi
FILE_NAME=$(rclone lsl "$REMOTE_PATH" | grep ".tar.gz" | awk '{print $4}')

if [ -z "$FILE_NAME" ]; then
    echo "❌ Backup file not found in $BACKUP_DATE!"
    exit 1
fi

echo "⬇️ Downloading Backup ($FILE_NAME)..."
mkdir -p $TEMP_DIR
rclone copy "$REMOTE_PATH/$FILE_NAME" $TEMP_DIR

echo "🗜️ Extracting Files..."
tar -xzf "$TEMP_DIR/$FILE_NAME" -C $TEMP_DIR

echo "♻️ RESTORING DATABASE..."
# SQL file dhund kar restore karte hain
SQL_FILE=$(find $TEMP_DIR -name "*.sql" | head -n 1)
if [ -f "$SQL_FILE" ]; then
    mysql -u $DB_USER -p"$DB_PASS" $DB_NAME < "$SQL_FILE"
    echo "✅ Database Restored."
else
    echo "⚠️ Warning: No SQL file found!"
fi

echo "♻️ RESTORING PANEL FILES..."
# Files ko wapas asli jagah copy karte hain
cp -r $TEMP_DIR/var/www/pterodactyl/* /var/www/pterodactyl/
cp $TEMP_DIR/var/www/pterodactyl/.env /var/www/pterodactyl/.env

echo "🔧 FIXING PERMISSIONS..."
chown -R www-data:www-data /var/www/pterodactyl
chmod -R 755 /var/www/pterodactyl

echo "🧹 CLEANING UP..."
rm -rf $TEMP_DIR
php /var/www/pterodactyl/artisan up
php /var/www/pterodactyl/artisan queue:restart

echo "🎉 PANEL RESTORE COMPLETE!"
