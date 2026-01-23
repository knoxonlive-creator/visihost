#!/bin/bash
# ===============================================================
# Pterodactyl Backup System Installer
# GitHub: https://github.com/knoxonlive-creator/visihost
# One-liner: bash <(curl -s https://raw.githubusercontent.com/knoxonlive-creator/visihost/main/install.sh)
# ===============================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# GitHub Raw URL
GITHUB_RAW="https://raw.githubusercontent.com/knoxonlive-creator/visihost/main"

# Installation paths
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/pterodactyl-backup"
CONFIG_FILE="$CONFIG_DIR/config.conf"

# =====================================================
# UTILITY FUNCTIONS
# =====================================================

print_banner() {
    clear
    echo -e "${PURPLE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║     🦖 Pterodactyl Backup System Installer                ║"
    echo "║                                                            ║"
    echo "║     GitHub: knoxonlive-creator/visihost                   ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

print_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root: sudo bash install.sh"
        exit 1
    fi
}

# Detect server type
detect_server_type() {
    local has_panel=false
    local has_wings=false
    
    [ -d "/var/www/pterodactyl" ] && has_panel=true
    [ -d "/var/lib/pterodactyl" ] && has_wings=true
    
    if $has_panel && $has_wings; then
        echo "both"
    elif $has_panel; then
        echo "panel"
    elif $has_wings; then
        echo "wings"
    else
        echo "none"
    fi
}

# =====================================================
# MAIN MENU
# =====================================================

show_main_menu() {
    print_banner
    
    local server_type=$(detect_server_type)
    echo -e "${CYAN}Detected Server Type: ${YELLOW}$server_type${NC}"
    echo ""
    
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "  ${GREEN}1)${NC} Install Dependencies (rclone)"
    echo "  ${GREEN}2)${NC} Setup Backup"
    echo "  ${GREEN}3)${NC} Restore from Backup"
    echo "  ${GREEN}4)${NC} View Current Configuration"
    echo "  ${GREEN}5)${NC} Uninstall"
    echo ""
    echo "  ${RED}0)${NC} Exit"
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo ""
}

# =====================================================
# 1. INSTALL DEPENDENCIES
# =====================================================

install_dependencies() {
    print_banner
    echo -e "${CYAN}═══ Installing Dependencies ═══${NC}"
    echo ""
    
    # Install rclone
    print_step "Checking rclone..."
    if command -v rclone &> /dev/null; then
        print_success "rclone already installed: $(rclone --version | head -n1)"
    else
        print_step "Installing rclone..."
        curl https://rclone.org/install.sh | bash
        print_success "rclone installed"
    fi
    
    # Install curl if not present
    print_step "Checking curl..."
    if command -v curl &> /dev/null; then
        print_success "curl already installed"
    else
        print_step "Installing curl..."
        apt-get update && apt-get install -y curl
        print_success "curl installed"
    fi
    
    echo ""
    print_success "Dependencies installed!"
    echo ""
    
    # Setup rclone with Google Drive
    echo -e "${YELLOW}Would you like to configure rclone with Google Drive now?${NC}"
    read -p "Configure rclone? (y/n): " configure_rclone
    
    if [[ "$configure_rclone" =~ ^[Yy]$ ]]; then
        echo ""
        print_info "Running rclone config..."
        print_warning "Follow the prompts to add 'gdrive' as your Google Drive remote"
        echo ""
        rclone config
        
        # Test connection
        echo ""
        print_step "Testing Google Drive connection..."
        if rclone lsd gdrive: &> /dev/null; then
            print_success "Google Drive connected successfully!"
        else
            print_error "Could not connect to Google Drive. Please run 'rclone config' manually."
        fi
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# =====================================================
# 2. SETUP BACKUP
# =====================================================

setup_backup() {
    print_banner
    echo -e "${CYAN}═══ Backup Setup ═══${NC}"
    echo ""
    
    local server_type=$(detect_server_type)
    
    # Check rclone
    if ! command -v rclone &> /dev/null; then
        print_error "rclone not installed! Please run option 1 first."
        read -p "Press Enter to continue..."
        return
    fi
    
    # Test Google Drive connection
    print_step "Testing Google Drive connection..."
    if ! rclone lsd gdrive: &> /dev/null; then
        print_error "Cannot connect to Google Drive!"
        print_info "Run 'rclone config' to setup Google Drive."
        read -p "Press Enter to continue..."
        return
    fi
    print_success "Google Drive connected"
    echo ""
    
    # Select backup type
    echo "What would you like to backup?"
    echo ""
    echo "  1) Wings (Game servers data)"
    echo "  2) Panel (Database + Panel files)"
    echo "  3) Both"
    echo ""
    read -p "Select [1-3]: " backup_type
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
    
    case $backup_type in
        1)
            setup_wings_backup
            ;;
        2)
            setup_panel_backup
            ;;
        3)
            setup_wings_backup
            setup_panel_backup
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac
    
    read -p "Press Enter to continue..."
}

