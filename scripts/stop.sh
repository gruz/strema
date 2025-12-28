#!/bin/bash
# Stop the Forpost Stream service

SERVICE_NAME="forpost-stream"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Stopping $SERVICE_NAME..."
systemctl stop "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Failed to stop $SERVICE_NAME"
    exit 1
else
    echo "$SERVICE_NAME stopped."
fi
