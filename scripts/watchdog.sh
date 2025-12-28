#!/bin/bash
# Watchdog script to monitor streaming service health
# Checks for CLOSE-WAIT connections and restarts service if needed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$PROJECT_ROOT/logs/watchdog.log"
SERVICE_NAME="forpost-stream"
MAX_LOG_SIZE=10485760  # 10MB

# Rotate log if too large
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
    # Keep only last 10MB, remove old backup
    rm -f "$LOG_FILE.old"
    mv "$LOG_FILE" "$LOG_FILE.old"
    # Truncate old file to last 5MB to save space
    tail -c 5242880 "$LOG_FILE.old" > "$LOG_FILE.old.tmp" 2>/dev/null && mv "$LOG_FILE.old.tmp" "$LOG_FILE.old"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if service is enabled (should be running)
IS_ENABLED=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)
if [ "$IS_ENABLED" != "enabled" ]; then
    # Service is disabled - user stopped it intentionally, don't monitor
    exit 0
fi

# Check if service is active
IS_ACTIVE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
if [ "$IS_ACTIVE" != "active" ]; then
    log "WARNING: Service $SERVICE_NAME is enabled but not active (status: $IS_ACTIVE)"
    exit 0
fi

# Get ffmpeg PID from service
FFMPEG_PID=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)

if [ -z "$FFMPEG_PID" ] || [ "$FFMPEG_PID" = "0" ]; then
    log "WARNING: Service $SERVICE_NAME is running but no main PID found"
    exit 0
fi

# Find actual ffmpeg process (child of start_stream.sh)
ACTUAL_FFMPEG_PID=$(pgrep -P "$FFMPEG_PID" ffmpeg 2>/dev/null | head -1)

if [ -z "$ACTUAL_FFMPEG_PID" ]; then
    log "WARNING: ffmpeg process not found under PID $FFMPEG_PID"
    exit 0
fi

# Check for CLOSE-WAIT connections on RTMP ports (8443, 1935)
CLOSE_WAIT_COUNT=$(ss -tn 2>/dev/null | grep -E "CLOSE-WAIT.*:(8443|1935)" | wc -l)

if [ "$CLOSE_WAIT_COUNT" -gt 0 ]; then
    log "ERROR: Detected $CLOSE_WAIT_COUNT CLOSE-WAIT connection(s) on RTMP ports"
    log "Connection details:"
    ss -tn 2>/dev/null | grep -E "CLOSE-WAIT.*:(8443|1935)" | while read line; do
        log "  $line"
    done
    
    log "ACTION: Restarting $SERVICE_NAME service..."
    systemctl restart "$SERVICE_NAME"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS: Service restarted successfully"
    else
        log "ERROR: Failed to restart service"
        exit 1
    fi
else
    # Check if ffmpeg process is actually consuming CPU (should be encoding)
    CPU_USAGE=$(top -b -n 1 -p "$ACTUAL_FFMPEG_PID" 2>/dev/null | tail -1 | awk '{print $9}' | cut -d. -f1)
    
    if [ -n "$CPU_USAGE" ] && [ "$CPU_USAGE" -lt 1 ]; then
        log "WARNING: ffmpeg process (PID $ACTUAL_FFMPEG_PID) has low CPU usage ($CPU_USAGE%), may be stalled"
        
        # Check if process has been running for more than 5 minutes with low CPU
        PROCESS_AGE=$(ps -p "$ACTUAL_FFMPEG_PID" -o etimes= 2>/dev/null | tr -d ' ')
        if [ -n "$PROCESS_AGE" ] && [ "$PROCESS_AGE" -gt 300 ]; then
            log "ACTION: Process running for ${PROCESS_AGE}s with low CPU, restarting service..."
            systemctl restart "$SERVICE_NAME"
            
            if [ $? -eq 0 ]; then
                log "SUCCESS: Service restarted successfully"
            else
                log "ERROR: Failed to restart service"
                exit 1
            fi
        fi
    else
        log "OK: Service healthy (ffmpeg PID $ACTUAL_FFMPEG_PID, CPU ${CPU_USAGE}%)"
    fi
fi

exit 0
