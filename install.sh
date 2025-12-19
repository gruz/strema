#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="forpost-stream"
SERVICE_FILE="$SCRIPT_DIR/forpost-stream.service"
CONFIG_FILE="$SCRIPT_DIR/stream.conf"
CONFIG_TEMPLATE="$SCRIPT_DIR/stream.conf.template"

echo "=========================================="
echo "Installing Forpost Stream"
echo "=========================================="

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Install dependencies
echo ""
echo "[1/6] Installing dependencies..."
apt-get update -qq
apt-get install -y ffmpeg strace python3-flask

# Generate configuration
echo ""
echo "[2/6] Configuring..."

if [ -f "$CONFIG_FILE" ]; then
    echo "Configuration file already exists: $CONFIG_FILE"
    read -p "Overwrite? (y/N): " overwrite
    if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
        echo "Using existing config."
    else
        rm -f "$CONFIG_FILE"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo ""
    echo "Creating new configuration file..."
    echo ""
    
    # RTMP URL
    read -p "RTMP URL (e.g. rtmps://server:port/app/key): " rtmp_url
    if [ -z "$rtmp_url" ]; then
        echo "Error: RTMP URL is required"
        exit 1
    fi
    
    # Overlay text
    read -p "Overlay text (leave empty to disable): " overlay_text
    
    # Generate config from template
    if [ ! -f "$CONFIG_TEMPLATE" ]; then
        echo "Error: Configuration template not found: $CONFIG_TEMPLATE"
        exit 1
    fi
    
    cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
    sed -i "s|__RTMP_URL__|$rtmp_url|g" "$CONFIG_FILE"
    sed -i "s|__OVERLAY_TEXT__|$overlay_text|g" "$CONFIG_FILE"
    
    # Make config accessible to user
    chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} "$CONFIG_FILE"
    
    echo "Configuration created: $CONFIG_FILE"
fi

# Check required files
echo ""
echo "[3/6] Checking files..."
REQUIRED_FILES=(
    "$SCRIPT_DIR/start_stream.sh"
    "$SCRIPT_DIR/get_frequency.sh"
    "$SCRIPT_DIR/update_frequency.sh"
    "$CONFIG_FILE"
    "$SERVICE_FILE"
    "$SCRIPT_DIR/web_config.py"
    "$SCRIPT_DIR/templates/index.html"
    "$SCRIPT_DIR/update_autorestart.sh"
    "$SCRIPT_DIR/forpost-stream-autorestart.timer"
    "$SCRIPT_DIR/forpost-stream-autorestart.service"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "Error: File not found: $file"
        exit 1
    fi
done

# Set execute permissions
chmod +x "$SCRIPT_DIR/start_stream.sh"
chmod +x "$SCRIPT_DIR/get_frequency.sh"
chmod +x "$SCRIPT_DIR/update_frequency.sh"
chmod +x "$SCRIPT_DIR/web_config.py"
chmod +x "$SCRIPT_DIR/update_autorestart.sh"

echo "All files in place."

# Install systemd service
echo ""
echo "[4/6] Installing systemd services..."
# Replace __INSTALL_DIR__ placeholder with actual script directory
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SERVICE_FILE" > /etc/systemd/system/forpost-stream.service
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/forpost-stream-config.path" > /etc/systemd/system/forpost-stream-config.path
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/forpost-stream-web.service" > /etc/systemd/system/forpost-stream-web.service
cp "$SCRIPT_DIR/forpost-stream-restart.service" /etc/systemd/system/
cp "$SCRIPT_DIR/forpost-stream-autorestart.timer" /etc/systemd/system/
cp "$SCRIPT_DIR/forpost-stream-autorestart.service" /etc/systemd/system/
systemctl daemon-reload

# Enable and start services
echo ""
echo "[5/6] Enabling services..."
# Stream service is disabled by default - control via web interface
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
# Config watcher is disabled by default
systemctl disable forpost-stream-config.path 2>/dev/null || true
systemctl stop forpost-stream-config.path 2>/dev/null || true
# Only web interface is enabled and started
systemctl enable forpost-stream-web
systemctl start forpost-stream-web

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "[6/6] Getting network information..."
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo ""
echo "🌐 Web Interface: http://$IP_ADDRESS:8081"
echo ""
echo "⚠️  Stream service is DISABLED by default."
echo "   Use the web interface to start/stop/configure streaming."
echo ""
echo "Useful commands:"
echo "  Web UI:   sudo systemctl status forpost-stream-web"
echo "  Stream:   sudo systemctl status $SERVICE_NAME"
echo "  Logs:     sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "Configuration: $SCRIPT_DIR/stream.conf"
echo ""
