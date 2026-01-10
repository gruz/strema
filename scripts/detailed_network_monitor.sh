#!/bin/bash

# Detailed Network Monitor - correlates ffmpeg behavior with network issues
# Logs TCP window, bandwidth, and retransmissions to find root cause

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
DETAIL_LOG="$PROJECT_ROOT/logs/network_detail.log"
MAX_LOG_SIZE=10485760  # 10MB

# Load configuration
# Load default values first
DEFAULTS_FILE="$(dirname "$0")/../config/defaults.conf"
if [ -f "$DEFAULTS_FILE" ]; then
    source "$DEFAULTS_FILE"
fi

# Load configuration (overrides defaults)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Auto-detect IP if needed
if [ -z "$FORPOST_IP" ] || [ "$FORPOST_IP" = "auto" ]; then
    FORPOST_IP=$(ip route get 1 | awk '{print $7; exit}')
fi

rotate_log() {
    if [ -f "$DETAIL_LOG" ] && [ $(stat -c%s "$DETAIL_LOG" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
        tail -c 5242880 "$DETAIL_LOG" > "$DETAIL_LOG.tmp" && mv "$DETAIL_LOG.tmp" "$DETAIL_LOG"
    fi
}

log_event() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%3N')] $1" >> "$DETAIL_LOG"
}

# Get ffmpeg PID
get_ffmpeg_pid() {
    pgrep -f "ffmpeg.*rtsp.*${FORPOST_IP}" | head -1
}

# Get TCP window size for ffmpeg connection
get_tcp_window() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    
    # Find ffmpeg's TCP connection to RTSP server
    local conn=$(ss -tnp 2>/dev/null | grep "pid=$pid" | grep ":${RTSP_PORT}")
    if [ -z "$conn" ]; then
        echo "0"
        return
    fi
    
    # Extract receive window size
    echo "$conn" | awk '{for(i=1;i<=NF;i++){if($i~/rwnd:/){split($i,a,":");print a[2];exit}}}' | tr -d ','
}

# Get bandwidth usage on RTSP port
get_bandwidth() {
    # Sample network traffic for 1 second
    local before=$(cat /proc/net/dev | grep -E "eth0|wlan0|enp" | head -1 | awk '{print $2}')
    sleep 1
    local after=$(cat /proc/net/dev | grep -E "eth0|wlan0|enp" | head -1 | awk '{print $2}')
    echo $((after - before))
}

# Check if ffmpeg is actively reading (CPU > 0)
check_ffmpeg_active() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "NO_PROCESS"
        return
    fi
    
    local cpu=$(ps -p $pid -o %cpu= 2>/dev/null | tr -d ' ')
    if [ -z "$cpu" ]; then
        echo "NO_PROCESS"
    elif [ $(echo "$cpu > 0.5" | bc -l 2>/dev/null || echo 0) -eq 1 ]; then
        echo "ACTIVE"
    else
        echo "IDLE"
    fi
}

log_event "=== Detailed Network Monitor Started ==="
log_event "Monitoring RTSP: ${FORPOST_IP}:${RTSP_PORT}"

PREV_RETRANS=0
CHECK_INTERVAL=2

while true; do
    rotate_log
    
    FFMPEG_PID=$(get_ffmpeg_pid)
    CURR_RETRANS=$(netstat -s 2>/dev/null | grep "segments retransmitted" | awk '{print $1}')
    
    if [ "$PREV_RETRANS" -gt 0 ]; then
        RETRANS_DELTA=$((CURR_RETRANS - PREV_RETRANS))
        
        # Log detailed info when retransmissions occur
        if [ "$RETRANS_DELTA" -gt 0 ]; then
            TCP_WINDOW=$(get_tcp_window "$FFMPEG_PID")
            FFMPEG_STATE=$(check_ffmpeg_active "$FFMPEG_PID")
            CONN_COUNT=$(netstat -tn 2>/dev/null | grep ":${RTSP_PORT}" | grep ESTABLISHED | wc -l)
            
            log_event "RETRANS: +${RETRANS_DELTA} | Connections: ${CONN_COUNT} | FFmpeg: ${FFMPEG_STATE} | TCP Window: ${TCP_WINDOW} bytes | PID: ${FFMPEG_PID:-NONE}"
            
            # If significant retransmissions, log TCP state
            if [ "$RETRANS_DELTA" -gt 5 ]; then
                ss -tnp 2>/dev/null | grep ":${RTSP_PORT}" | grep "pid=$FFMPEG_PID" >> "$DETAIL_LOG" 2>&1
            fi
        fi
    fi
    
    PREV_RETRANS=$CURR_RETRANS
    sleep $CHECK_INTERVAL
done