setup_wings_backup() {
    echo ""
    echo -e "${CYAN}═══ Wings Backup Configuration ═══${NC}"
    echo ""
    
    # Default values
    local default_game_data="/var/lib/pterodactyl/volumes"
    local default_wings_config="/etc/pterodactyl"
    local default_remote_path="gdrive:pterodactyl-backups/wings"
    local default_max_backups=4
    local default_cron="0 3 * * *"
    
    # Prompt for Server Name (for backup folder)
    echo ""
    print_info "Enter a unique name for this server (e.g., node-1, panel-vps)"
    read -p "Server Name: " server_name
    
    # Auto-generate remote path
    local default_remote_path="gdrive:visihost/${server_name}/wings"
    
    # Prompt for directories
    print_info "Enter directories to backup (press Enter for default)"
    echo ""
    
    read -p "Game Data Directory [$default_game_data]: " game_data
    game_data=${game_data:-$default_game_data}
    
    read -p "Wings Config Directory [$default_wings_config]: " wings_config
    wings_config=${wings_config:-$default_wings_config}
    
    echo ""
    print_info "Enter Google Drive path for backups"
    read -p "Remote Path [$default_remote_path]: " remote_path
    remote_path=${remote_path:-$default_remote_path}
    
    echo ""
    print_info "How many backups to keep in history?"
    read -p "Max Backups [$default_max_backups]: " max_backups
    max_backups=${max_backups:-$default_max_backups}
    
    echo ""
    print_info "Backup schedule (cron format)"
    echo "  Examples:"
    echo "    0 3 * * *     = Daily at 3 AM"
    echo "    0 */6 * * *   = Every 6 hours"
    echo "    0 0 * * 0     = Weekly on Sunday"
    read -p "Cron Schedule [$default_cron]: " cron_schedule
    cron_schedule=${cron_schedule:-$default_cron}
    
    echo ""
    print_info "Discord Webhook for notifications (optional, press Enter to skip)"
    read -p "Discord Webhook URL: " discord_webhook
    
    echo ""
    print_info "Bandwidth limit for uploads (e.g., 50M, 100M, 0 for unlimited)"
    read -p "Bandwidth Limit [50M]: " bandwidth_limit
    bandwidth_limit=${bandwidth_limit:-50M}
    
    # Save wings config
    cat > "$CONFIG_DIR/wings.conf" << EOF
# Wings Backup Configuration
# Generated: $(date)

# Source Directories
GAME_DATA="$game_data"
WINGS_CONFIG="$wings_config"

# Remote Paths
REMOTE_LIVE="$remote_path/LIVE_MIRROR"
REMOTE_HISTORY="$remote_path/History"

# Backup Settings
MAX_BACKUPS=$max_backups
BANDWIDTH_LIMIT="$bandwidth_limit"
TRANSFERS=16

# Notifications
DISCORD_WEBHOOK="$discord_webhook"

# Logging
LOG_FILE="/var/log/pterodactyl-wings-backup.log"
EOF

    print_success "Wings config saved to $CONFIG_DIR/wings.conf"
    
    # Download and install backup script
    print_step "Installing wings backup script..."
    curl -s "$GITHUB_RAW/scripts/wings-backup.sh" -o "$INSTALL_DIR/pterodactyl-wings-backup"
    chmod +x "$INSTALL_DIR/pterodactyl-wings-backup"
    print_success "Installed: $INSTALL_DIR/pterodactyl-wings-backup"
    
    # Download and install restore script
    print_step "Installing wings restore script..."
    curl -s "$GITHUB_RAW/scripts/wings-restore.sh" -o "$INSTALL_DIR/pterodactyl-wings-restore"
    chmod +x "$INSTALL_DIR/pterodactyl-wings-restore"
    print_success "Installed: $INSTALL_DIR/pterodactyl-wings-restore"
    
    # Setup cron job
    print_step "Setting up cron job..."
    (crontab -l 2>/dev/null | grep -v "pterodactyl-wings-backup"; echo "$cron_schedule /usr/local/bin/pterodactyl-wings-backup") | crontab -
    print_success "Cron job added: $cron_schedule"
    
    echo ""
    print_success "Wings backup setup complete!"
    echo ""
    echo "Commands:"
    echo "  • Run backup:  sudo pterodactyl-wings-backup"
    echo "  • Restore:     sudo pterodactyl-wings-restore"
    echo ""
}

