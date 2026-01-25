# 🦖 Pterodactyl Backup System

One-liner installer for automated Pterodactyl Panel & Wings backup to Google Drive.

## ⚡ Quick Install

```bash
bash <(curl -s https://raw.githubusercontent.com/knoxonlive-creator/visihost/main/install.sh)
```

## 📋 Features

### Installer Menu
1. **Install Dependencies** - Installs rclone, configures Google Drive
2. **Setup Backup** - Interactive setup with prompts for:
   - Source directories
   - Google Drive path
   - Max backups to keep
   - Cron schedule
   - Discord webhook (optional)
3. **Restore Backup** - Interactive restore from LIVE_MIRROR or History
4. **View Configuration** - Show current settings
5. **Uninstall** - Remove all scripts and configs

### Backup Types

| Type | What's Backed Up |
|------|-----------------|
| **Wings** | Game data (`/var/lib/pterodactyl/volumes`), Wings config (`/etc/pterodactyl`) |
| **Panel** | MySQL database, `.env` file, Nginx config, Panel files (optional) |

### ⚡ Performance & Safety
- 🚀 **Hybrid Backup Strategy** - Automatically chooses the fastest/safest method:
  - **Local Compression**: Uses local disk if space permits (Fastest & Resume-supported)
  - **Streaming Mode**: Falls back to `rcat` streaming if disk is full (Zero-space backup)
- 🔒 **Execution Locking** - Prevents backup overlaps (Critical for cron)
- 💾 **Disk Safety Checks** - Prevents filling up `/tmp`
- 🛡️ **API Rate Limiting** - Built-in throttling to prevent Google Drive 429 Bans

### Smart Features
- 📁 **LIVE_MIRROR** - Always keeps latest state
- 📦 **History** - Keeps N backups (configurable)
- 🗑️ **Auto-cleanup** - Deletes oldest backup when limit reached
- 🔔 **Discord notifications** - Optional webhook support
- ⏰ **Cron jobs** - Automatic scheduled backups

## 🚀 Usage

After setup, use these commands:

```bash
# Wings
sudo pterodactyl-wings-backup    # Run backup
sudo pterodactyl-wings-restore   # Restore from backup

# Panel
sudo pterodactyl-panel-backup    # Run backup
sudo pterodactyl-panel-restore   # Restore from backup
```

## 📁 Files

```
/etc/pterodactyl-backup/
├── wings.conf          # Wings configuration
└── panel.conf          # Panel configuration

/usr/local/bin/
├── pterodactyl-wings-backup
├── pterodactyl-wings-restore
├── pterodactyl-panel-backup
└── pterodactyl-panel-restore
```

## 🔧 Manual Configuration

Edit config files directly:

```bash
sudo nano /etc/pterodactyl-backup/wings.conf
sudo nano /etc/pterodactyl-backup/panel.conf
```

## 📝 Logs

```bash
# Wings logs
tail -f /var/log/pterodactyl-wings-backup.log

# Panel logs
tail -f /var/log/pterodactyl-panel-backup.log
```

## 🔗 Requirements

- Ubuntu/Debian Linux
- Root access
- rclone (installed by script)
- Google Drive account

## 📜 License

MIT License
