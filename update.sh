#!/bin/bash
# Quick update script - pulls latest code and restarts services

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Updating Forpost Stream"
echo "=========================================="
echo ""

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo "ERROR: Not a git repository"
    exit 1
fi

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Step 1: Pull latest changes
echo "[1/4] Pulling latest changes from git..."
sudo -u "${SUDO_USER:-$USER}" git pull
if [ $? -ne 0 ]; then
    echo "ERROR: git pull failed"
    exit 1
fi
echo "✓ Code updated"
echo ""

# Step 2: Run install script
echo "[2/4] Running install script..."
./install.sh
if [ $? -ne 0 ]; then
    echo "ERROR: install.sh failed"
    exit 1
fi
echo ""

# Step 3: Restart web interface
echo "[3/4] Restarting web interface..."
systemctl restart forpost-stream-web
if [ $? -eq 0 ]; then
    echo "✓ Web interface restarted"
else
    echo "⚠ Failed to restart web interface"
fi
echo ""

# Step 4: Restart stream services (if running)
echo "[4/4] Restarting stream services..."
STREAM_ACTIVE=$(systemctl is-active forpost-stream 2>/dev/null || echo "inactive")
UDP_ACTIVE=$(systemctl is-active forpost-udp-proxy 2>/dev/null || echo "inactive")

if [ "$STREAM_ACTIVE" = "active" ]; then
    echo "Restarting stream service..."
    systemctl restart forpost-stream
    echo "✓ Stream service restarted"
else
    echo "Stream service is not running (skipped)"
fi

if [ "$UDP_ACTIVE" = "active" ]; then
    echo "Restarting UDP proxy..."
    systemctl restart forpost-udp-proxy
    echo "✓ UDP proxy restarted"
else
    echo "UDP proxy is not running (skipped)"
fi

echo ""
echo "=========================================="
echo "Update complete!"
echo "=========================================="
echo ""

# Show current version
if [ -f "$SCRIPT_DIR/VERSION" ]; then
    VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
    echo "Current version: $VERSION"
fi

# Show web interface URL
IP_ADDRESS=$(hostname -I | awk '{print $1}')
echo "Web interface: http://$IP_ADDRESS:8081"
echo ""
