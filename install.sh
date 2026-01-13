#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service
#
# Usage:
#   Remote install:    curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash
#   Specific version:  curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash -s v0.1.0
#   Local install:     ./install.sh

set -e

GITHUB_REPO="gruz/strema"
VERSION="${1:-latest}"
[ -z "$VERSION" ] && VERSION="latest"

echo "=========================================="
echo "Installing Forpost Stream"
echo "=========================================="

# Determine real user (handle both 'bash' and 'sudo bash' cases)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(eval echo ~$SUDO_USER)
    echo "⚠️  Detected sudo - installing for user: $REAL_USER"
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

# Check if user has sudo access
if ! sudo -n true 2>/dev/null; then
    echo "❌ Error: This script requires sudo access"
    echo "   Please ensure your user has sudo privileges"
    exit 1
fi

# Stop and remove all old forpost services FIRST
echo ""
echo "[1/5] Stopping and removing old services..."
STREAM_WAS_ACTIVE=false
if [ "$(sudo systemctl is-active forpost-stream 2>/dev/null)" = "active" ]; then
    STREAM_WAS_ACTIVE=true
    echo "📝 Stream service is running - will restart after update"
fi

sudo systemctl stop 'forpost-*' 2>/dev/null || true
sudo systemctl disable 'forpost-*' 2>/dev/null || true
sudo rm -f /etc/systemd/system/forpost-*
sudo systemctl daemon-reload

# Now analyze what we have and what to do
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLD_INSTALL_DIR="$REAL_HOME/FORPOST/strema"
NEW_INSTALL_DIR="$REAL_HOME/strema"

# Check for migration
if [ -d "$OLD_INSTALL_DIR" ] && [ ! -d "$NEW_INSTALL_DIR" ]; then
    echo ""
    echo "⚠️  Found old installation at: $OLD_INSTALL_DIR"
    echo "   Migrating to new location: $NEW_INSTALL_DIR"
    mv "$OLD_INSTALL_DIR" "$NEW_INSTALL_DIR"
    echo "✅ Migration complete"
    echo "   Note: Old directory $REAL_HOME/FORPOST still exists (may contain other files)"
    INSTALL_DIR="$NEW_INSTALL_DIR"
elif [ -d "$OLD_INSTALL_DIR" ] && [ -d "$NEW_INSTALL_DIR" ]; then
    echo "⚠️  Found installations in both locations:"
    echo "   Old: $OLD_INSTALL_DIR"
    echo "   New: $NEW_INSTALL_DIR"
    echo "   Using new location. You can manually remove old one."
    INSTALL_DIR="$NEW_INSTALL_DIR"
else
    INSTALL_DIR="$NEW_INSTALL_DIR"
fi

# Check installation type and update files
if [ -d "$SCRIPT_DIR/.git" ]; then
    # Git installation
    echo ""
    echo "📁 Git installation detected"
    
    if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
        echo "⚠️  Warning: Git installation is at $SCRIPT_DIR"
        echo "   Expected location: $INSTALL_DIR"
        echo "   Continuing with current location..."
        INSTALL_DIR="$SCRIPT_DIR"
    fi
    
    cd "$INSTALL_DIR"
    
    # Stash local changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "💾 Stashing local changes..."
        git stash push -m "Auto-stash before install.sh update $(date +%Y%m%d_%H%M%S)"
    fi
    
    # Update from git
    echo "Updating from git..."
    git fetch origin
    
    if [ "$VERSION" = "latest" ]; then
        echo "Pulling latest from master..."
        git reset --hard origin/master
    else
        echo "Checking out version $VERSION..."
        git fetch --tags
        git reset --hard "$VERSION"
    fi
    
    echo "✅ Git update complete"
    
