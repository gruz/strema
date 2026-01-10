#!/bin/bash
# Updates frequency file for ffmpeg overlay
# Runs as a background process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FREQ_FILE="/tmp/dzyga_freq.txt"
GET_FREQ="$SCRIPT_DIR/get_frequency.sh"
SCAN_DETECTOR="$SCRIPT_DIR/detect_scan_state.sh"
UPDATE_INTERVAL=2  # seconds

# Load default values first
DEFAULTS_FILE="$(dirname "$0")/../config/defaults.conf"
if [ -f "$DEFAULTS_FILE" ]; then
    source "$DEFAULTS_FILE"
fi

# Load configuration if exists (overrides defaults)
CONFIG_FILE="$SCRIPT_DIR/../config/stream.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Remove old file and create new with correct permissions
rm -f "$FREQ_FILE"
echo "---" > "$FREQ_FILE"
chmod 666 "$FREQ_FILE"

while true; do
    freq=$("$GET_FREQ" 2>/dev/null)
    
    # Check if we should show scanning indicator (only in overlay mode)
    if [ "$STREAM_MODE" = "overlay" ] && [ -x "$SCAN_DETECTOR" ]; then
        # Use threshold=2 for scanning detection (same as monitoring in on-lock mode)
        "$SCAN_DETECTOR" 3 1.0 0 2 >/dev/null 2>&1
        scan_state=$?
        
        if [ $scan_state -eq 1 ]; then
            # Scanning detected
            if [ -n "$freq" ] && [ "$freq" != "ERROR" ]; then
                echo "$freq СКАНУВАННЯ..." > "$FREQ_FILE"
            else
                echo "СКАНУВАННЯ..." > "$FREQ_FILE"
            fi
        else
            # Locked or unknown - show frequency normally
            if [ -n "$freq" ] && [ "$freq" != "ERROR" ]; then
                echo "$freq" > "$FREQ_FILE"
            fi
        fi
    else
        # Normal mode - just show frequency
        if [ -n "$freq" ] && [ "$freq" != "ERROR" ]; then
            echo "$freq" > "$FREQ_FILE"
        fi
    fi
    
    sleep "$UPDATE_INTERVAL"
done
