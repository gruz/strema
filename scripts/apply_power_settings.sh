#!/bin/bash
# Script to apply power saving settings
# Reduces power consumption for long PoE cable deployments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
LOG_FILE="$PROJECT_ROOT/logs/power_settings.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Power saving settings with defaults
POWER_SAVE_WIFI=${POWER_SAVE_WIFI:-false}
POWER_SAVE_BLUETOOTH=${POWER_SAVE_BLUETOOTH:-false}
POWER_SAVE_HDMI=${POWER_SAVE_HDMI:-false}
POWER_SAVE_ETH_SPEED=${POWER_SAVE_ETH_SPEED:-auto}
POWER_SAVE_ETH_AUTONEG=${POWER_SAVE_ETH_AUTONEG:-on}

log "=========================================="
log "Applying power saving settings"
log "=========================================="

# WiFi control
if [ "$POWER_SAVE_WIFI" = "true" ]; then
    log "Disabling WiFi..."
    rfkill block wifi 2>/dev/null
    if [ $? -eq 0 ]; then
        log "  WiFi disabled successfully"
    else
        log "  WARNING: Failed to disable WiFi"
    fi
else
    log "Enabling WiFi..."
    rfkill unblock wifi 2>/dev/null
    log "  WiFi enabled"
fi

# Bluetooth control
if [ "$POWER_SAVE_BLUETOOTH" = "true" ]; then
    log "Disabling Bluetooth..."
    rfkill block bluetooth 2>/dev/null
    if [ $? -eq 0 ]; then
        log "  Bluetooth disabled successfully"
    else
        log "  WARNING: Failed to disable Bluetooth"
    fi
else
    log "Enabling Bluetooth..."
    rfkill unblock bluetooth 2>/dev/null
    log "  Bluetooth enabled"
fi

# HDMI control
if [ "$POWER_SAVE_HDMI" = "true" ]; then
    log "Disabling HDMI output..."
    vcgencmd display_power 0 2>/dev/null
    if [ $? -eq 0 ]; then
        log "  HDMI disabled successfully"
    else
        log "  WARNING: Failed to disable HDMI"
    fi
else
    log "Enabling HDMI output..."
    vcgencmd display_power 1 2>/dev/null
    log "  HDMI enabled"
fi

# Ethernet speed control
if [ "$POWER_SAVE_ETH_SPEED" != "auto" ]; then
    log "Setting Ethernet speed to ${POWER_SAVE_ETH_SPEED}Mbps, autoneg: ${POWER_SAVE_ETH_AUTONEG}..."
    
    if [ "$POWER_SAVE_ETH_AUTONEG" = "off" ]; then
        # Fixed speed without auto-negotiation
        ethtool -s eth0 speed "$POWER_SAVE_ETH_SPEED" duplex full autoneg off 2>/dev/null
        if [ $? -eq 0 ]; then
            log "  Ethernet configured: ${POWER_SAVE_ETH_SPEED}Mbps, duplex full, autoneg off"
        else
            log "  WARNING: Failed to configure Ethernet speed"
        fi
    else
        # Auto-negotiation enabled
        ethtool -s eth0 autoneg on 2>/dev/null
        if [ $? -eq 0 ]; then
            log "  Ethernet configured: auto-negotiation enabled"
        else
            log "  WARNING: Failed to enable auto-negotiation"
        fi
    fi
else
    log "Ethernet speed: auto (no changes)"
fi

log "=========================================="
log "Power settings applied successfully"
log "=========================================="

exit 0
