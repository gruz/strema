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

# Always work as current user
INSTALL_DIR="$HOME/strema"

# Check if user has sudo access
if ! sudo -n true 2>/dev/null; then
    echo "❌ Error: This script requires sudo access"
    echo "   Please ensure your user has sudo privileges"
    exit 1
fi

# Detect installation type
if [ -f "$(dirname "${BASH_SOURCE[0]}")/scripts/start_stream.sh" ]; then
    echo "📁 Local installation"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IS_UPDATE=false
else
    echo "🌐 Remote installation"
    
    # Backup config if exists
    if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
        echo "⚠️  Updating existing installation"
        IS_UPDATE=true
        TMP_BACKUP="/tmp/strema_config_backup_$$"
        cp "$INSTALL_DIR/config/stream.conf" "$TMP_BACKUP"
    else
        echo "📦 Fresh installation"
        IS_UPDATE=false
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
    
    # Install files
    rm -rf "$INSTALL_DIR"
    mkdir -p "$HOME"
    mv "$SOURCE_DIR" "$INSTALL_DIR"
    
    # Restore config
    if [ -n "$TMP_BACKUP" ] && [ -f "$TMP_BACKUP" ]; then
        cp "$TMP_BACKUP" "$INSTALL_DIR/config/stream.conf"
        rm -f "$TMP_BACKUP"
    fi
    
    cd "$HOME"
    rm -rf "$TMP_DIR"
    SCRIPT_DIR="$INSTALL_DIR"
fi

# Install dependencies (requires sudo)
echo ""
echo "[1/5] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y ffmpeg strace python3-flask iproute2 jq

# Prepare project files
echo ""
echo "[2/5] Preparing project files..."
cp "$SCRIPT_DIR/scripts/service_manager.sh.template" "$SCRIPT_DIR/scripts/service_manager.sh"
chmod +x "$SCRIPT_DIR/scripts/"*.sh
chmod +x "$SCRIPT_DIR/web/web_config.py"
mkdir -p "$SCRIPT_DIR/logs"
echo "✅ Files ready"

# Install systemd services (requires sudo)
echo ""
echo "[3/5] Installing systemd services..."
source "$SCRIPT_DIR/scripts/service_manager.sh"
sudo bash -c "$(declare -f cleanup_old_services); cleanup_old_services '$SCRIPT_DIR'"
sudo bash -c "$(declare -f install_all_services); install_all_services '$SCRIPT_DIR'"

# Start/restart services
echo ""
echo "[4/5] Configuring services..."
if [ "$IS_UPDATE" = "true" ]; then
    echo "Restarting web service..."
    sudo systemctl restart forpost-stream-web 2>/dev/null || sudo systemctl start forpost-stream-web
    
    if [ -f "$SCRIPT_DIR/scripts/handle_config_change.sh" ]; then
        sudo rm -f /tmp/forpost_config_snapshot.conf
        bash "$SCRIPT_DIR/scripts/handle_config_change.sh"
    fi
    echo "✅ Services updated"
else
    sudo bash -c "$(declare -f enable_services); enable_services"
    echo "✅ Services started"
fi

# Show info
echo ""
echo "[5/5] Installation complete!"
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
