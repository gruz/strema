#!/bin/bash
# Watchdog script to monitor streaming service health
# Checks for CLOSE-WAIT connections and restarts service if needed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$PROJECT_ROOT/logs/watchdog.log"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
SERVICE_NAME="forpost-stream"
MAX_LOG_SIZE=10485760  # 10MB

# Rotate log if too large
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
    rm -f "$LOG_FILE.old"
    mv "$LOG_FILE" "$LOG_FILE.old"
    tail -c 5242880 "$LOG_FILE.old" > "$LOG_FILE.old.tmp" 2>/dev/null && mv "$LOG_FILE.old.tmp" "$LOG_FILE.old"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

restart_service() {
    local service=$1
    log "ACTION: Restarting $service..."
    systemctl restart "$service"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS: $service restarted successfully"
        return 0
    else
        log "ERROR: Failed to restart $service"
        return 1
    fi
}

check_udp_proxy_enabled() {
    local use_proxy="true"
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        use_proxy=${USE_UDP_PROXY:-true}
    fi
    [ "$use_proxy" = "true" ]
}

# Exit early if service is disabled or not active
[ "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)" != "enabled" ] && exit 0

IS_ACTIVE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
if [ "$IS_ACTIVE" != "active" ]; then
    log "WARNING: Service $SERVICE_NAME is enabled but not active (status: $IS_ACTIVE)"
    exit 0
fi

# Get ffmpeg PID
FFMPEG_PID=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
if [ -z "$FFMPEG_PID" ] || [ "$FFMPEG_PID" = "0" ]; then
    log "WARNING: Service $SERVICE_NAME is running but no main PID found"
    exit 0
fi

ACTUAL_FFMPEG_PID=$(pgrep -P "$FFMPEG_PID" ffmpeg 2>/dev/null | head -1)
if [ -z "$ACTUAL_FFMPEG_PID" ]; then
    log "WARNING: ffmpeg process not found under PID $FFMPEG_PID"
    exit 0
fi

# Check for CLOSE-WAIT connections on RTMP ports
CLOSE_WAIT_COUNT=$(ss -tn 2>/dev/null | grep -E "CLOSE-WAIT.*:(8443|1935)" | wc -l)
if [ "$CLOSE_WAIT_COUNT" -gt 0 ]; then
    log "ERROR: Detected $CLOSE_WAIT_COUNT CLOSE-WAIT connection(s) on RTMP ports"
    ss -tn 2>/dev/null | grep -E "CLOSE-WAIT.*:(8443|1935)" | while read line; do
        log "  $line"
    done
    restart_service "$SERVICE_NAME" || exit 1
    exit 0
fi

# Get current state
UDP_PROXY_ACTIVE=$(systemctl is-active forpost-udp-proxy 2>/dev/null)
CPU_USAGE=$(top -b -n 1 -p "$ACTUAL_FFMPEG_PID" 2>/dev/null | tail -1 | awk '{print $9}' | cut -d. -f1)

# If CPU usage is normal, everything is healthy
if [ -z "$CPU_USAGE" ] || [ "$CPU_USAGE" -ge 1 ]; then
    log "OK: Service healthy (ffmpeg PID $ACTUAL_FFMPEG_PID, CPU ${CPU_USAGE}%, UDP proxy: $UDP_PROXY_ACTIVE)"
    exit 0
fi

# Low CPU detected - investigate why
if [ "$UDP_PROXY_ACTIVE" = "active" ]; then
    # UDP proxy running but low CPU = stalled ffmpeg
    log "WARNING: ffmpeg (PID $ACTUAL_FFMPEG_PID) has low CPU ($CPU_USAGE%) with active UDP proxy, may be stalled"
    
    PROCESS_AGE=$(ps -p "$ACTUAL_FFMPEG_PID" -o etimes= 2>/dev/null | tr -d ' ')
    if [ -n "$PROCESS_AGE" ] && [ "$PROCESS_AGE" -gt 60 ]; then
        log "ACTION: Process stalled for ${PROCESS_AGE}s, restarting..."
        restart_service "$SERVICE_NAME" || exit 1
    fi
else
    # UDP proxy not running - check if it should be
    if check_udp_proxy_enabled; then
        log "WARNING: UDP proxy should be running but is inactive"
        restart_service "forpost-udp-proxy" && {
            sleep 2
            restart_service "$SERVICE_NAME"
        }
    else
        log "INFO: Low CPU ($CPU_USAGE%) is normal - UDP proxy is disabled"
    fi
fi

exit 0
