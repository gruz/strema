#!/bin/bash
# Uninstall script for Forpost Stream service

SERVICE_NAME="forpost-stream"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Removing service $SERVICE_NAME..."

# Stop and disable services
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl stop forpost-stream-config.path 2>/dev/null || true
systemctl stop forpost-stream-web 2>/dev/null || true
systemctl stop forpost-stream-autorestart.timer 2>/dev/null || true
systemctl stop forpost-stream-watchdog.timer 2>/dev/null || true
systemctl stop forpost-stream-cleanup.timer 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
systemctl disable forpost-stream-config.path 2>/dev/null || true
systemctl disable forpost-stream-web 2>/dev/null || true
systemctl disable forpost-stream-autorestart.timer 2>/dev/null || true
systemctl disable forpost-stream-watchdog.timer 2>/dev/null || true
systemctl disable forpost-stream-cleanup.timer 2>/dev/null || true

# Remove service files
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
rm -f "/etc/systemd/system/forpost-stream-config.path"
rm -f "/etc/systemd/system/forpost-stream-restart.service"
rm -f "/etc/systemd/system/forpost-stream-web.service"
rm -f "/etc/systemd/system/forpost-stream-autorestart.timer"
rm -f "/etc/systemd/system/forpost-stream-autorestart.service"
rm -f "/etc/systemd/system/forpost-stream-watchdog.timer"
rm -f "/etc/systemd/system/forpost-stream-watchdog.service"
rm -f "/etc/systemd/system/forpost-stream-cleanup.timer"
rm -f "/etc/systemd/system/forpost-stream-cleanup.service"
systemctl daemon-reload

echo "Service $SERVICE_NAME removed."
