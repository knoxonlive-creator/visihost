#!/bin/bash

# --- CONFIG ---
REMOTE_LIVE="gdrive:us1free/LIVE_MIRROR"
GAME_DATA="/var/lib/pterodactyl/volumes"
WINGS_CONFIG="/etc/pterodactyl"
# --------------

echo "⚠️  WARNING: You are about to RESTORE 'us1free' System!"
echo "This will OVERWRITE all current data on this Game VPS."
echo "Type 'yes' to continue:"
read CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "❌ Restore Cancelled."
    exit 1
fi

echo "🛑 Stopping Wings..."
systemctl stop wings

# --- 1. RESTORE CONFIG ---
echo "⚙️ Restoring Wings Config..."
rclone copy "$REMOTE_LIVE/Wings_Config" $WINGS_CONFIG

# --- 2. RESTORE GAME DATA ---
echo "⬇️ Downloading Game Data (This will take time)..."
rclone sync "$REMOTE_LIVE/Game_Data" $GAME_DATA --transfers=16 --progress

# --- 3. FIX PERMISSIONS ---
echo "🔒 Fixing Permissions..."
chown -R pterodactyl:pterodactyl $GAME_DATA
chmod -R 755 $GAME_DATA
# Wings config permissions (Important)
chmod -R 644 /etc/pterodactyl/config.yml

echo "🦅 Starting Wings..."
systemctl start wings

echo "🎉 US1FREE SYSTEM RESTORED!"
