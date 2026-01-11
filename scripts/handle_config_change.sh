#!/bin/bash
# Universal configuration change handler
# Monitors config changes and applies appropriate actions:
# - Power settings if POWER_SAVE_* changed
# - Auto-restart timer if AUTO_RESTART_* changed
# - Stream restart if critical params changed and stream is active

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
DEFAULTS_FILE="$PROJECT_ROOT/config/defaults.conf"
SNAPSHOT_FILE="/tmp/forpost_config_snapshot.conf"
LOG_FILE="$PROJECT_ROOT/logs/config_handler.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Load configuration with defaults
load_config() {
    local config_array=()
    
    # Load defaults first
    if [ -f "$DEFAULTS_FILE" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value#\"}"
            value="${value%\"}"
            config_array+=("$key=$value")
        done < "$DEFAULTS_FILE"
    fi
    
    # Override with actual config
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value#\"}"
            value="${value%\"}"
            # Remove from array if exists, then add new value
            config_array=("${config_array[@]/$key=*}")
            config_array+=("$key=$value")
        done < "$CONFIG_FILE"
    fi
    
    printf '%s\n' "${config_array[@]}"
}

# Get value from config array
get_value() {
    local key="$1"
    local config="$2"
    echo "$config" | grep "^$key=" | cut -d= -f2-
}

# Check if power settings changed
power_settings_changed() {
    local old_config="$1"
    local new_config="$2"
    
    local power_keys=("POWER_SAVE_WIFI" "POWER_SAVE_BLUETOOTH")
    
    for key in "${power_keys[@]}"; do
        local old_val=$(get_value "$key" "$old_config")
        local new_val=$(get_value "$key" "$new_config")
        if [ "$old_val" != "$new_val" ]; then
            log "Power setting changed: $key ($old_val -> $new_val)"
            return 0
        fi
    done
    
    return 1
}

# Check if autostart setting changed
autostart_setting_changed() {
    local old_config="$1"
    local new_config="$2"
    
    local old_val=$(get_value "AUTOSTART_ENABLED" "$old_config")
    local new_val=$(get_value "AUTOSTART_ENABLED" "$new_config")
    
    if [ "$old_val" != "$new_val" ]; then
        log "Autostart setting changed: ($old_val -> $new_val)"
        return 0
    fi
    
    return 1
}

# Check if auto-restart settings changed
autorestart_settings_changed() {
    local old_config="$1"
    local new_config="$2"
    
    local restart_keys=("AUTO_RESTART_ENABLED" "AUTO_RESTART_INTERVAL")
    
    for key in "${restart_keys[@]}"; do
        local old_val=$(get_value "$key" "$old_config")
        local new_val=$(get_value "$key" "$new_config")
        if [ "$old_val" != "$new_val" ]; then
            log "Auto-restart setting changed: $key ($old_val -> $new_val)"
            return 0
        fi
    done
    
    return 1
}

# Check if stream-critical parameters changed
stream_critical_changed() {
    local old_config="$1"
    local new_config="$2"
    
    # Parameters that require stream restart
    local critical_keys=(
        "RTMP_URL"
        "VIDEO_DEVICE"
        "VIDEO_CRF"
        "VIDEO_FPS"
        "RTSP_PORT"
        "USE_UDP_PROXY"
        "UDP_PROXY_PORT"
        "STREAM_MODE"
        "OVERLAY_ENABLED"
        "OVERLAY_TEXT"
        "OVERLAY_POSITION"
        "OVERLAY_FONTSIZE_CUSTOM"
        "OVERLAY_TEXT_COLOR"
        "OVERLAY_TEXT_OPACITY_CUSTOM"
        "OVERLAY_BORDER_WIDTH"
        "OVERLAY_BORDER_COLOR"
        "OVERLAY_BG_COLOR"
        "OVERLAY_BG_OPACITY_CUSTOM"
        "SHOW_FREQUENCY"
        "FREQUENCY_POSITION"
        "FREQUENCY_FONTSIZE"
        "FREQUENCY_TEXT_COLOR"
        "FREQUENCY_TEXT_OPACITY"
        "FREQUENCY_BORDER_WIDTH"
        "FREQUENCY_BORDER_COLOR"
        "FREQUENCY_BG_COLOR"
        "FREQUENCY_BG_OPACITY"
        "DYNAMIC_OVERLAY_POSITION"
        "DYNAMIC_OVERLAY_FONTSIZE"
        "DYNAMIC_OVERLAY_TEXT_COLOR"
        "DYNAMIC_OVERLAY_TEXT_OPACITY"
        "DYNAMIC_OVERLAY_BG_COLOR"
        "DYNAMIC_OVERLAY_BG_OPACITY"
        "DYNAMIC_OVERLAY_BORDER_WIDTH"
        "DYNAMIC_OVERLAY_BORDER_COLOR"
        "FFMPEG_LOGLEVEL"
    )
    
    for key in "${critical_keys[@]}"; do
        local old_val=$(get_value "$key" "$old_config")
        local new_val=$(get_value "$key" "$new_config")
        if [ "$old_val" != "$new_val" ]; then
            log "Stream-critical parameter changed: $key"
            return 0
        fi
    done
    
    return 1
}

# Apply power settings
apply_power_settings() {
    log "Applying power settings..."
    if bash "$SCRIPT_DIR/apply_power_settings.sh" >> "$LOG_FILE" 2>&1; then
        log "Power settings applied successfully"
    else
        log "WARNING: Failed to apply power settings"
    fi
}

# Apply autostart setting
apply_autostart_setting() {
    local new_config=$(load_config)
    local autostart_enabled=$(get_value "AUTOSTART_ENABLED" "$new_config")
    
    log "Applying autostart setting..."
    
    if [ "$autostart_enabled" = "true" ]; then
        if systemctl enable forpost-stream 2>/dev/null; then
            log "Autostart enabled (systemctl enable forpost-stream)"
        else
            log "WARNING: Failed to enable autostart"
        fi
    else
        if systemctl disable forpost-stream 2>/dev/null; then
            log "Autostart disabled (systemctl disable forpost-stream)"
        else
            log "WARNING: Failed to disable autostart"
        fi
    fi
}

# Update auto-restart timer
update_autorestart_timer() {
    log "Updating auto-restart timer..."
    if bash "$SCRIPT_DIR/update_autorestart.sh" >> "$LOG_FILE" 2>&1; then
        log "Auto-restart timer updated successfully"
    else
        log "WARNING: Failed to update auto-restart timer"
    fi
}

# Restart stream service
restart_stream() {
    log "Restarting stream service..."
    
    # Check if stream is actually running
    if ! systemctl is-active --quiet forpost-stream; then
        log "Stream service is not active, skipping restart"
        return 0
    fi
    
    # Restart UDP proxy if enabled
    local new_config=$(load_config)
    local use_udp=$(get_value "USE_UDP_PROXY" "$new_config")
    if [ "$use_udp" = "true" ]; then
        log "Restarting UDP proxy..."
        systemctl restart forpost-udp-proxy 2>/dev/null || true
    fi
    
    # Restart stream
    if systemctl restart forpost-stream; then
        log "Stream service restarted successfully"
    else
        log "ERROR: Failed to restart stream service"
        return 1
    fi
}

# Main logic
main() {
    log "=========================================="
    log "Configuration change detected"
    log "=========================================="
    
    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        log "Configuration file not found, nothing to do"
        exit 0
    fi
    
    # Load current configuration
    local new_config=$(load_config)
    
    # Load previous snapshot (if exists)
    local old_config=""
    if [ -f "$SNAPSHOT_FILE" ]; then
        old_config=$(cat "$SNAPSHOT_FILE")
    else
        log "No previous snapshot found, creating initial snapshot"
        echo "$new_config" > "$SNAPSHOT_FILE"
        log "Initial snapshot created, applying all settings"
        apply_power_settings
        update_autorestart_timer
        exit 0
    fi
    
    # Detect what changed
    local power_changed=false
    local autostart_changed=false
    local autorestart_changed=false
    local stream_changed=false
    
    if power_settings_changed "$old_config" "$new_config"; then
        power_changed=true
    fi
    
    if autostart_setting_changed "$old_config" "$new_config"; then
        autostart_changed=true
    fi
    
    if autorestart_settings_changed "$old_config" "$new_config"; then
        autorestart_changed=true
    fi
    
    if stream_critical_changed "$old_config" "$new_config"; then
        stream_changed=true
    fi
    
    # Apply changes
    if [ "$power_changed" = true ]; then
        apply_power_settings
    fi
    
    if [ "$autostart_changed" = true ]; then
        apply_autostart_setting
    fi
    
    if [ "$autorestart_changed" = true ]; then
        update_autorestart_timer
    fi
    
    if [ "$stream_changed" = true ]; then
        restart_stream
    fi
    
    # Save new snapshot
    echo "$new_config" > "$SNAPSHOT_FILE"
    
    if [ "$power_changed" = false ] && [ "$autostart_changed" = false ] && [ "$autorestart_changed" = false ] && [ "$stream_changed" = false ]; then
        log "No significant changes detected"
    fi
    
    log "Configuration change handling complete"
    log "=========================================="
}

main
