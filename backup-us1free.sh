#!/bin/bash

# ================= CONFIGURATION =================
# Source Folders
GAME_DATA="/var/lib/pterodactyl/volumes"
WINGS_CONFIG="/etc/pterodactyl"

# Remote Folders (Google Drive)
# Main Folder: us1free
REMOTE_LIVE="gdrive:us1free/LIVE_MIRROR"
REMOTE_HISTORY="gdrive:us1free/History"
DATE=$(date +%Y-%m-%d_%H-%M)
# =================================================

echo "🚀 [Start] Running US1FREE System Backup: $DATE"

# --- PART 1: WINGS CONFIG (Chota hai, seedha copy karo) ---
echo "⚙️ Backing up Wings Config..."
# Config files ko 'Config' folder me daal rahe hain
rclone copy $WINGS_CONFIG "$REMOTE_LIVE/Wings_Config"
rclone copy $WINGS_CONFIG "$REMOTE_HISTORY/$DATE/Wings_Config"

# --- PART 2: GAME FILES (Smart Sync - 100GB) ---
echo "🔄 Syncing Game Data..."
# Jo files change hui hain wo 'History' me jayengi
# Jo nayi hain wo 'LIVE_MIRROR' me update hongi
rclone sync $GAME_DATA "$REMOTE_LIVE/Game_Data" \
  --backup-dir "$REMOTE_HISTORY/$DATE/Game_Data" \
  --exclude "*.log" \
  --exclude "cache/**" \
  --exclude "backups/**" \
  --transfers=16 \
  --check-first \
  --fast-list

# --- PART 3: CLEANUP ---
echo "🗑️ Cleaning Old History..."
# 3 Din purana history delete karo
rclone delete "$REMOTE_HISTORY" --min-age 3d --rmdirs

echo "✅ US1FREE Backup Complete!"
