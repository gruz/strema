#!/bin/bash
# Updates auto-restart timer based on configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/stream.conf"
TIMER_FILE="/etc/systemd/system/forpost-stream-autorestart.timer"

# Source configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Default values
AUTO_RESTART_ENABLED=${AUTO_RESTART_ENABLED:-false}
AUTO_RESTART_INTERVAL=${AUTO_RESTART_INTERVAL:-2}

# Update timer file with new interval
cat > "$TIMER_FILE" << EOF
[Unit]
Description=FORPOST Stream Auto-Restart Timer
Requires=forpost-stream.service

[Timer]
OnUnitActiveSec=${AUTO_RESTART_INTERVAL}h
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# Enable or disable timer based on configuration
if [ "$AUTO_RESTART_ENABLED" = "true" ]; then
    # Check if stream service is running before enabling timer
    if systemctl is-active --quiet forpost-stream; then
        systemctl enable forpost-stream-autorestart.timer
        systemctl restart forpost-stream-autorestart.timer
        echo "Auto-restart enabled (every ${AUTO_RESTART_INTERVAL}h)"
    else
        # Only enable, don't start timer if stream is not running
        systemctl enable forpost-stream-autorestart.timer
        systemctl stop forpost-stream-autorestart.timer 2>/dev/null || true
        echo "Auto-restart enabled but not started (stream is not running)"
    fi
else
    systemctl stop forpost-stream-autorestart.timer 2>/dev/null || true
    systemctl disable forpost-stream-autorestart.timer 2>/dev/null || true
    echo "Auto-restart disabled"
fi
