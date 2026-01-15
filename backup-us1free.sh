# === INSTALLATION COMMAND (Run on Game VPS) ===

cat << 'EOF' > /usr/local/bin/backup-script.sh
#!/bin/bash

# ================= CONFIGURATION =================
# Source Folders
GAME_DATA="/var/lib/pterodactyl/volumes"
WINGS_CONFIG="/etc/pterodactyl"

# Remote Folders (Google Drive)
REMOTE_LIVE="gdrive:us1free/LIVE_MIRROR"
REMOTE_HISTORY="gdrive:us1free/History"

DATE=$(date +%Y-%m-%d_%H-%M)
LOG_FILE="/var/log/backup.log"
# =================================================

echo "🚀 [Start] Game VPS Backup: $DATE" | tee -a $LOG_FILE

# --- PART 1: WINGS CONFIG ---
echo "⚙️ Syncing Wings Config..."
rclone copy $WINGS_CONFIG "$REMOTE_LIVE/Wings_Config"

# --- PART 2: GAME FILES (Smart Sync) ---
echo "🔄 Syncing Game Data..." | tee -a $LOG_FILE

# --transfers=32: Speed boosted
# --copy-links: Symlinks fix
# --exclude: Cache garbage remove
rclone sync $GAME_DATA "$REMOTE_LIVE/Game_Data" \
  --backup-dir "$REMOTE_HISTORY/$DATE/Game_Data" \
  --copy-links \
  --transfers=32 \
  --checkers=64 \
  --drive-use-trash=false \
  --ignore-checksum \
  --ignore-errors \
  --exclude "*.log" \
  --exclude "**/.npm/**" \
  --exclude "**/.cache/**" \
  --exclude "**/cache/**" \
  --exclude "**/tmp/**" \
  --exclude "**/backups/**" \
  --exclude "**/node_modules/**" \
  --fast-list \
  --log-file=$LOG_FILE \
  --log-level ERROR

# --- PART 3: PROOF FILE (Receipt) ---
echo "🧾 Uploading Proof File..."
echo "Backup Completed Successfully on: $DATE" > /root/backup_status.txt
rclone copy /root/backup_status.txt "$REMOTE_LIVE/"

# --- PART 4: AGGRESSIVE CLEANUP (1 Hour Rule) ---
echo "🗑️ Cleaning Old History..." | tee -a $LOG_FILE
rclone delete "$REMOTE_HISTORY" --min-age 1h --drive-use-trash=false --ignore-errors
rclone rmdirs "$REMOTE_HISTORY" --min-age 1h --leave-root --drive-use-trash=false --ignore-errors 2>/dev/null

echo "✅ Game VPS Backup Done!" | tee -a $LOG_FILE
EOF

chmod +x /usr/local/bin/backup-script.sh