setup_panel_backup() {
    echo ""
    echo -e "${CYAN}═══ Panel Backup Configuration ═══${NC}"
    echo ""
    
    # Default values
    local default_panel_dir="/var/www/pterodactyl"
    local default_remote_path="gdrive:pterodactyl-backups/panel"
    local default_max_backups=4
    local default_cron="0 4 * * *"
    
    # Prompt for Server Name (for backup folder)
    echo ""
    print_info "Enter a unique name for this server (e.g., panel-main)"
    read -p "Server Name: " server_name
    
    # Auto-generate remote path
    local default_remote_path="gdrive:visihost/${server_name}/panel"

    # Prompt for directories
    print_info "Enter Panel directory"
    read -p "Panel Directory [$default_panel_dir]: " panel_dir
    panel_dir=${panel_dir:-$default_panel_dir}
    
    # Check if .env exists
    if [ -f "$panel_dir/.env" ]; then
        print_success "Found .env file - will auto-detect database credentials"
    else
        print_warning ".env file not found in $panel_dir"
    fi
    
    echo ""
    print_info "Enter Google Drive path for backups"
    read -p "Remote Path [$default_remote_path]: " remote_path
    remote_path=${remote_path:-$default_remote_path}
    
    echo ""
    print_info "How many backups to keep in history?"
    read -p "Max Backups [$default_max_backups]: " max_backups
    max_backups=${max_backups:-$default_max_backups}
    
    echo ""
    print_info "What to backup?"
    echo "  1) Database + .env only (recommended, smaller)"
    echo "  2) Full panel directory + Database"
    read -p "Select [1-2]: " backup_scope
    
    echo ""
    print_info "Backup schedule (cron format)"
    read -p "Cron Schedule [$default_cron]: " cron_schedule
    cron_schedule=${cron_schedule:-$default_cron}
    
    echo ""
    print_info "Discord Webhook for notifications (optional)"
    read -p "Discord Webhook URL: " discord_webhook
    
    echo ""
    print_info "Bandwidth limit for uploads"
    read -p "Bandwidth Limit [50M]: " bandwidth_limit
    bandwidth_limit=${bandwidth_limit:-50M}
    
    # Save panel config
    cat > "$CONFIG_DIR/panel.conf" << EOF
# Panel Backup Configuration
# Generated: $(date)

# Source Directory
PANEL_DIR="$panel_dir"

# Backup Scope (1=minimal, 2=full)
BACKUP_SCOPE=$backup_scope

# Remote Paths
REMOTE_LIVE="$remote_path/LIVE_MIRROR"
REMOTE_HISTORY="$remote_path/History"

# Backup Settings
MAX_BACKUPS=$max_backups
BANDWIDTH_LIMIT="$bandwidth_limit"
TRANSFERS=16

# Notifications
DISCORD_WEBHOOK="$discord_webhook"

# Logging
LOG_FILE="/var/log/pterodactyl-panel-backup.log"
EOF

    print_success "Panel config saved to $CONFIG_DIR/panel.conf"
    
    # Download and install backup script
    print_step "Installing panel backup script..."
    curl -s "$GITHUB_RAW/scripts/panel-backup.sh" -o "$INSTALL_DIR/pterodactyl-panel-backup"
    chmod +x "$INSTALL_DIR/pterodactyl-panel-backup"
    print_success "Installed: $INSTALL_DIR/pterodactyl-panel-backup"
    
    # Download and install restore script
    print_step "Installing panel restore script..."
    curl -s "$GITHUB_RAW/scripts/panel-restore.sh" -o "$INSTALL_DIR/pterodactyl-panel-restore"
    chmod +x "$INSTALL_DIR/pterodactyl-panel-restore"
    print_success "Installed: $INSTALL_DIR/pterodactyl-panel-restore"
    
    # Setup cron job
    print_step "Setting up cron job..."
    (crontab -l 2>/dev/null | grep -v "pterodactyl-panel-backup"; echo "$cron_schedule /usr/local/bin/pterodactyl-panel-backup") | crontab -
    print_success "Cron job added: $cron_schedule"
    
    echo ""
    print_success "Panel backup setup complete!"
    echo ""
    echo "Commands:"
    echo "  • Run backup:  sudo pterodactyl-panel-backup"
    echo "  • Restore:     sudo pterodactyl-panel-restore"
    echo ""
}

