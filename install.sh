#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service
#
# Usage:
#   Local install (from git clone):  sudo ./install.sh
#   Remote install (without git):    curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | sudo bash
#   Specific version:                curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | sudo bash -s v0.1.0

set -e

GITHUB_REPO="gruz/strema"
REQUESTED_VERSION="${1:-latest}"

echo "=========================================="
echo "Installing Forpost Stream"
echo "=========================================="

# Remember original user (before sudo elevation)
ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_UID=$(id -u "$ORIGINAL_USER")
ORIGINAL_GID=$(id -g "$ORIGINAL_USER")

# Install in user's home directory
ORIGINAL_HOME=$(eval echo ~$ORIGINAL_USER)
INSTALL_DIR="$ORIGINAL_HOME/strema"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Detect if running from local directory or remote
if [ -f "$(dirname "${BASH_SOURCE[0]}")/VERSION" ] || [ -f "$(dirname "${BASH_SOURCE[0]}")/scripts/start_stream.sh" ]; then
    # Local installation (git clone)
    echo "📁 Local installation detected"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_INSTALL=true
else
    # Remote installation (curl)
    echo "🌐 Remote installation - downloading from GitHub"
    LOCAL_INSTALL=false
    
    # Check if this is an update (installation directory already exists)
    IS_UPDATE=false
    if [ -d "$INSTALL_DIR" ]; then
        echo "⚠️  Installation directory exists - this is an update"
        IS_UPDATE=true
        
        # Backup existing config if present
        if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
            echo "Backing up configuration..."
            TMP_BACKUP=$(mktemp -d)
            cp "$INSTALL_DIR/config/stream.conf" "$TMP_BACKUP/stream.conf.backup"
        fi
    else
        echo "Fresh installation detected"
    fi
    
    # Determine installation source
    if [ "$REQUESTED_VERSION" = "latest" ]; then
        # Install from master branch (latest development version)
        echo "📦 Installing latest version from master branch..."
        BRANCH="master"
        ARCHIVE_URL="https://github.com/$GITHUB_REPO/archive/refs/heads/$BRANCH.tar.gz"
        
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        echo "Downloading $ARCHIVE_URL..."
        if ! curl -fsSL -o "strema-master.tar.gz" "$ARCHIVE_URL"; then
            echo "❌ Error: Failed to download from master branch"
            rm -rf "$TMP_DIR"
            exit 1
        fi
        
        # Extract archive (GitHub creates a folder named repo-branch)
        echo "Extracting archive..."
        tar -xzf "strema-master.tar.gz"
        
        # Move to installation directory
        if [ -d "$INSTALL_DIR" ]; then
            rm -rf "$INSTALL_DIR"
        fi
        
        mkdir -p "$(dirname "$INSTALL_DIR")"
        mv strema-$BRANCH "$INSTALL_DIR"
        
    else
        # Install specific release version
        VERSION="$REQUESTED_VERSION"
        echo "📦 Installing release version: $VERSION"
        
        # Download release archive
        ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/strema-$VERSION.tar.gz"
        CHECKSUM_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/checksums.txt"
        
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        echo "Downloading $ARCHIVE_URL..."
        if ! curl -fsSL -o "strema-$VERSION.tar.gz" "$ARCHIVE_URL"; then
            echo "❌ Error: Failed to download release archive"
            echo "   Make sure release $VERSION exists on GitHub"
            rm -rf "$TMP_DIR"
            exit 1
        fi
        
        # Verify checksum
        echo "Verifying checksum..."
        if curl -fsSL -o checksums.txt "$CHECKSUM_URL" 2>/dev/null; then
            if sha256sum -c checksums.txt 2>/dev/null | grep -q "strema-$VERSION.tar.gz: OK"; then
                echo "✅ Checksum verified"
            else
                echo "⚠️  Warning: Checksum verification failed, but continuing..."
            fi
        else
            echo "⚠️  Warning: Could not download checksums, skipping verification"
        fi
        
        # Extract archive
        echo "Extracting archive..."
        tar -xzf "strema-$VERSION.tar.gz"
        
        # Move to installation directory
        if [ -d "$INSTALL_DIR" ]; then
            rm -rf "$INSTALL_DIR"
        fi
        
        mkdir -p "$(dirname "$INSTALL_DIR")"
        mv strema "$INSTALL_DIR"
    fi
    
    # Restore config if backed up
    if [ -n "$TMP_BACKUP" ] && [ -f "$TMP_BACKUP/stream.conf.backup" ]; then
        echo "Restoring configuration..."
        cp "$TMP_BACKUP/stream.conf.backup" "$INSTALL_DIR/config/stream.conf"
        rm -rf "$TMP_BACKUP"
    fi
    
    # Cleanup
    cd /
    rm -rf "$TMP_DIR"
    
    SCRIPT_DIR="$INSTALL_DIR"
fi

CONFIG_FILE="$SCRIPT_DIR/config/stream.conf"

# Install dependencies
echo ""
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y ffmpeg strace python3-flask iproute2 jq

# Generate configuration
echo ""
echo "[2/7] Configuring..."

echo "Configuration will be created on first visit in the web UI."

