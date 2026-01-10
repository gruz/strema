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
source "$SCRIPT_DIR/scripts/service_manager.sh"
ACTIVE_SERVICES=$(get_active_services)
echo "Active services: ${ACTIVE_SERVICES:-none}"
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
if [ -n "$ACTIVE_SERVICES" ]; then
    restart_active_services $ACTIVE_SERVICES
    echo "✓ Services restarted"
else
    echo "No stream services were running (skipped)"
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
