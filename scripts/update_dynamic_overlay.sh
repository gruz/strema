#!/bin/bash

# Dynamic overlay updater - monitors frequency changes and manages dynamic text
# Clears text when frequency changes by more than 10 MHz

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DYNAMIC_TEXT_FILE="/tmp/dzyga_dynamic_overlay.txt"
LAST_FREQ_FILE="/tmp/dzyga_last_freq_dynamic.txt"
SCANNING_STATE_FILE="/tmp/dzyga_scanning_state.txt"
FREQ_SCRIPT="$SCRIPT_DIR/get_frequency.sh"

FREQ_THRESHOLD=10
STABLE_TIME=5  # Frequency must be stable for 5 seconds to consider stopped

# Track when frequency last changed significantly
last_change_time=0

# Initialize files
touch "$DYNAMIC_TEXT_FILE"
chmod 666 "$DYNAMIC_TEXT_FILE"
echo "stable" | tee "$SCANNING_STATE_FILE" > /dev/null
chmod 666 "$SCANNING_STATE_FILE" 2>/dev/null || true

# Initialize last frequency file with current frequency to prevent clearing on startup
if [ ! -f "$LAST_FREQ_FILE" ] || [ ! -s "$LAST_FREQ_FILE" ]; then
    if [ "$EUID" -eq 0 ]; then
        init_freq=$("$FREQ_SCRIPT" 2>/dev/null)
    else
        init_freq=$(sudo bash "$FREQ_SCRIPT" 2>/dev/null)
    fi
    
    if [ $? -eq 0 ] && [ -n "$init_freq" ]; then
        echo "$init_freq" | tee "$LAST_FREQ_FILE" > /dev/null
        chmod 666 "$LAST_FREQ_FILE" 2>/dev/null || true
    fi
fi

# Main loop - check frequency every 2 seconds
while true; do
    sleep 2
    
    # Get current frequency
    # Ensure lock file has correct permissions
    if [ -f "/tmp/get_frequency.lock" ]; then
        chmod 666 /tmp/get_frequency.lock 2>/dev/null || true
    fi
    
    if [ "$EUID" -eq 0 ]; then
        current_freq=$("$FREQ_SCRIPT" 2>/dev/null)
        freq_result=$?
    else
        current_freq=$(sudo bash "$FREQ_SCRIPT" 2>/dev/null)
        freq_result=$?
    fi
    
    # Skip if frequency read failed - don't clear text on errors
    if [ $freq_result -ne 0 ] || [ -z "$current_freq" ] || ! [[ "$current_freq" =~ ^[0-9]+$ ]]; then
        continue
    fi
    
    # Read last frequency
    if [ -f "$LAST_FREQ_FILE" ] && [ -s "$LAST_FREQ_FILE" ]; then
        last_freq=$(cat "$LAST_FREQ_FILE")
        # Validate last_freq is a number
        if ! [[ "$last_freq" =~ ^[0-9]+$ ]]; then
            last_freq="$current_freq"
        fi
    else
        last_freq="$current_freq"
    fi
    
    # Calculate frequency difference
    freq_diff=$((current_freq > last_freq ? current_freq - last_freq : last_freq - current_freq))
    
    current_time=$(date +%s)
    
    # Check if frequency changed significantly
    if [ $freq_diff -gt $FREQ_THRESHOLD ]; then
        # Frequency changed - we are scanning
        last_change_time=$current_time
        echo "scanning" | tee "$SCANNING_STATE_FILE" > /dev/null
        chmod 666 "$SCANNING_STATE_FILE" 2>/dev/null || true
        
        # Clear dynamic text when scanning starts
        echo "" | tee "$DYNAMIC_TEXT_FILE" > /dev/null
        chmod 666 "$DYNAMIC_TEXT_FILE" 2>/dev/null || true
    else
        # Frequency stable - check if enough time passed to consider stopped
        time_since_change=$((current_time - last_change_time))
        
        if [ $time_since_change -ge $STABLE_TIME ]; then
            # Frequency has been stable for STABLE_TIME seconds
            echo "stable" | tee "$SCANNING_STATE_FILE" > /dev/null
            chmod 666 "$SCANNING_STATE_FILE" 2>/dev/null || true
        fi
    fi
    
    # Always update last frequency to current
    echo "$current_freq" | tee "$LAST_FREQ_FILE" > /dev/null
    chmod 666 "$LAST_FREQ_FILE" 2>/dev/null || true
done
