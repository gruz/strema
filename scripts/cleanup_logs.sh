#!/bin/bash
# Cleanup old log files to prevent disk space issues
# Run this script periodically via cron or systemd timer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGS_DIR="$PROJECT_ROOT/logs"
MAX_TOTAL_SIZE=52428800  # 50MB total for all logs
MAX_AGE_DAYS=7  # Delete .old files older than 7 days

# Find all log files
LOG_FILES=(
    "$LOGS_DIR/stream.log"
    "$LOGS_DIR/stream.log.old"
    "$LOGS_DIR/watchdog.log"
    "$LOGS_DIR/watchdog.log.old"
)

# Delete old .old files
find "$LOGS_DIR" -name "*.log.old" -type f -mtime +$MAX_AGE_DAYS -delete 2>/dev/null

# Calculate total size
TOTAL_SIZE=0
for file in "${LOG_FILES[@]}"; do
    if [ -f "$file" ]; then
        SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
    fi
done

# If total size exceeds limit, truncate .old files
if [ $TOTAL_SIZE -gt $MAX_TOTAL_SIZE ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Total log size ${TOTAL_SIZE} exceeds ${MAX_TOTAL_SIZE}, cleaning up..."
    
    # Remove all .old files first
    rm -f "$LOGS_DIR"/*.log.old
    
    # Recalculate
    TOTAL_SIZE=0
    for file in "$LOGS_DIR/stream.log" "$LOGS_DIR/watchdog.log"; do
        if [ -f "$file" ]; then
            SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
        fi
    done
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] After cleanup: ${TOTAL_SIZE} bytes"
fi

exit 0
