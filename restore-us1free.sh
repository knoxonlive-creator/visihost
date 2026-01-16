#!/bin/bash

# ==========================================
# 🛡️ FINAL PTERODACTYL RESTORE SYSTEM
#    Target: us1free/History
# ==========================================

# --- CONFIGURATION ---
REMOTE="gdrive"
# ✅ FIX: Ab hum 'Server_Backups' nahi, 'us1free' scan karenge
SCAN_PATH="us1free/History"

VOLUMES_DEST="/var/lib/pterodactyl/volumes"
CONFIG_DEST="/etc/pterodactyl"
MOUNT_POINT="/var/lib/pterodactyl/volumes"

# --- COLORS ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}   🚀 AUTO-RESTORE: us1free EDITION           ${NC}"
echo -e "${CYAN}==============================================${NC}"

# 1. 🛡️ SAFETY CHECK (Storage Mount)
echo -e "${YELLOW}🔍 [1/6] Verifying Storage Mount...${NC}"
if mountpoint -q "$MOUNT_POINT"; then
    echo -e "${GREEN}   ✅ Storage is mounted! Safe to proceed.${NC}"
else
    echo -e "${RED}   ❌ FATAL ERROR: Storage ($MOUNT_POINT) mount nahi hai!${NC}"
    echo -e "${RED}   Script rok raha hoon taake VPS full na ho.${NC}"
    exit 1
fi

# 2. 🔍 INTELLIGENT SCANNER (us1free)
echo -e "${YELLOW}🔍 [2/6] Scanning 'us1free/History' for Valid Backups...${NC}"

# Check agar path exist bhi karta hai ya nahi
if ! rclone lsd "$REMOTE:$SCAN_PATH" > /dev/null 2>&1; then
    echo -e "${RED}❌ ERROR: Path '$REMOTE:$SCAN_PATH' nahi mila!${NC}"
    echo -e "${YELLOW}   Checking root folders for you...${NC}"
    rclone lsd "$REMOTE:"
    exit 1
fi

# Get list (Newest -> Oldest)
BACKUP_LIST=$(rclone lsd "$REMOTE:$SCAN_PATH" | sort -k 2,3 | awk '{print $5}' | tac)
FOUND_BACKUP=""

for BACKUP_DATE in $BACKUP_LIST; do
    # CHECK: Kya is date me 'Game_Data' hai?
    CHECK_PATH="$REMOTE:$SCAN_PATH/$BACKUP_DATE/Game_Data"
    
    # Hum rclone lsd se check karenge (Fast & Accurate)
    if rclone lsd "$CHECK_PATH" > /dev/null 2>&1; then
        echo -e "${GREEN}   ✅ FOUND VALID BACKUP: $BACKUP_DATE${NC}"
        FOUND_BACKUP="$BACKUP_DATE"
        break
    else
        echo -e "${YELLOW}   ⚠️ Skipping $BACKUP_DATE (Game_Data missing)${NC}"
    fi
done

if [ -z "$FOUND_BACKUP" ]; then
    echo -e "${RED}❌ ERROR: Pure 'us1free/History' me koi dhang ka backup nahi mila!${NC}"
    exit 1
fi

# Paths Set Karo
SOURCE_GAME="$REMOTE:$SCAN_PATH/$FOUND_BACKUP/Game_Data"
SOURCE_CONFIG="$REMOTE:$SCAN_PATH/$FOUND_BACKUP/Wings_Config"

# 3. 🛑 STOP WINGS
echo -e "${YELLOW}🛑 [3/6] Stopping Wings Service...${NC}"
systemctl stop wings 2>/dev/null

# 4. 🚀 RESTORE GAME DATA
echo -e "${YELLOW}🚀 [4/6] Restoring Game Data (Volumes)...${NC}"
echo -e "   Source: $SOURCE_GAME"
# --transfers=32 (Max Speed)
rclone copy "$SOURCE_GAME" "$VOLUMES_DEST" --transfers=32 --progress --create-empty-src-dirs

# 5. ⚙️ RESTORE CONFIG
echo -e "${YELLOW}⚙️ [5/6] Restoring Wings Config...${NC}"
if rclone lsd "$SOURCE_CONFIG" > /dev/null 2>&1; then
    echo -e "   Source: $SOURCE_CONFIG"
    rclone copy "$SOURCE_CONFIG" "$CONFIG_DEST" --transfers=4
    echo -e "${GREEN}   ✅ Config Restore Successful!${NC}"
else
    echo -e "${RED}   ⚠️ Wings_Config folder nahi mila. Skipping.${NC}"
fi

# 6. 🔒 FIX PERMISSIONS & START
echo -e "${YELLOW}🔒 [6/6] Finalizing...${NC}"

# User Check
if ! id "pterodactyl" &>/dev/null; then
    useradd -d /var/lib/pterodactyl -m -s /bin/bash pterodactyl
    groupadd docker 2>/dev/null
    usermod -aG docker pterodactyl
fi

# Fix Ownership
chown -R pterodactyl:pterodactyl "$VOLUMES_DEST"
chmod -R 755 "$VOLUMES_DEST"
chown -R pterodactyl:pterodactyl "$CONFIG_DEST"
chmod 644 "$CONFIG_DEST/config.yml" 2>/dev/null

# Start Wings
systemctl start wings
echo -e "${GREEN}✅ Wings Started!${NC}"

echo -e "${CYAN}==============================================${NC}"
echo -e "${GREEN}🎉 RESTORE COMPLETE! ($FOUND_BACKUP)${NC}"
echo -e "${CYAN}==============================================${NC}"