# =====================================================
# 3. RESTORE
# =====================================================

restore_backup() {
    print_banner
    echo -e "${CYAN}═══ Restore Backup ═══${NC}"
    echo ""
    
    echo "What would you like to restore?"
    echo ""
    echo "  1) Wings (Game servers data)"
    echo "  2) Panel (Database + Panel files)"
    echo ""
    echo "  0) Back"
    echo ""
    read -p "Select [0-2]: " restore_type
    
    case $restore_type in
        0)
            return
            ;;
        1)
            if [ -f "$INSTALL_DIR/pterodactyl-wings-restore" ]; then
                "$INSTALL_DIR/pterodactyl-wings-restore"
            else
                print_error "Wings restore script not installed. Run Setup Backup first."
            fi
            ;;
        2)
            if [ -f "$INSTALL_DIR/pterodactyl-panel-restore" ]; then
                "$INSTALL_DIR/pterodactyl-panel-restore"
            else
                print_error "Panel restore script not installed. Run Setup Backup first."
            fi
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac
    
    read -p "Press Enter to continue..."
}

# =====================================================
# 4. VIEW CONFIGURATION
# =====================================================

view_config() {
    print_banner
    echo -e "${CYAN}═══ Current Configuration ═══${NC}"
    echo ""
    
    if [ -f "$CONFIG_DIR/wings.conf" ]; then
        echo -e "${GREEN}Wings Configuration:${NC}"
        echo "────────────────────────────────────────"
        cat "$CONFIG_DIR/wings.conf"
        echo ""
    else
        print_warning "Wings configuration not found"
    fi
    
    echo ""
    
    if [ -f "$CONFIG_DIR/panel.conf" ]; then
        echo -e "${GREEN}Panel Configuration:${NC}"
        echo "────────────────────────────────────────"
        cat "$CONFIG_DIR/panel.conf"
        echo ""
    else
        print_warning "Panel configuration not found"
    fi
    
    echo ""
    echo -e "${GREEN}Cron Jobs:${NC}"
    echo "────────────────────────────────────────"
    crontab -l 2>/dev/null | grep pterodactyl || echo "No cron jobs found"
    
    echo ""
    read -p "Press Enter to continue..."
}

# =====================================================
# 5. UNINSTALL
# =====================================================

uninstall() {
    print_banner
    echo -e "${RED}═══ Uninstall ═══${NC}"
    echo ""
    
    print_warning "This will remove:"
    echo "  • All backup/restore scripts"
    echo "  • Configuration files"
    echo "  • Cron jobs"
    echo ""
    print_warning "Your backups on Google Drive will NOT be deleted."
    echo ""
    
    read -p "Type 'yes' to confirm uninstall: " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Uninstall cancelled"
        read -p "Press Enter to continue..."
        return
    fi
    
    # Remove scripts
    rm -f "$INSTALL_DIR/pterodactyl-wings-backup"
    rm -f "$INSTALL_DIR/pterodactyl-wings-restore"
    rm -f "$INSTALL_DIR/pterodactyl-panel-backup"
    rm -f "$INSTALL_DIR/pterodactyl-panel-restore"
    
    # Remove config
    rm -rf "$CONFIG_DIR"
    
    # Remove cron jobs
    crontab -l 2>/dev/null | grep -v pterodactyl | crontab -
    
    print_success "Uninstalled successfully!"
    
    read -p "Press Enter to continue..."
}

# =====================================================
# MAIN LOOP
# =====================================================

main() {
    check_root
    
    while true; do
        show_main_menu
        read -p "Select option [0-5]: " choice
        
        case $choice in
            0)
                echo ""
                print_info "Bye! 👋"
                exit 0
                ;;
            1)
                install_dependencies
                ;;
            2)
                setup_backup
                ;;
            3)
                restore_backup
                ;;
            4)
                view_config
                ;;
            5)
                uninstall
                ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Run
main
