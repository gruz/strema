#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="forpost-stream"
SERVICE_FILE="$SCRIPT_DIR/systemd/forpost-stream.service"
CONFIG_FILE="$SCRIPT_DIR/config/stream.conf"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/stream.conf.template"

echo "=========================================="
echo "Installing Forpost Stream"
echo "=========================================="

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Install dependencies
echo ""
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y ffmpeg strace python3-flask iproute2

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
    "$CONFIG_TEMPLATE"
    "$SERVICE_FILE"
    "$SCRIPT_DIR/web/web_config.py"
    "$SCRIPT_DIR/web/templates/index.html"
    "$SCRIPT_DIR/scripts/update_autorestart.sh"
    "$SCRIPT_DIR/systemd/forpost-stream-autorestart.timer"
    "$SCRIPT_DIR/systemd/forpost-stream-autorestart.service"
    "$SCRIPT_DIR/systemd/forpost-stream-watchdog.timer"
    "$SCRIPT_DIR/systemd/forpost-stream-watchdog.service"
)

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

echo "All files in place."

# Install systemd service
echo ""
echo "[4/7] Installing systemd services..."
# Replace __INSTALL_DIR__ placeholder with actual script directory
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/systemd/forpost-stream.service" > /etc/systemd/system/forpost-stream.service
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/systemd/forpost-stream-config.path" > /etc/systemd/system/forpost-stream-config.path
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/systemd/forpost-stream-web.service" > /etc/systemd/system/forpost-stream-web.service
sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$SCRIPT_DIR/systemd/forpost-stream-watchdog.service" > /etc/systemd/system/forpost-stream-watchdog.service
cp "$SCRIPT_DIR/systemd/forpost-stream-restart.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/forpost-stream-autorestart.timer" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/forpost-stream-autorestart.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/forpost-stream-watchdog.timer" /etc/systemd/system/
systemctl daemon-reload

# Enable and start services
echo ""
echo "[5/7] Enabling services..."
# Stream service is disabled by default - control via web interface
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
# Enable config watcher for automatic restart on config changes
systemctl enable forpost-stream-config.path
systemctl start forpost-stream-config.path
# Enable and start web interface
systemctl enable forpost-stream-web
systemctl start forpost-stream-web
# Enable watchdog timer
systemctl enable forpost-stream-watchdog.timer
systemctl start forpost-stream-watchdog.timer

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
