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

# Step 1: Pull latest changes
echo "[1/5] Pulling latest changes from git..."
git pull
if [ $? -ne 0 ]; then
    echo "ERROR: git pull failed"
    exit 1
fi
echo "✓ Code updated"
echo ""

# Step 2: Check service status BEFORE install
echo "[2/5] Checking service status..."
STREAM_WAS_ACTIVE=$(sudo systemctl is-active forpost-stream 2>/dev/null || echo "inactive")
UDP_WAS_ACTIVE=$(sudo systemctl is-active forpost-udp-proxy 2>/dev/null || echo "inactive")
echo "Stream: $STREAM_WAS_ACTIVE, UDP Proxy: $UDP_WAS_ACTIVE"
echo ""

# Step 3: Run install script
echo "[3/5] Running install script..."
sudo ./install.sh 2>&1 | grep -v "^\[" || true
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: install.sh failed"
    exit 1
fi
echo "✓ Installation completed"
echo ""

# Step 4: Restart web interface
echo "[4/5] Restarting web interface..."
sudo systemctl restart forpost-stream-web
if [ $? -eq 0 ]; then
    echo "✓ Web interface restarted"
else
    echo "⚠ Failed to restart web interface"
fi
echo ""

# Step 5: Restart stream services (if they were running before)
echo "[5/5] Restarting stream services..."
STREAM_ACTIVE="$STREAM_WAS_ACTIVE"
UDP_ACTIVE="$UDP_WAS_ACTIVE"

if [ "$STREAM_ACTIVE" = "active" ]; then
    echo "Restarting stream service..."
    sudo systemctl restart forpost-stream
    echo "✓ Stream service restarted"
else
    echo "Stream service is not running (skipped)"
fi

if [ "$UDP_ACTIVE" = "active" ]; then
    echo "Restarting UDP proxy..."
    sudo systemctl restart forpost-udp-proxy
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
