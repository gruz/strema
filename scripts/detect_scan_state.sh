#!/bin/bash
# Detects if DZYGA scanner is scanning or locked on frequency
# Returns: 0 if LOCKED, 1 if SCANNING, 2 if UNKNOWN

SAMPLES=${1:-5}
SAMPLE_DELAY=${2:-1.5}
DEBUG=${3:-0}

FREQ_SCRIPT="$(dirname "$0")/get_frequency.sh"

if [ ! -x "$FREQ_SCRIPT" ]; then
    [ "$DEBUG" = "1" ] && echo "ERROR: Frequency script not executable" >&2
    exit 2
fi

frequencies=()

for i in $(seq 1 $SAMPLES); do
    if [ "$EUID" -eq 0 ]; then
        freq=$("$FREQ_SCRIPT" 2>&1)
        ret=$?
    else
        freq=$(sudo "$FREQ_SCRIPT" 2>&1)
        ret=$?
    fi
    
    if [ $ret -ne 0 ] || [ -z "$freq" ]; then
        [ "$DEBUG" = "1" ] && echo "ERROR: Failed to get frequency (sample $i): ret=$ret, freq='$freq'" >&2
        exit 2
    fi
    
    [ "$DEBUG" = "1" ] && echo "Sample $i: $freq" >&2
    frequencies+=("$freq")
    [ $i -lt $SAMPLES ] && sleep $SAMPLE_DELAY
done

changes=0
for i in $(seq 1 $((${#frequencies[@]} - 1))); do
    if [ "${frequencies[$i]}" != "${frequencies[$((i-1))]}" ]; then
        ((changes++))
    fi
done

[ "$DEBUG" = "1" ] && echo "Changes detected: $changes out of $((${#frequencies[@]} - 1)) transitions" >&2

THRESHOLD=${4:-2}

if [ $changes -ge $THRESHOLD ]; then
    [ "$DEBUG" = "1" ] && echo "SCANNING (changes=$changes >= threshold=$THRESHOLD)" >&2
    exit 1
fi

[ "$DEBUG" = "1" ] && echo "LOCKED (changes=$changes < threshold=$THRESHOLD)" >&2
exit 0
