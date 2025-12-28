#!/usr/bin/env bash
set -euo pipefail

# This script is a diagnostic probe for the local RTSP stream.
#
# What it does:
# - Connects to the RTSP URL using GStreamer (gst-launch-1.0) with low-latency settings.
# - Writes detailed GStreamer debug logs into a file so you can inspect what happens
#   during freezes (timeouts, RTP jitterbuffer issues, disconnects, etc.).
#
# Why it exists:
# - Some freezes happen only for RTSP viewers (GStreamer/VLC/clients) while ffmpeg->RTMP
#   keeps working. This probe helps reproduce/observe the RTSP side independent of the
#   Windows client.
#
# Usage:
# - Just run: ./gst_rtsp_probe.sh
# - It will read stream.conf (same as start_stream.sh) and auto-detect FORPOST_IP.
# - Logs are written to /tmp/gst_rtsp_probe.log
#
# Optional overrides (environment variables):
# - DURATION_SEC: run for N seconds (default 600)
# - GST_DEBUG: override debug categories/levels
# - RTSP_URL: fully override RTSP URL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/stream.conf"

DURATION_SEC="${DURATION_SEC:-600}"
LOG_FILE="/tmp/gst_rtsp_probe.log"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

FORPOST_IP=${FORPOST_IP:-auto}
RTSP_PORT=${RTSP_PORT:-8554}
VIDEO_DEVICE=${VIDEO_DEVICE:-devvideo0}

if [[ -z "${RTSP_URL:-}" ]]; then
  if [[ -z "$FORPOST_IP" || "$FORPOST_IP" == "auto" ]]; then
    FORPOST_IP=$(ip route get 1 | awk '{print $7; exit}')
  fi
  RTSP_URL="rtsp://${FORPOST_IP}:${RTSP_PORT}/${VIDEO_DEVICE}"
else
  RTSP_URL="$RTSP_URL"
fi

if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
  echo "Error: gst-launch-1.0 not found. Install gstreamer1.0-tools"
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

echo "RTSP probe"
echo "  url:      $RTSP_URL"
echo "  duration: ${DURATION_SEC}s"
echo "  log:      $LOG_FILE"

export GST_DEBUG_NO_COLOR=1
export GST_DEBUG="${GST_DEBUG:-2,rtsp*:6,rtspsrc:6,rtpjitterbuffer:6,rtp*:5,udpsrc:4,tcp*:4}"

PIPELINE=(
  rtspsrc
  "location=$RTSP_URL"
  protocols=tcp
  latency=0
  drop-on-latency=true
  do-rtsp-keep-alive=true
  timeout=5000000
  !
  rtph264depay
  !
  h264parse
  !
  fakesink
  sync=false
)

CMD=(gst-launch-1.0 -e -q "${PIPELINE[@]}")

CMD=(timeout "$DURATION_SEC" "${CMD[@]}")

echo "Running: ${CMD[*]}" | tee -a "$LOG_FILE"

echo "---" >>"$LOG_FILE"
"${CMD[@]}" >>"$LOG_FILE" 2>&1
RC=$?

echo "---" >>"$LOG_FILE"
echo "Exit code: $RC" | tee -a "$LOG_FILE"

if [[ $RC -eq 124 ]]; then
  exit 0
fi

exit $RC
