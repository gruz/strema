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

# Auto-detect IP address if not set in config
if [ -z "$FORPOST_IP" ] || [ "$FORPOST_IP" = "auto" ]; then
    FORPOST_IP=$(ip route get 1 | awk '{print $7; exit}')
    log "Auto-detected IP: $FORPOST_IP"
fi

# Auto-detect RTSP transport using shared function
source "$SCRIPT_DIR/detect_rtsp_transport.sh"
RTSP_TRANSPORT=$(detect_rtsp_transport)
if [ "$RTSP_TRANSPORT" = "udp" ]; then
    log "Detected VLC RTSP server - using UDP transport"
else
    log "Detected custom RTSP server - using TCP transport"
fi

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    log "ERROR: ffmpeg is not installed"
    exit 1
fi

# Build RTSP URL
RTSP_URL="rtsp://${FORPOST_IP}:${RTSP_PORT}/${VIDEO_DEVICE}"

# UDP Proxy settings (if enabled, read from UDP instead of RTSP)
USE_UDP_PROXY=${USE_UDP_PROXY:-true}
UDP_PROXY_PORT=${UDP_PROXY_PORT:-5000}
if [ "$USE_UDP_PROXY" = "true" ]; then
    # Small buffer to prevent lag accumulation - old packets are dropped
    INPUT_URL="udp://127.0.0.1:${UDP_PROXY_PORT}?overrun_nonfatal=1&fifo_size=65536&buffer_size=131072&listen=0"
    log "UDP Proxy mode enabled - reading from UDP port ${UDP_PROXY_PORT}"
else
    INPUT_URL="$RTSP_URL"
fi

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
log "Stream mode: $STREAM_MODE"
log "=========================================="

# File for dynamic frequency
FREQ_FILE="/tmp/dzyga_freq.txt"
FREQ_UPDATER="$SCRIPT_DIR/update_frequency.sh"
SCAN_DETECTOR="$SCRIPT_DIR/detect_scan_state.sh"

# Function to check if we should stream based on scan state
# $1 - threshold: 1=fast/sensitive (for initial check), 2=tolerant (for monitoring)
should_stream() {
    local threshold=${1:-1}
    
    # In overlay mode, always stream (scanning indicator shown in overlay)
    # In always mode, always stream (ignore scanning)
    # In on-lock mode, only stream when locked
    if [ "$STREAM_MODE" != "on-lock" ]; then
        return 0
    fi
    
    if [ ! -x "$SCAN_DETECTOR" ]; then
        log "WARNING: Scan detector not found, streaming anyway"
        return 0
    fi
    
    "$SCAN_DETECTOR" 3 1.0 0 $threshold >/dev/null 2>&1
    local state=$?
    
    case $state in
        0)
            return 0
            ;;
        1)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

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

# Set default values
OVERLAY_FONTSIZE=${OVERLAY_FONTSIZE:-20}
OVERLAY_BG_OPACITY=${OVERLAY_BG_OPACITY:-0.5}
OVERLAY_TEXT_OPACITY=${OVERLAY_TEXT_OPACITY:-1.0}
VIDEO_CRF=${VIDEO_CRF:-30}
VIDEO_FPS=${VIDEO_FPS:-25}
OVERLAY_POSITION=${OVERLAY_POSITION:-top-left}
FREQUENCY_POSITION=${FREQUENCY_POSITION:-bottom-left}
STREAM_MODE=${STREAM_MODE:-always}

# Calculate GOP (keyframe interval) based on FPS
# GOP = FPS * 2 (keyframe every 2 seconds)
VIDEO_GOP=$((VIDEO_FPS * 2))

# Build video filter and encoding parameters
if [ -n "$OVERLAY_TEXT" ] || [ "$SHOW_FREQUENCY" = "true" ]; then
    
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
            # Export STREAM_MODE so update_frequency.sh can use it
            export STREAM_MODE
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
    log "Parameters: CRF=${VIDEO_CRF}, FPS=${VIDEO_FPS}, GOP=${VIDEO_GOP}, font size=${OVERLAY_FONTSIZE}"
    
    # Build video encoding options
    VIDEO_OPTS="-vf \"$VF_FILTER\" -r ${VIDEO_FPS} -c:v libx264 -preset ultrafast -tune zerolatency -bf 0 -crf ${VIDEO_CRF} -g ${VIDEO_GOP} -sc_threshold 0 -threads 2"
else
    log "Overlay disabled - using stream copy"
    
    # Build video copy options
    VIDEO_OPTS="-r ${VIDEO_FPS} -c:v copy"
fi

# Auto-reconnect loop (watchdog service handles service restarts)
RECONNECT_DELAY=2
CHECK_INTERVAL=5

while true; do
    # Initial check: fast detection (threshold=1) - any 1+ change = scanning
    if should_stream 1; then
        log "Connecting to stream..."
        
        # Build ffmpeg command based on source type
        if [ "$USE_UDP_PROXY" = "true" ]; then
            # UDP input - low latency configuration
            # -fflags nobuffer: disable input buffering
            # -flags low_delay: minimize encoding delay
            # -probesize: quick stream analysis
            INPUT_PARAMS="-fflags nobuffer -flags low_delay -probesize 32768 -analyzeduration 0 -i $INPUT_URL"
        else
            # RTSP input
            INPUT_PARAMS="-rtsp_transport $RTSP_TRANSPORT -i $RTSP_URL"
        fi
        
        # Build video encoding parameters and run in background
        if [ -n "$OVERLAY_TEXT" ] || [ "$SHOW_FREQUENCY" = "true" ]; then
            # With overlay - need to encode
            ffmpeg -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
                $INPUT_PARAMS \
                -vf "$VF_FILTER" \
                -c:v libx264 -preset ultrafast -tune zerolatency \
                -bf 0 -pix_fmt yuv420p \
                -crf ${VIDEO_CRF} -g ${VIDEO_GOP} \
                -an -f flv "$RTMP_URL" &
        else
            # No overlay - just copy
            ffmpeg -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
                $INPUT_PARAMS \
                -c:v copy -an -f flv "$RTMP_URL" &
        fi
        
        FFMPEG_PID=$!
        
        # Monitor ffmpeg and scan state
        # During streaming: tolerant detection (threshold=2) - 2 changes = scanning
        while kill -0 $FFMPEG_PID 2>/dev/null; do
            sleep $CHECK_INTERVAL
            
            if [ "$STREAM_MODE" = "on-lock" ]; then
                if ! should_stream 2; then
                    log "Scanner started scanning, stopping stream..."
                    kill $FFMPEG_PID 2>/dev/null
                    wait $FFMPEG_PID 2>/dev/null
                    break
                fi
            fi
        done
        
        wait $FFMPEG_PID 2>/dev/null
        log "Stream disconnected. Reconnecting in ${RECONNECT_DELAY}s..."
    else
        log "Scanner is scanning, waiting for lock... (checking again in ${RECONNECT_DELAY}s)"
    fi
    
    sleep $RECONNECT_DELAY
done
