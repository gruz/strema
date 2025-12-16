#!/bin/bash
# Start the Forpost Stream service

SERVICE_NAME="forpost-stream"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Starting $SERVICE_NAME..."
systemctl start "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "$SERVICE_NAME started."
else
    echo "Failed to start $SERVICE_NAME"
    exit 1
fi
