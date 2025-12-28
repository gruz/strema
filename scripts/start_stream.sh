#!/bin/bash

# Script for starting video stream from Forpost

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
LOG_FILE="$PROJECT_ROOT/logs/stream.log"
MAX_LOG_SIZE=10485760  # 10MB

# Rotate log if too large
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
    # Keep only last 10MB, remove old backup
    rm -f "$LOG_FILE.old"
    mv "$LOG_FILE" "$LOG_FILE.old"
    # Truncate old file to last 5MB to save space
    tail -c 5242880 "$LOG_FILE.old" > "$LOG_FILE.old.tmp" 2>/dev/null && mv "$LOG_FILE.old.tmp" "$LOG_FILE.old"
fi

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check for configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Load configuration
source "$CONFIG_FILE"

# FFmpeg logging level (quiet, panic, fatal, error, warning, info, verbose, debug, trace)
FFMPEG_LOGLEVEL=${FFMPEG_LOGLEVEL:-info}

RTSP_TRANSPORT=${RTSP_TRANSPORT:-tcp}

# Auto-detect IP address if not set in config
if [ -z "$FORPOST_IP" ] || [ "$FORPOST_IP" = "auto" ]; then
    FORPOST_IP=$(ip route get 1 | awk '{print $7; exit}')
    log "Auto-detected IP: $FORPOST_IP"
fi

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    log "ERROR: ffmpeg is not installed"
    exit 1
fi

# Build RTSP URL
RTSP_URL="rtsp://${FORPOST_IP}:${RTSP_PORT}/${VIDEO_DEVICE}"

# Validate required settings
if [ -z "${RTMP_URL}" ] || [[ "${RTMP_URL}" == *"__RTMP_URL__"* ]]; then
    log "ERROR: RTMP_URL is not configured. Open the web interface and set RTMP URL, then restart the service."
    exit 1
fi

log "=========================================="
log "Starting video stream"
log "=========================================="
log "RTSP source: $RTSP_URL"
log "RTMP: ${RTMP_URL%/*}/***"
log "=========================================="

# File for dynamic frequency
FREQ_FILE="/tmp/dzyga_freq.txt"
FREQ_UPDATER="$SCRIPT_DIR/update_frequency.sh"

# Function to calculate position coordinates
get_position_coords() {
    local position=$1
    local x_coord="10"
    local y_coord="10"
    
    case "$position" in
        "top-left")
            x_coord="10"
            y_coord="10"
            ;;
        "top-right")
            x_coord="(w-text_w-10)"
            y_coord="10"
            ;;
        "bottom-left")
            x_coord="10"
            y_coord="(h-text_h-10)"
            ;;
        "bottom-right")
            x_coord="(w-text_w-10)"
            y_coord="(h-text_h-10)"
            ;;
        *)
            x_coord="10"
            y_coord="10"
            ;;
    esac
    
    echo "${x_coord}:${y_coord}"
}

# Build video filter and encoding parameters
if [ -n "$OVERLAY_TEXT" ] || [ "$SHOW_FREQUENCY" = "true" ]; then
    
    # Set default values
    OVERLAY_FONTSIZE=${OVERLAY_FONTSIZE:-20}
    OVERLAY_BG_OPACITY=${OVERLAY_BG_OPACITY:-0.5}
    OVERLAY_TEXT_OPACITY=${OVERLAY_TEXT_OPACITY:-1.0}
    VIDEO_CRF=${VIDEO_CRF:-30}
    OVERLAY_POSITION=${OVERLAY_POSITION:-top-left}
    FREQUENCY_POSITION=${FREQUENCY_POSITION:-bottom-left}
    
    # Build filter
    VF_FILTER=""
    
    # Static overlay text
    if [ -n "$OVERLAY_TEXT" ]; then
        log "Overlay text: $OVERLAY_TEXT (position: $OVERLAY_POSITION)"
        OVERLAY_COORDS=$(get_position_coords "$OVERLAY_POSITION")
        VF_FILTER="drawtext=text='${OVERLAY_TEXT}':fontsize=${OVERLAY_FONTSIZE}:fontcolor=white@${OVERLAY_TEXT_OPACITY}:box=1:boxcolor=black@${OVERLAY_BG_OPACITY}:boxborderw=5:x=${OVERLAY_COORDS%:*}:y=${OVERLAY_COORDS#*:}"
    fi
    
    # Dynamic frequency
    if [ "$SHOW_FREQUENCY" = "true" ]; then
        log "Frequency: enabled (updates every 2 sec, position: $FREQUENCY_POSITION)"
        
        # Start frequency updater in background
        if [ -x "$FREQ_UPDATER" ]; then
            rm -f "$FREQ_FILE"
            echo "---" > "$FREQ_FILE"
            chmod 666 "$FREQ_FILE"
            "$FREQ_UPDATER" &
            FREQ_PID=$!
            trap "kill $FREQ_PID 2>/dev/null" EXIT
            log "Started frequency updater (PID: $FREQ_PID)"
        else
            log "WARNING: Frequency update script not found: $FREQ_UPDATER"
        fi
        
        # Add frequency filter
        FREQ_COORDS=$(get_position_coords "$FREQUENCY_POSITION")
        FREQ_FILTER="drawtext=textfile='${FREQ_FILE}':reload=1:fontsize=${OVERLAY_FONTSIZE}:fontcolor=yellow@${OVERLAY_TEXT_OPACITY}:box=1:boxcolor=black@${OVERLAY_BG_OPACITY}:boxborderw=5:x=${FREQ_COORDS%:*}:y=${FREQ_COORDS#*:}"
        
        if [ -n "$VF_FILTER" ]; then
            VF_FILTER="${VF_FILTER},${FREQ_FILTER}"
        else
            VF_FILTER="$FREQ_FILTER"
        fi
    fi
    
    log "Using optimized software encoding (libx264)"
    log "Parameters: CRF=${VIDEO_CRF}, font size=${OVERLAY_FONTSIZE}"
    
    # Auto-reconnect loop (watchdog service handles service restarts)
    RECONNECT_DELAY=5
    
    while true; do
        log "Connecting to stream..."
        
        ffmpeg -hide_banner -loglevel "$FFMPEG_LOGLEVEL" -stats -stats_period 5 \
            -rtsp_transport "$RTSP_TRANSPORT" \
            -fflags +genpts -thread_queue_size 512 \
            -i "$RTSP_URL" \
            -vf "$VF_FILTER" \
            -c:v libx264 -preset ultrafast -tune zerolatency -crf ${VIDEO_CRF} -g 60 -sc_threshold 0 -threads 2 \
            -an \
            -max_muxing_queue_size 512 \
            -f flv \
            "$RTMP_URL"
        
        log "Stream disconnected. Reconnecting in ${RECONNECT_DELAY}s..."
        sleep $RECONNECT_DELAY
    done
else
    log "Overlay disabled - using stream copy"
    
    # Auto-reconnect loop (watchdog service handles service restarts)
    RECONNECT_DELAY=5
    
    while true; do
        log "Connecting to stream..."
        
        ffmpeg -hide_banner -loglevel "$FFMPEG_LOGLEVEL" -stats -stats_period 5 \
            -rtsp_transport "$RTSP_TRANSPORT" \
            -fflags +genpts -thread_queue_size 512 \
            -i "$RTSP_URL" \
            -c:v copy \
            -an \
            -max_muxing_queue_size 512 \
            -f flv \
            "$RTMP_URL"
        
        log "Stream disconnected. Reconnecting in ${RECONNECT_DELAY}s..."
        sleep $RECONNECT_DELAY
    done
fi
