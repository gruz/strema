#!/bin/bash
# Monitor dzyga.log for serial port connection issues
# If "No data > 2s" appears too frequently in recent logs, restart dzyga service

# Determine user home directory
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
else
    USER_HOME="$HOME"
fi

LOG_FILE="$USER_HOME/FORPOST/dzyga.log"
MONITOR_LOG="$USER_HOME/strema/logs/dzyga_monitor.log"
THRESHOLD=10
TIME_WINDOW=120

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$MONITOR_LOG"
}

if [ ! -f "$LOG_FILE" ]; then
    log "ERROR: dzyga.log not found at $LOG_FILE"
    exit 1
fi

DZYGA_PID=$(pgrep -f "$USER_HOME/FORPOST/dzyga$" | tail -1)
if [ -z "$DZYGA_PID" ]; then
    log "WARNING: dzyga process not running"
    exit 0
fi

CUTOFF_TIME=$(date -d "$TIME_WINDOW seconds ago" '+%Y-%m-%d %H:%M:%S')

RECENT_ERRORS=$(awk -v cutoff="$CUTOFF_TIME" '
    /No data > 2s, reconnecting serial port/ {
        if (match($0, /\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/)) {
            timestamp = substr($0, RSTART+1, RLENGTH-2)
            if (timestamp >= cutoff) {
                count++
            }
        }
    }
    END { print count+0 }
' "$LOG_FILE")

if [ "$RECENT_ERRORS" -ge "$THRESHOLD" ]; then
    log "=========================================="
    log "CRITICAL: Detected $RECENT_ERRORS serial port reconnections in last ${TIME_WINDOW}s"
    log "Threshold: $THRESHOLD - restarting dzyga service"
    log "=========================================="
    
    if sudo systemctl restart forpost-stream; then
        log "SUCCESS: forpost-stream service restarted"
    else
        log "ERROR: Failed to restart forpost-stream service"
        exit 1
    fi
else
    log "Status OK: $RECENT_ERRORS serial reconnections in last ${TIME_WINDOW}s (threshold: $THRESHOLD)"
fi

exit 0
