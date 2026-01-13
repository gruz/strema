#!/bin/bash
# Reads current frequency from DZYGA packets via strace
# Packet: 0xFF 0xAA + 2 bytes frequency
# Does not interrupt client operation

# Use flock to prevent parallel strace calls (only one strace can attach to process at a time)
LOCK_FILE="/tmp/get_frequency.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "ERROR: Another instance is running" >&2
    exit 1
fi

# Determine user home directory
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
else
    USER_HOME="$HOME"
fi

# Find dzyga process PID (not dzyga_web)
DZYGA_PID=$(pgrep -f "$USER_HOME/FORPOST/dzyga$" | tail -1)

if [ -z "$DZYGA_PID" ]; then
    echo "ERROR: dzyga process not found" >&2
    exit 1
fi

# Kill stale strace processes (older than 2 sec) - safety net for crashed instances
pkill -9 -f "strace.*-p $DZYGA_PID" --older 2 2>/dev/null

# Find fd for ttyACM0 dynamically
TTY_FD=$(ls -la /proc/$DZYGA_PID/fd/ 2>/dev/null | grep ttyACM | awk '{print $9}' | head -1)

if [ -z "$TTY_FD" ]; then
    echo "ERROR: ttyACM fd not found for dzyga process" >&2
    exit 1
fi

RESULT_FILE=$(mktemp)
trap "rm -f $RESULT_FILE" EXIT

# Convert strace escape sequence to hex byte
parse_byte() {
    local s="$1"
    case "$s" in
        \\x[0-9a-fA-F][0-9a-fA-F]) echo "${s:2:2}" ;;
        \\r) echo "0d" ;;
        \\n) echo "0a" ;;
        \\t) echo "09" ;;
        \\f) echo "0c" ;;
        \\v) echo "0b" ;;
        \\b) echo "08" ;;
        \\a) echo "07" ;;
        \\0) echo "00" ;;
        \\\\) echo "5c" ;;
        *) printf '%02x' "'$s" ;;
    esac
}

# Sniff via strace fd=4 (ttyACM0)
# Note: with -f flag, strace outputs [pid XXXX] prefix, so we need to match that
# Timeout must be less than update interval (2 sec) to avoid accumulating stale processes
timeout 1.5 strace -f -p "$DZYGA_PID" -e read -s 256 -x 2>&1 | \
grep -m1 -A2 "read($TTY_FD, \"\\\\xff\", 1)" | \
{
    read -r line1
    read -r line2
    read -r line3
    
    # Check if second read contains \xaa or \xab
    if echo "$line2" | grep -qE "read\($TTY_FD, \"\\\\x(aa|ab)\", 1\)"; then
        # Extract content between quotes: read(4, "...", 2)
        content=$(echo "$line3" | sed -n "s/.*read($TTY_FD, \"\(.*\)\", 2).*/\1/p")
        
        if [ -n "$content" ]; then
            # Parse bytes
            byte1=""
            byte2=""
            
            # First byte
            if [[ "$content" =~ ^\\x([0-9a-fA-F]{2}) ]]; then
                byte1="${BASH_REMATCH[1]}"
                content="${content:4}"
            elif [[ "$content" =~ ^\\([rntfvba0\\]) ]]; then
                byte1=$(parse_byte "\\${BASH_REMATCH[1]}")
                content="${content:2}"
            elif [ -n "$content" ]; then
                byte1=$(printf '%02x' "'${content:0:1}")
                content="${content:1}"
            fi
            
            # Second byte
            if [[ "$content" =~ ^\\x([0-9a-fA-F]{2}) ]]; then
                byte2="${BASH_REMATCH[1]}"
            elif [[ "$content" =~ ^\\([rntfvba0\\]) ]]; then
                byte2=$(parse_byte "\\${BASH_REMATCH[1]}")
            elif [ -n "$content" ]; then
                byte2=$(printf '%02x' "'${content:0:1}")
            fi
            
            if [ -n "$byte1" ] && [ -n "$byte2" ]; then
                freq_be=$((16#${byte1}${byte2}))
                echo "$freq_be" > "$RESULT_FILE"
            fi
        fi
    fi
}

if [ -s "$RESULT_FILE" ]; then
    cat "$RESULT_FILE"
    exit 0
fi

echo "ERROR: No frequency packet captured" >&2
exit 1