# Generate service_manager.sh from template
echo ""
echo "[3/7] Generating service manager..."
if [ -f "$SCRIPT_DIR/scripts/service_manager.sh.template" ]; then
    cp "$SCRIPT_DIR/scripts/service_manager.sh.template" "$SCRIPT_DIR/scripts/service_manager.sh"
    echo "✅ Service manager generated from template"
else
    echo "❌ Error: service_manager.sh.template not found"
    exit 1
fi

# Check required files
echo ""
echo "[4/7] Checking files..."
REQUIRED_FILES=(
    "$SCRIPT_DIR/scripts/start_stream.sh"
    "$SCRIPT_DIR/scripts/get_frequency.sh"
    "$SCRIPT_DIR/scripts/update_frequency.sh"
    "$SCRIPT_DIR/scripts/watchdog.sh"
    "$SCRIPT_DIR/scripts/udp_proxy.sh"
    "$SCRIPT_DIR/scripts/service_manager.sh"
    "$SCRIPT_DIR/scripts/handle_config_change.sh"
    "$SCRIPT_DIR/scripts/update_autorestart.sh"
    "$SCRIPT_DIR/web/web_config.py"
    "$SCRIPT_DIR/web/templates/index.html"
    "$SCRIPT_DIR/web/templates/installer.html"
)

# VERSION file is optional - will be created by GitHub Action or get_version.sh
if [ ! -f "$SCRIPT_DIR/VERSION" ] && [ "$LOCAL_INSTALL" = true ]; then
    echo "⚠️  VERSION file not found, creating from git tag..."
    if git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' > "$SCRIPT_DIR/VERSION"; then
        echo "✅ Created VERSION from git tag: $(cat "$SCRIPT_DIR/VERSION")"
    else
        echo "unknown" > "$SCRIPT_DIR/VERSION"
        echo "⚠️  No git tags found, using 'unknown' version"
    fi
fi

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "Error: File not found: $file"
        exit 1
    fi
done

# Set execute permissions
chmod +x "$SCRIPT_DIR/scripts/"*.sh
chmod +x "$SCRIPT_DIR/web/web_config.py"

# Create logs directory if it doesn't exist
mkdir -p "$SCRIPT_DIR/logs"

# Fix ownership of config and logs directories
echo "Fixing ownership of config and logs directories..."
chown -R "$ORIGINAL_UID:$ORIGINAL_GID" "$SCRIPT_DIR/config" 2>/dev/null || true
chown -R "$ORIGINAL_UID:$ORIGINAL_GID" "$SCRIPT_DIR/logs" 2>/dev/null || true

echo "All files in place."

# Install systemd service
echo ""
echo "[5/7] Installing systemd services..."
source "$SCRIPT_DIR/scripts/service_manager.sh"
cleanup_old_services "$SCRIPT_DIR"
install_all_services "$SCRIPT_DIR"

# Enable and start services
echo ""
echo "[6/7] Enabling services..."

# Check if this is an update and restart services accordingly
if [ "$IS_UPDATE" = "true" ]; then
    echo "Update mode - applying configuration and restarting services..."
    
    # Always restart web service to apply new code
    echo "Restarting web service..."
    systemctl restart forpost-stream-web 2>/dev/null || systemctl start forpost-stream-web
    
    # Use handle_config_change.sh to manage stream service state
    # It will:
    # - Apply autostart setting from config (enable/disable)
    # - Restart stream only if it's currently running
    # - Handle UDP proxy if needed
    if [ -f "$SCRIPT_DIR/scripts/handle_config_change.sh" ]; then
        echo "Applying configuration settings..."
        # Force re-apply all settings by removing snapshot
        rm -f /tmp/forpost_config_snapshot.conf
        bash "$SCRIPT_DIR/scripts/handle_config_change.sh"
    fi
    
    echo "Update complete - services configured according to settings"
else
    echo "Fresh installation - starting services normally..."
    enable_services
    echo "All services enabled and started"
fi

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "[7/7] Getting network information..."
ALL_IPS=$(hostname -I 2>/dev/null | xargs)
IP_ADDRESS=$(echo "$ALL_IPS" | awk '{print $1}')
echo ""
echo "🌐 Web Interface: http://$IP_ADDRESS:8081"
if [ -n "$ALL_IPS" ]; then
    echo "   (All IPs: $ALL_IPS)"
fi
echo ""
echo "⚠️  Stream service is DISABLED by default."
echo "   Use the web interface to start/stop/configure streaming."
echo ""
echo "Useful commands:"
echo "  Web UI:     sudo systemctl status forpost-stream-web"
echo "  Stream:     sudo systemctl status forpost-stream"
echo "  Watchdog:   sudo systemctl status forpost-stream-watchdog.timer"
echo "  Logs:       sudo journalctl -u forpost-stream -f"
echo "  Stream log: tail -f $SCRIPT_DIR/logs/stream.log"
echo "  Watchdog:   tail -f $SCRIPT_DIR/logs/watchdog.log"
echo ""
echo "Watchdog enabled - monitors stream health every 2 minutes"
echo "Configuration will be created in the web UI: $SCRIPT_DIR/config/stream.conf"
echo ""
