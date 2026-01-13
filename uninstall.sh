#!/bin/bash
# Uninstall script for Forpost Stream service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Removing Forpost Stream services..."

# Stop and remove all forpost-* services
echo "Stopping services..."
systemctl stop 'forpost-*' 2>/dev/null || true

echo "Disabling services..."
systemctl disable 'forpost-*' 2>/dev/null || true

echo "Removing service files..."
rm -f /etc/systemd/system/forpost-*

systemctl daemon-reload

echo "✅ Forpost Stream services removed."
