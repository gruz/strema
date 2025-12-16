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
echo "[1/5] Installing dependencies..."
apt-get update -qq
apt-get install -y ffmpeg strace

# Generate configuration
echo ""
echo "[2/5] Configuring..."

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
echo "[3/5] Checking files..."
REQUIRED_FILES=(
    "$SCRIPT_DIR/start_stream.sh"
    "$SCRIPT_DIR/get_frequency.sh"
    "$SCRIPT_DIR/update_frequency.sh"
    "$CONFIG_FILE"
    "$SERVICE_FILE"
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

echo "All files in place."

# Install systemd service
echo ""
echo "[4/5] Installing systemd service..."
cp "$SERVICE_FILE" /etc/systemd/system/
cp "$SCRIPT_DIR/forpost-stream-config.path" /etc/systemd/system/
cp "$SCRIPT_DIR/forpost-stream-restart.service" /etc/systemd/system/
systemctl daemon-reload

# Enable and start service
echo ""
echo "[5/5] Enabling service..."
systemctl enable "$SERVICE_NAME"
systemctl enable forpost-stream-config.path
systemctl start "$SERVICE_NAME"
systemctl start forpost-stream-config.path

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "Useful commands:"
echo "  Status:   sudo systemctl status $SERVICE_NAME"
echo "  Logs:     sudo journalctl -u $SERVICE_NAME -f"
echo "  Stop:     sudo systemctl stop $SERVICE_NAME"
echo "  Start:    sudo systemctl start $SERVICE_NAME"
echo "  Disable:  sudo systemctl disable $SERVICE_NAME"
echo ""
echo "Configuration: $SCRIPT_DIR/stream.conf"
echo ""
