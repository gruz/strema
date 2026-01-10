#!/bin/bash

# UDP Multicast Proxy - reads RTSP fast and streams via UDP
# FFmpeg will read from UDP instead of RTSP to avoid blocking the camera

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
LOG_FILE="$PROJECT_ROOT/logs/udp_proxy.log"
MAX_LOG_SIZE=10485760  # 10MB

if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
    rm -f "$LOG_FILE.old"
    mv "$LOG_FILE" "$LOG_FILE.old"
    tail -c 5242880 "$LOG_FILE.old" > "$LOG_FILE.old.tmp" 2>/dev/null && mv "$LOG_FILE.old.tmp" "$LOG_FILE.old"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Load default values first
DEFAULTS_FILE="$(dirname "$0")/../config/defaults.conf"
if [ -f "$DEFAULTS_FILE" ]; then
    source "$DEFAULTS_FILE"
fi

# Load configuration (overrides defaults)
source "$CONFIG_FILE"

UDP_PORT=${UDP_PROXY_PORT}

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

if ! command -v ffmpeg &> /dev/null; then
    log "ERROR: ffmpeg is not installed"
    exit 1
fi

SOURCE_RTSP_URL="rtsp://${FORPOST_IP}:${RTSP_PORT}/${VIDEO_DEVICE}"
UDP_OUTPUT="udp://127.0.0.1:${UDP_PORT}?pkt_size=1316"

log "=========================================="
log "Starting UDP Multicast Proxy"
log "=========================================="
log "Source RTSP: $SOURCE_RTSP_URL"
log "UDP output: udp://127.0.0.1:${UDP_PORT}"
log "=========================================="

RECONNECT_DELAY=5

while true; do
    log "Connecting to RTSP source..."
    
    # Read from RTSP and stream to UDP
    # -c:v copy = no re-encoding, minimal CPU
    # -f mpegts = MPEG-TS format for UDP streaming
    # -flush_packets 1 = immediate packet flushing for low latency
    ffmpeg -hide_banner -loglevel info \
        -rtsp_transport "$RTSP_TRANSPORT" \
        -fflags +genpts+nobuffer \
        -i "$SOURCE_RTSP_URL" \
        -c:v copy -an \
        -f mpegts \
        -flush_packets 1 \
        "$UDP_OUTPUT"
    
    log "Proxy disconnected. Reconnecting in ${RECONNECT_DELAY}s..."
    sleep $RECONNECT_DELAY
done