elif [ -d "$INSTALL_DIR" ]; then
    # Remote installation - update existing
    echo ""
    echo "🌐 Remote installation - updating"
    
    # Backup config
    if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
        TMP_BACKUP="/tmp/strema_config_backup_$$"
        cp "$INSTALL_DIR/config/stream.conf" "$TMP_BACKUP"
    fi
    
    # Download and extract
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    if [ "$VERSION" = "latest" ]; then
        echo "Downloading latest from master..."
        ARCHIVE_URL="https://github.com/$GITHUB_REPO/archive/refs/heads/master.tar.gz"
        curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
            echo "❌ Download failed"
            rm -rf "$TMP_DIR"
            exit 1
        }
        tar -xzf strema.tar.gz
        SOURCE_DIR="strema-master"
    else
        echo "Downloading release $VERSION..."
        ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/strema-$VERSION.tar.gz"
        curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
            echo "❌ Download failed. Check if release $VERSION exists"
            rm -rf "$TMP_DIR"
            exit 1
        }
        tar -xzf strema.tar.gz
        SOURCE_DIR="strema"
    fi
    
    # Replace files
    rm -rf "$INSTALL_DIR"
    mkdir -p "$REAL_HOME"
    mv "$SOURCE_DIR" "$INSTALL_DIR"
    
    # Restore config
    if [ -n "$TMP_BACKUP" ] && [ -f "$TMP_BACKUP" ]; then
        cp "$TMP_BACKUP" "$INSTALL_DIR/config/stream.conf"
        rm -f "$TMP_BACKUP"
    fi
    
    cd "$REAL_HOME"
    rm -rf "$TMP_DIR"
    echo "✅ Download complete"
    
else
    # Remote installation - fresh install
    echo ""
    echo "🌐 Remote installation - fresh install"
    
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    if [ "$VERSION" = "latest" ]; then
        echo "Downloading latest from master..."
        ARCHIVE_URL="https://github.com/$GITHUB_REPO/archive/refs/heads/master.tar.gz"
        curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
            echo "❌ Download failed"
            rm -rf "$TMP_DIR"
            exit 1
        }
        tar -xzf strema.tar.gz
        SOURCE_DIR="strema-master"
    else
        echo "Downloading release $VERSION..."
        ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/strema-$VERSION.tar.gz"
        curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
            echo "❌ Download failed. Check if release $VERSION exists"
            rm -rf "$TMP_DIR"
            exit 1
        }
        tar -xzf strema.tar.gz
        SOURCE_DIR="strema"
    fi
    
    # Install files
    mkdir -p "$REAL_HOME"
    mv "$SOURCE_DIR" "$INSTALL_DIR"
    
    cd "$REAL_HOME"
    rm -rf "$TMP_DIR"
    echo "✅ Download complete"
fi

SCRIPT_DIR="$INSTALL_DIR"

# Install dependencies (requires sudo)
echo ""
echo "[2/5] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y ffmpeg strace python3-flask iproute2 jq

# Prepare project files
echo ""
echo "[3/5] Preparing project files..."
chmod +x "$SCRIPT_DIR/scripts/"*.sh
chmod +x "$SCRIPT_DIR/web/web_config.py"
mkdir -p "$SCRIPT_DIR/logs"

# Clean up old temporary files from previous versions (migration)
sudo rm -f /tmp/dzyga_* 2>/dev/null || true

echo "✅ Files ready"

# Install systemd services
echo ""
echo "[4/5] Installing systemd services..."
for file in "$SCRIPT_DIR/systemd"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    if grep -q "__INSTALL_DIR__" "$file"; then
        sudo sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$file" > "/tmp/$name"
        sudo mv "/tmp/$name" "/etc/systemd/system/$name"
    else
        sudo cp "$file" "/etc/systemd/system/$name"
    fi
done
sudo systemctl daemon-reload

# Start services
echo ""
echo "[5/5] Starting services..."

# Always start these services
sudo systemctl enable --now forpost-stream-web
sudo systemctl enable --now forpost-stream-config.path
sudo systemctl enable --now forpost-stream-watchdog.timer
sudo systemctl enable --now forpost-dzyga-monitor.timer

# Enable on boot only (don't start now)
sudo systemctl enable forpost-power-settings 2>/dev/null || true

# Disable by default (controlled via web UI)
sudo systemctl disable forpost-stream 2>/dev/null || true
sudo systemctl disable forpost-udp-proxy 2>/dev/null || true
sudo systemctl disable forpost-stream-autorestart.timer 2>/dev/null || true

# Restart stream if it was running before update
if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    echo "Restarting stream service..."
    sudo systemctl start forpost-stream
fi

echo "✅ Services configured"

# Show info
echo ""
echo "=========================================="
echo "[6/6] Installation complete!"
echo "=========================================="
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo "🌐 Web Interface: http://$IP_ADDRESS:8081"
echo ""
echo "Useful commands:"
echo "  sudo systemctl status forpost-stream-web"
echo "  sudo systemctl status forpost-stream"
echo "  tail -f $SCRIPT_DIR/logs/stream.log"
echo ""
