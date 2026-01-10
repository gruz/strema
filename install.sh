#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service
#
# Usage:
#   Local install (from git clone):  sudo ./install.sh
#   Remote install (without git):    curl -fsSL https://raw.githubusercontent.com/gruz/strema/main/install.sh | sudo bash
#   Specific version:                curl -fsSL https://raw.githubusercontent.com/gruz/strema/main/install.sh | sudo bash -s v0.1.0

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
    
    # Determine version to install
    if [ "$REQUESTED_VERSION" = "latest" ]; then
        echo "Fetching latest stable release..."
        RELEASE_INFO=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest")
        VERSION=$(echo "$RELEASE_INFO" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    else
        VERSION="$REQUESTED_VERSION"
    fi
    
    if [ -z "$VERSION" ]; then
        echo "❌ Error: Could not determine version to install"
        exit 1
    fi
    
    echo "📦 Installing version: $VERSION"
    
    # Download release archive
    ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/strema-$VERSION.tar.gz"
    CHECKSUM_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/checksums.txt"
    
    echo "Downloading $ARCHIVE_URL..."
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    if ! curl -fsSL -o "strema-$VERSION.tar.gz" "$ARCHIVE_URL"; then
        echo "❌ Error: Failed to download release archive"
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
        echo "⚠️  Installation directory exists, backing up config..."
        if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
            cp "$INSTALL_DIR/config/stream.conf" "$TMP_DIR/stream.conf.backup"
        fi
        rm -rf "$INSTALL_DIR"
    fi
    
    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv strema "$INSTALL_DIR"
    
    # Restore config if backed up
    if [ -f "$TMP_DIR/stream.conf.backup" ]; then
        echo "Restoring configuration..."
        cp "$TMP_DIR/stream.conf.backup" "$INSTALL_DIR/config/stream.conf"
    fi
    
    # Cleanup
    cd /
    rm -rf "$TMP_DIR"
    
    SCRIPT_DIR="$INSTALL_DIR"
fi

SERVICE_NAME="forpost-stream"
SERVICE_FILE="$SCRIPT_DIR/systemd/forpost-stream.service"
CONFIG_FILE="$SCRIPT_DIR/config/stream.conf"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/stream.conf.template"

# Install dependencies
echo ""
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y ffmpeg strace python3-flask iproute2 jq

# Generate configuration
echo ""
echo "[2/7] Configuring..."

echo "Configuration will be created on first visit in the web UI."

# Check required files
echo ""
echo "[3/7] Checking files..."
REQUIRED_FILES=(
    "$SCRIPT_DIR/scripts/start_stream.sh"
    "$SCRIPT_DIR/scripts/get_frequency.sh"
    "$SCRIPT_DIR/scripts/update_frequency.sh"
    "$SCRIPT_DIR/scripts/watchdog.sh"
    "$SCRIPT_DIR/scripts/udp_proxy.sh"
    "$SCRIPT_DIR/scripts/service_manager.sh"
    "$CONFIG_TEMPLATE"
    "$SERVICE_FILE"
    "$SCRIPT_DIR/web/web_config.py"
    "$SCRIPT_DIR/web/templates/index.html"
    "$SCRIPT_DIR/scripts/update_autorestart.sh"
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

# Fix ownership of existing config file if it's owned by root
if [ -f "$CONFIG_FILE" ]; then
    FILE_OWNER=$(stat -c '%u' "$CONFIG_FILE")
    if [ "$FILE_OWNER" = "0" ]; then
        echo "Config file owned by root, changing to $ORIGINAL_USER..."
        chown "$ORIGINAL_UID:$ORIGINAL_GID" "$CONFIG_FILE"
    fi
fi

echo "All files in place."

# Install systemd service
echo ""
echo "[4/7] Installing systemd services..."
source "$SCRIPT_DIR/scripts/service_manager.sh"
install_all_services "$SCRIPT_DIR"

# Enable and start services
echo ""
echo "[5/7] Enabling services..."
enable_services
echo "Power settings service enabled (will apply on boot)"

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "[6/7] Getting network information..."
IP_ADDRESS=$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')
if [ -z "$IP_ADDRESS" ]; then
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
fi
ALL_IPS=$(hostname -I 2>/dev/null | xargs)
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
echo "  Stream:     sudo systemctl status $SERVICE_NAME"
echo "  Watchdog:   sudo systemctl status forpost-stream-watchdog.timer"
echo "  Logs:       sudo journalctl -u $SERVICE_NAME -f"
echo "  Stream log: tail -f $SCRIPT_DIR/logs/stream.log"
echo "  Watchdog:   tail -f $SCRIPT_DIR/logs/watchdog.log"
echo ""
echo "[7/7] Watchdog enabled - monitors stream health every 2 minutes"
echo "Configuration will be created in the web UI: $SCRIPT_DIR/config/stream.conf"
echo ""
