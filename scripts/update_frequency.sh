#!/bin/bash
# Updates frequency file for ffmpeg overlay
# Runs as a background process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FREQ_FILE="/tmp/dzyga_freq.txt"
GET_FREQ="$SCRIPT_DIR/get_frequency.sh"
UPDATE_INTERVAL=2  # seconds

# Remove old file and create new with correct permissions
rm -f "$FREQ_FILE"
echo "---" > "$FREQ_FILE"
chmod 666 "$FREQ_FILE"

while true; do
    freq=$("$GET_FREQ" 2>/dev/null)
    if [ -n "$freq" ] && [ "$freq" != "ERROR" ]; then
        echo "$freq" > "$FREQ_FILE"
    fi
    sleep "$UPDATE_INTERVAL"
done
