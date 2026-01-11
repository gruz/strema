#!/bin/bash
# Soft reset RP2040 via DTR/RTS signals
# Does NOT change ttyACM device number
# Safe to run while dzyga is running

LOG_FILE="/home/rpidrone/strema/logs/rp2040_reset.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=========================================="
log "Starting soft RP2040 reset"
log "=========================================="

# Check if device exists
if [ ! -e "/dev/rp2040" ]; then
    log "ERROR: /dev/rp2040 not found"
    exit 1
fi

log "Device before reset: $(ls -la /dev/rp2040 | awk '{print $11}')"

# Perform soft reset via DTR/RTS
python3 << 'PYEOF'
import serial
import time
import sys

try:
    ser = serial.Serial('/dev/rp2040', 115200, timeout=1)
    print(f"Opened: {ser.name}")
    
    # Toggle DTR/RTS to reset RP2040
    ser.setDTR(False)
    ser.setRTS(False)
    time.sleep(0.2)
    ser.setDTR(True)
    ser.setRTS(True)
    time.sleep(0.5)
    
    ser.close()
    print("Soft reset completed successfully")
    sys.exit(0)
    
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF

if [ $? -eq 0 ]; then
    log "SUCCESS: Soft reset completed"
    sleep 2
    log "Device after reset: $(ls -la /dev/rp2040 | awk '{print $11}')"
    log "=========================================="
    log "Check dzyga log to verify reconnection"
    log "=========================================="
    exit 0
else
    log "ERROR: Soft reset failed"
    exit 1
fi
