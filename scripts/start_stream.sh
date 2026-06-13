#!/bin/bash

# Script for starting video stream from Forpost

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/stream.conf"
LOG_FILE="$PROJECT_ROOT/logs/stream.log"
MAX_LOG_SIZE=10485760  # 10MB

# Rotate log if too large
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
    # Keep only last 10MB, remove old backup
    rm -f "$LOG_FILE.old"
    mv "$LOG_FILE" "$LOG_FILE.old"
    # Truncate old file to last 5MB to save space
    tail -c 5242880 "$LOG_FILE.old" > "$LOG_FILE.old.tmp" 2>/dev/null && mv "$LOG_FILE.old.tmp" "$LOG_FILE.old"
fi

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Debug logging
DEBUG_LOG_FILE="$PROJECT_ROOT/logs/debug.log"
DEBUG_RAW_FILE="$PROJECT_ROOT/logs/debug_raw.log"
MAX_DEBUG_SIZE=5242880  # 5MB

debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_LOG_FILE"
}

# Check for configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    log "ПОМИЛКА: Файл конфігурації не знайдено: $CONFIG_FILE"
    exit 1
fi

# Load default values first
DEFAULTS_FILE="$(dirname "$0")/../config/defaults.conf"
if [ -f "$DEFAULTS_FILE" ]; then
    source "$DEFAULTS_FILE"
fi

# Load configuration (overrides defaults)
source "$CONFIG_FILE"

# Initialize debug mode
if [ "$DEBUG_MODE" = "true" ]; then
    if [ -f "$DEBUG_LOG_FILE" ] && [ $(stat -c%s "$DEBUG_LOG_FILE" 2>/dev/null) -gt $MAX_DEBUG_SIZE ]; then
        mv "$DEBUG_LOG_FILE" "$DEBUG_LOG_FILE.old"
    fi
    > "$DEBUG_RAW_FILE"
fi

# Auto-detect IP address if not set in config
if [ -z "$FORPOST_IP" ] || [ "$FORPOST_IP" = "auto" ]; then
    FORPOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    if [ -z "$FORPOST_IP" ]; then
        # RTSP server runs locally, loopback works as fallback
        FORPOST_IP="127.0.0.1"
        log "ПОПЕРЕДЖЕННЯ: Не вдалося визначити IP, використовуємо резервний $FORPOST_IP"
    else
        log "Автоматично визначено IP: $FORPOST_IP"
    fi
fi

# Auto-detect RTSP transport using shared function
source "$SCRIPT_DIR/detect_rtsp_transport.sh"
RTSP_TRANSPORT=$(detect_rtsp_transport)
if [ "$RTSP_TRANSPORT" = "udp" ]; then
    log "Виявлено VLC RTSP сервер — використовуємо UDP транспорт"
else
    log "Виявлено кастомний RTSP сервер — використовуємо TCP транспорт"
fi

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    log "ПОМИЛКА: ffmpeg не встановлено"
    exit 1
fi

# Build RTSP URL
RTSP_URL="rtsp://${FORPOST_IP}:${RTSP_PORT}/${VIDEO_DEVICE}"

# UDP Proxy settings (loaded from defaults.conf)
if [ "$USE_UDP_PROXY" = "true" ]; then
    # Small buffer to prevent lag accumulation - old packets are dropped
    INPUT_URL="udp://127.0.0.1:${UDP_PROXY_PORT}?overrun_nonfatal=1&fifo_size=500000&buffer_size=500000&listen=0"
    log "Режим UDP Proxy увімкнено — читаємо з UDP порту ${UDP_PROXY_PORT}"
else
    INPUT_URL="$RTSP_URL"
fi

# Validate required settings
if [ -z "${RTMP_URL}" ]; then
    log "ПОМИЛКА: RTMP_URL не налаштовано. Відкрийте веб-інтерфейс і встановіть RTMP URL, потім перезапустіть сервіс."
    exit 1
fi

log "=========================================="
log "Запуск відеопотоку"
log "=========================================="
log "Джерело RTSP: $RTSP_URL"
log "RTMP: ${RTMP_URL%/*}/***"
log "Режим стріму: $STREAM_MODE"
log "=========================================="

# File for dynamic frequency
FREQ_FILE="/tmp/dzyga_freq.txt"
FREQ_UPDATER="$SCRIPT_DIR/update_frequency.sh"
SCAN_DETECTOR="$SCRIPT_DIR/detect_scan_state.sh"

# File for dynamic overlay
DYNAMIC_OVERLAY_FILE="/tmp/dzyga_dynamic_overlay.txt"
DYNAMIC_OVERLAY_UPDATER="$SCRIPT_DIR/update_dynamic_overlay.sh"

# Function to check if we should stream based on scan state
# $1 - threshold: 1=fast/sensitive (for initial check), 2=tolerant (for monitoring)
should_stream() {
    local threshold=${1}
    
    # In overlay mode, always stream (scanning indicator shown in overlay)
    # In always mode, always stream (ignore scanning)
    # In on-lock mode, only stream when locked
    if [ "$STREAM_MODE" != "on-lock" ]; then
        return 0
    fi
    
    if [ ! -x "$SCAN_DETECTOR" ]; then
        log "ПОПЕРЕДЖЕННЯ: Детектор сканування не знайдено, стрім запущено попри це"
        return 0
    fi
    
    "$SCAN_DETECTOR" 3 1.0 0 $threshold >/dev/null 2>&1
    local state=$?
    
    case $state in
        0)
            return 0
            ;;
        1)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Function to calculate position coordinates
get_position_coords() {
    local position=$1
    local x_coord="10"
    local y_coord="10"
    
    case "$position" in
        "top-left")
            x_coord="10"
            y_coord="10"
            ;;
        "top-right")
            x_coord="(w-text_w-10)"
            y_coord="10"
            ;;
        "bottom-left")
            x_coord="10"
            y_coord="(h-text_h-60)"
            ;;
        "bottom-right")
            x_coord="(w-text_w-10)"
            y_coord="(h-text_h-60)"
            ;;
        *)
            x_coord="10"
            y_coord="10"
            ;;
    esac
    
    echo "${x_coord}:${y_coord}"
}

# Unified function to create drawtext filter
# Usage: create_drawtext_filter <file_or_text> <position> <fontsize> <color> <text_opacity> <border_width> <border_color> <bg_color> <bg_opacity> <is_file>
create_drawtext_filter() {
    local content=$1
    local position=$2
    local fontsize=$3
    local color=$4
    local text_opacity=$5
    local border_width=$6
    local border_color=$7
    local bg_color=$8
    local bg_opacity=$9
    local is_file=${10}
    
    local coords=$(get_position_coords "$position")
    local x_coord="${coords%:*}"
    local y_coord="${coords#*:}"
    
    if [ "$is_file" = "true" ]; then
        local text_param="textfile='${content}':reload=1"
    else
        local text_param="text='${content}'"
    fi
    
    if [ "$border_width" -gt 0 ]; then
        # Use border for readability
        echo "drawtext=${text_param}:fontsize=${fontsize}:fontcolor=${color}@${text_opacity}:borderw=${border_width}:bordercolor=${border_color}:x=${x_coord}:y=${y_coord}"
    else
        # Use background box
        echo "drawtext=${text_param}:fontsize=${fontsize}:fontcolor=${color}@${text_opacity}:box=1:boxcolor=${bg_color}@${bg_opacity}:boxborderw=5:x=${x_coord}:y=${y_coord}"
    fi
}

# Overlay enabled (master switch for encoding vs copy)
OVERLAY_ENABLED=${OVERLAY_ENABLED:-true}

# Static overlay display defaults
OVERLAY_FONTSIZE_CUSTOM=${OVERLAY_FONTSIZE_CUSTOM:-20}
OVERLAY_TEXT_COLOR=${OVERLAY_TEXT_COLOR:-white}
OVERLAY_TEXT_OPACITY_CUSTOM=${OVERLAY_TEXT_OPACITY_CUSTOM:-1.0}
OVERLAY_BORDER_WIDTH=${OVERLAY_BORDER_WIDTH:-0}
OVERLAY_BORDER_COLOR=${OVERLAY_BORDER_COLOR:-black}
OVERLAY_BG_COLOR=${OVERLAY_BG_COLOR:-black}
OVERLAY_BG_OPACITY_CUSTOM=${OVERLAY_BG_OPACITY_CUSTOM:-0.5}

# Frequency display defaults
FREQUENCY_FONTSIZE=${FREQUENCY_FONTSIZE:-20}
FREQUENCY_TEXT_COLOR=${FREQUENCY_TEXT_COLOR:-yellow}
FREQUENCY_TEXT_OPACITY=${FREQUENCY_TEXT_OPACITY:-1.0}
FREQUENCY_BORDER_WIDTH=${FREQUENCY_BORDER_WIDTH:-0}
FREQUENCY_BORDER_COLOR=${FREQUENCY_BORDER_COLOR:-black}
FREQUENCY_BG_COLOR=${FREQUENCY_BG_COLOR:-black}
FREQUENCY_BG_OPACITY=${FREQUENCY_BG_OPACITY:-0.5}

# Dynamic overlay defaults
DYNAMIC_OVERLAY_POSITION=${DYNAMIC_OVERLAY_POSITION:-bottom-left}
DYNAMIC_OVERLAY_FONTSIZE=${DYNAMIC_OVERLAY_FONTSIZE:-20}
DYNAMIC_OVERLAY_TEXT_COLOR=${DYNAMIC_OVERLAY_TEXT_COLOR:-white}
DYNAMIC_OVERLAY_TEXT_OPACITY=${DYNAMIC_OVERLAY_TEXT_OPACITY:-1.0}
DYNAMIC_OVERLAY_BG_COLOR=${DYNAMIC_OVERLAY_BG_COLOR:-black}
DYNAMIC_OVERLAY_BG_OPACITY=${DYNAMIC_OVERLAY_BG_OPACITY:-0.5}
DYNAMIC_OVERLAY_BORDER_WIDTH=${DYNAMIC_OVERLAY_BORDER_WIDTH:-0}
DYNAMIC_OVERLAY_BORDER_COLOR=${DYNAMIC_OVERLAY_BORDER_COLOR:-black}

# Calculate GOP (keyframe interval) based on FPS
# GOP = FPS * 2 (keyframe every 2 seconds)
VIDEO_GOP=$((VIDEO_FPS * 2))

# Calculate bufsize as 1.5x bitrate for better motion quality
# while keeping maxrate capped at the target bitrate (Delta requirement)
VIDEO_BITRATE_NUM="${VIDEO_BITRATE%k}"
VIDEO_BUFSIZE=$((VIDEO_BITRATE_NUM * 15 / 10))k

# Build video filter and encoding parameters
if [ "$OVERLAY_ENABLED" = "true" ]; then
    
    # Build filter
    VF_FILTER=""
    
    # Static overlay text
    if [ -n "$OVERLAY_TEXT" ]; then
        log "Текст оверлею: $OVERLAY_TEXT (позиція: $OVERLAY_POSITION)"
        VF_FILTER=$(create_drawtext_filter "$OVERLAY_TEXT" "$OVERLAY_POSITION" "$OVERLAY_FONTSIZE_CUSTOM" "$OVERLAY_TEXT_COLOR" "$OVERLAY_TEXT_OPACITY_CUSTOM" "$OVERLAY_BORDER_WIDTH" "$OVERLAY_BORDER_COLOR" "$OVERLAY_BG_COLOR" "$OVERLAY_BG_OPACITY_CUSTOM" false)
    fi
    
    # Dynamic frequency
    if [ "$SHOW_FREQUENCY" = "true" ]; then
        log "Частота: увімкнено (оновлення кожні 2 с, позиція: $FREQUENCY_POSITION)"
        
        # Start frequency updater in background
        if [ -x "$FREQ_UPDATER" ]; then
            rm -f "$FREQ_FILE"
            echo "---" > "$FREQ_FILE"
            chmod 666 "$FREQ_FILE"
            # Export STREAM_MODE so update_frequency.sh can use it
            export STREAM_MODE
            "$FREQ_UPDATER" &
            FREQ_PID=$!
            trap "kill $FREQ_PID 2>/dev/null" EXIT
            log "Запущено оновлювач частоти (PID: $FREQ_PID)"
        else
            log "ПОПЕРЕДЖЕННЯ: Скрипт оновлення частоти не знайдено: $FREQ_UPDATER"
        fi
        
        # Add frequency filter with configurable display parameters
        FREQ_FILTER=$(create_drawtext_filter "$FREQ_FILE" "$FREQUENCY_POSITION" "$FREQUENCY_FONTSIZE" "$FREQUENCY_TEXT_COLOR" "$FREQUENCY_TEXT_OPACITY" "$FREQUENCY_BORDER_WIDTH" "$FREQUENCY_BORDER_COLOR" "$FREQUENCY_BG_COLOR" "$FREQUENCY_BG_OPACITY" true)
        
        if [ -n "$VF_FILTER" ]; then
            VF_FILTER="${VF_FILTER},${FREQ_FILTER}"
        else
            VF_FILTER="$FREQ_FILTER"
        fi
    fi
    
    # Dynamic overlay (always available when overlay enabled)
    log "Динамічний оверлей: доступний (позиція: $DYNAMIC_OVERLAY_POSITION)"
    
    # Initialize dynamic overlay file
    rm -f "$DYNAMIC_OVERLAY_FILE"
    echo "" > "$DYNAMIC_OVERLAY_FILE"
    chmod 666 "$DYNAMIC_OVERLAY_FILE"
    
    # Start dynamic overlay updater in background
    if [ -x "$DYNAMIC_OVERLAY_UPDATER" ]; then
        "$DYNAMIC_OVERLAY_UPDATER" &
        DYNAMIC_OVERLAY_PID=$!
        trap "kill $DYNAMIC_OVERLAY_PID 2>/dev/null; kill $FREQ_PID 2>/dev/null" EXIT
        log "Запущено оновлювач динамічного оверлею (PID: $DYNAMIC_OVERLAY_PID)"
    else
        log "ПОПЕРЕДЖЕННЯ: Скрипт оновлення динамічного оверлею не знайдено: $DYNAMIC_OVERLAY_UPDATER"
    fi
    
    # Build dynamic overlay filter
    DYNAMIC_FILTER=$(create_drawtext_filter "$DYNAMIC_OVERLAY_FILE" "$DYNAMIC_OVERLAY_POSITION" "$DYNAMIC_OVERLAY_FONTSIZE" "$DYNAMIC_OVERLAY_TEXT_COLOR" "$DYNAMIC_OVERLAY_TEXT_OPACITY" "$DYNAMIC_OVERLAY_BORDER_WIDTH" "$DYNAMIC_OVERLAY_BORDER_COLOR" "$DYNAMIC_OVERLAY_BG_COLOR" "$DYNAMIC_OVERLAY_BG_OPACITY" true)
    
    if [ -n "$VF_FILTER" ]; then
        VF_FILTER="${VF_FILTER},${DYNAMIC_FILTER}"
    else
        VF_FILTER="$DYNAMIC_FILTER"
    fi
    
    # Pre-filter: reduce input framerate before overlay to save CPU
    if [ -n "$VF_FILTER" ]; then
        VF_FILTER="fps=fps=${VIDEO_FPS}:round=near,${VF_FILTER}"
    fi
    # Detect available encoder: prefer hardware, fallback to software
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "h264_v4l2m2m"; then
        ENCODER="h264_v4l2m2m"
        ENCODER_OPTS=""
        log "Використовуємо апаратне кодування (h264_v4l2m2m)"
    else
        ENCODER="libx264"
        ENCODER_OPTS="-preset ultrafast -tune zerolatency -bf 0 -pix_fmt yuv420p -sc_threshold 0"
        log "Використовуємо програмне кодування (libx264, fallback)"
    fi
    log "Параметри: BITRATE=${VIDEO_BITRATE}, FPS=${VIDEO_FPS}, GOP=${VIDEO_GOP}"
    log "Статичний оверлей: розмір шрифту=${OVERLAY_FONTSIZE_CUSTOM}, колір=${OVERLAY_TEXT_COLOR}"
    log "Частота: розмір шрифту=${FREQUENCY_FONTSIZE}, колір=${FREQUENCY_TEXT_COLOR}"
    log "Динамічний оверлей: розмір шрифту=${DYNAMIC_OVERLAY_FONTSIZE}, колір=${DYNAMIC_OVERLAY_TEXT_COLOR}"
else
    log "Оверлей вимкнено — використовуємо копіювання потоку (без перекодування)"
    log "ПОПЕРЕДЖЕННЯ: Параметри потоку камери (бітрейт/профіль/FPS) можуть не відповідати вимогам RTMP-сервера"
fi

# Auto-reconnect loop (watchdog service handles service restarts)
RECONNECT_DELAY=2
CHECK_INTERVAL=5
METRIC_INTERVAL=2  # how often to collect debug metrics (faster than scan check)

while true; do
    LAST_FFMPEG_EXIT=""
    # Initial check: fast detection (threshold=1) - any 1+ change = scanning
    if should_stream 1; then
        log "Підключення до потоку..."
        
        # Build ffmpeg command based on source type
        if [ "$USE_UDP_PROXY" = "true" ]; then
            # UDP input - larger probesize for Starlink jitter
            INPUT_PARAMS="-fflags nobuffer -flags low_delay -probesize 500000 -analyzeduration 1000000 -thread_queue_size 512 -i $INPUT_URL"
        else
            # RTSP input
            INPUT_PARAMS="-rtsp_transport $RTSP_TRANSPORT -fflags +genpts+igndts -probesize 500000 -analyzeduration 1000000 -thread_queue_size 512 -i $RTSP_URL"
        fi
        
        # Build video encoding parameters and run in background
        if [ "$OVERLAY_ENABLED" = "true" ]; then
            # With overlay - re-encode with Delta-compatible settings:
            # libx264, constrained bitrate (maxrate capped), zerolatency, no B-frames, GOP = 2 * FPS.
            # Bufsize is 1.5x bitrate to improve motion quality without exceeding maxrate.
            # Optional late-frame dropping (configured in advanced settings)
            VSYNC_OPTS=""
            if [ "$FFMPEG_DROP_LATE_FRAMES" = "true" ]; then
                VSYNC_OPTS="-vsync drop -max_muxing_queue_size 1024"
            fi

            # Build ffmpeg args as array (no duplication between log and exec)
            if [ "$DEBUG_MODE" = "true" ]; then
                FFMPEG_ARR=(ffmpeg -hide_banner -loglevel verbose -stats_period 5)
            else
                FFMPEG_ARR=(ffmpeg -hide_banner)
            fi
            read -ra INPUT_ARR <<< "$INPUT_PARAMS"
            FFMPEG_ARR+=("${INPUT_ARR[@]}")
            FFMPEG_ARR+=(-vf "$VF_FILTER" -r "${VIDEO_FPS}" -c:v "${ENCODER}")
            if [ -n "$ENCODER_OPTS" ]; then
                read -ra ENC_ARR <<< "$ENCODER_OPTS"
                FFMPEG_ARR+=("${ENC_ARR[@]}")
            fi
            if [ -n "$VSYNC_OPTS" ]; then
                read -ra VSYNC_ARR <<< "$VSYNC_OPTS"
                FFMPEG_ARR+=("${VSYNC_ARR[@]}")
            fi
            FFMPEG_ARR+=(-b:v "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "${VIDEO_BUFSIZE}" -g "${VIDEO_GOP}" -an -f flv "${RTMP_URL}")
            if [ "$DEBUG_MODE" = "true" ]; then
                debug_log "ffmpeg command: ${FFMPEG_ARR[*]}"
                "${FFMPEG_ARR[@]}" 2>> "$DEBUG_RAW_FILE" &
            else
                "${FFMPEG_ARR[@]}" 2>/dev/null &
            fi
        else
            # No overlay - just copy
            if [ "$DEBUG_MODE" = "true" ]; then
                FFMPEG_ARR=(ffmpeg -hide_banner -loglevel verbose -stats_period 5)
            else
                FFMPEG_ARR=(ffmpeg -hide_banner)
            fi
            read -ra INPUT_ARR <<< "$INPUT_PARAMS"
            FFMPEG_ARR+=("${INPUT_ARR[@]}")
            FFMPEG_ARR+=(-c:v copy -an -f flv "${RTMP_URL}")
            if [ "$DEBUG_MODE" = "true" ]; then
                debug_log "ffmpeg command: ${FFMPEG_ARR[*]}"
                "${FFMPEG_ARR[@]}" 2>> "$DEBUG_RAW_FILE" &
            else
                "${FFMPEG_ARR[@]}" 2>/dev/null &
            fi
        fi
        
        FFMPEG_PID=$!
        
        # Start debug monitor if enabled
        if [ "$DEBUG_MODE" = "true" ]; then
            # Delta server blocks ICMP - ping the default gateway (local link health)
            # and read TCP RTT/retransmits from the actual RTMP connection via ss
            GW_FOR_PING=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
            RTMP_PORT_NUM=$(echo "$RTMP_URL" | sed -n 's|rtmp[s]*://[^/:]*:\([0-9]*\)/.*|\1|p')
            [ -z "$RTMP_PORT_NUM" ] && RTMP_PORT_NUM=1935
            (
            while kill -0 "$FFMPEG_PID" 2>/dev/null; do
                sleep $METRIC_INTERVAL
                CPU_RAW=$(top -b -n1 -p "$FFMPEG_PID" 2>/dev/null | tail -1 | awk '{print $9}' | cut -d. -f1)
                # top may output header/footer when process dies - validate numeric
                if echo "$CPU_RAW" | grep -qE '^[0-9]+$'; then
                    CPU_FFMPEG="$CPU_RAW"
                else
                    CPU_FFMPEG="N/A"
                fi
                LOAD_AVG=$(cut -d' ' -f1 /proc/loadavg)

                # CPU temperature
                CPU_TEMP="N/A"
                if command -v vcgencmd &>/dev/null; then
                    CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -o '[0-9.]*' | head -1)
                elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
                    CPU_TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
                fi

                # Free memory (MB)
                MEM_FREE=$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')
                [ -z "$MEM_FREE" ] && MEM_FREE="N/A"

                # Power status (Raspberry Pi): undervoltage and throttling flags
                # get_throttled bits: 0=undervoltage now, 1=freq capped now, 2=throttled now,
                #                     16=undervoltage occurred, 17=freq capped occurred, 18=throttled occurred
                PWR_STATUS="N/A"
                CORE_VOLT="N/A"
                if command -v vcgencmd &>/dev/null; then
                    THROTTLED_HEX=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
                    if [ -n "$THROTTLED_HEX" ]; then
                        THROTTLED_VAL=$((THROTTLED_HEX))
                        PWR_STATUS="ok"
                        [ $((THROTTLED_VAL & 0x50000)) -ne 0 ] && PWR_STATUS="was_bad"
                        [ $((THROTTLED_VAL & 0x5)) -ne 0 ] && PWR_STATUS="UNDERVOLT"
                    fi
                    CORE_VOLT=$(vcgencmd measure_volts core 2>/dev/null | grep -o '[0-9.]*' | head -1)
                    [ -z "$CORE_VOLT" ] && CORE_VOLT="N/A"
                    ARM_CLOCK=$(vcgencmd measure_clock arm 2>/dev/null | cut -d= -f2)
                    [ -z "$ARM_CLOCK" ] && ARM_CLOCK="N/A"
                fi

                # USB disconnects since boot (cumulative counter)
                # Peripherals (VRX/capture/RP2040) resetting may indicate power issues
                USB_DISC=$(dmesg 2>/dev/null | grep -c 'USB disconnect')

                # Key peripheral presence and USB power health
                USB_DEVS=$(lsusb 2>/dev/null | wc -l)
                VIDEO_DEV=$(ls /dev/video* 2>/dev/null | wc -l)
                TTYACM_DEV=$(ls /dev/ttyACM* 2>/dev/null | wc -l)
                USB_PWR_ERR=$(dmesg 2>/dev/null | grep -ciE 'under-voltage|over-current|not enough power|usb .* power')

                # Local link: burst ping to gateway (5 probes in 1s) for jitter and loss
                PING_MS="N/A"
                PING_LOSS="N/A"
                if [ -n "$GW_FOR_PING" ]; then
                    PING_OUT=$(ping -c 5 -i 0.2 -W 2 "$GW_FOR_PING" 2>/dev/null)
                    PING_STATS=$(echo "$PING_OUT" | grep -o 'min/avg/max[^=]*= [0-9./]*' | grep -o '[0-9./]*$')
                    PING_LOSS=$(echo "$PING_OUT" | grep -o '[0-9]*% packet loss' | grep -o '^[0-9]*')
                    if [ -n "$PING_STATS" ]; then
                        # min/avg/max/mdev -> keep min/avg/max
                        PING_MS=$(echo "$PING_STATS" | cut -d/ -f1-3)
                    else
                        PING_MS="timeout"
                    fi
                    [ -z "$PING_LOSS" ] && PING_LOSS="100"
                fi

                # RTMP connection health: TCP RTT and total retransmits from ss
                # retrans:X/Y -> Y is total; pattern with "/" avoids matching bytes_retrans
                SS_INFO=$(ss -tin "dport = :${RTMP_PORT_NUM}" 2>/dev/null)
                TCP_RTT=$(echo "$SS_INFO" | grep -o 'rtt:[0-9.]*' | head -1 | cut -d: -f2)
                RETRANS=$(echo "$SS_INFO" | grep -o 'retrans:[0-9]*/[0-9]*' | head -1 | cut -d/ -f2)
                [ -z "$TCP_RTT" ] && TCP_RTT="N/A"
                [ -z "$RETRANS" ] && RETRANS="0"

                # FFmpeg stats from debug_raw.log (speed, fps, drop)
                # ffmpeg separates progress lines with \r and pads numbers (e.g. "fps= 24")
                FFMPEG_SPEED="N/A"
                FFMPEG_FPS="N/A"
                FFMPEG_DROP="N/A"
                if [ -f "$DEBUG_RAW_FILE" ]; then
                    LAST_STATS=$(tail -c 8192 "$DEBUG_RAW_FILE" 2>/dev/null | tr '\r' '\n' | grep 'speed=' | tail -n 3)
                    SPEED_VAL=$(echo "$LAST_STATS" | grep -o 'speed= *[0-9.]*x' | tail -1 | grep -o '[0-9.]*x')
                    FPS_VAL=$(echo "$LAST_STATS" | grep -o 'fps= *[0-9.]*' | tail -1 | grep -o '[0-9.]*$')
                    DROP_VAL=$(echo "$LAST_STATS" | grep -o 'drop= *[0-9]*' | tail -1 | grep -o '[0-9]*$')
                    [ -n "$SPEED_VAL" ] && FFMPEG_SPEED="$SPEED_VAL"
                    [ -n "$FPS_VAL" ] && FFMPEG_FPS="$FPS_VAL"
                    [ -n "$DROP_VAL" ] && FFMPEG_DROP="$DROP_VAL"
                fi

                debug_log "[METRIC] cpu_ffmpeg=${CPU_FFMPEG}% load=${LOAD_AVG} temp=${CPU_TEMP}°C mem=${MEM_FREE}MB pwr=${PWR_STATUS} volt=${CORE_VOLT}V arm_clock=${ARM_CLOCK} usb_disc=${USB_DISC} usb_devs=${USB_DEVS} video_dev=${VIDEO_DEV} ttyacm=${TTYACM_DEV} usb_pwr_err=${USB_PWR_ERR} gw_ping=${PING_MS}ms gw_loss=${PING_LOSS}% rtt=${TCP_RTT}ms retrans=${RETRANS} speed=${FFMPEG_SPEED} fps=${FFMPEG_FPS} drop=${FFMPEG_DROP}"
            done
            ) &
            DEBUG_MON_PID=$!
        fi
        
        # Monitor ffmpeg and scan state
        # During streaming: tolerant detection (threshold=2) - 2 changes = scanning
        while kill -0 $FFMPEG_PID 2>/dev/null; do
            sleep $CHECK_INTERVAL
            
            if [ "$STREAM_MODE" = "on-lock" ]; then
                if ! should_stream 2; then
                    log "Сканер почав сканування, зупиняємо стрім..."
                    kill $FFMPEG_PID 2>/dev/null
                    wait $FFMPEG_PID 2>/dev/null
                    LAST_FFMPEG_EXIT=$?
                    break
                fi
            fi
        done
        
        if [ -n "$LAST_FFMPEG_EXIT" ]; then
            FFMPEG_EXIT=$LAST_FFMPEG_EXIT
            LAST_FFMPEG_EXIT=""
        else
            wait $FFMPEG_PID 2>/dev/null
            FFMPEG_EXIT=$?
        fi
        
        # Log disconnect reason for the analyzer
        if [ "$DEBUG_MODE" = "true" ]; then
            if [ "$FFMPEG_EXIT" -eq 143 ] || [ "$FFMPEG_EXIT" -eq 0 ]; then
                debug_log "[EVENT] disconnected (graceful — scanning stopped)"
            elif [ "$FFMPEG_EXIT" -ne 0 ]; then
                debug_log "[EVENT] disconnected (ffmpeg exited with code $FFMPEG_EXIT)"
            fi
        fi
        
        # Stop debug monitor
        if [ "$DEBUG_MODE" = "true" ] && [ -n "$DEBUG_MON_PID" ]; then
            kill $DEBUG_MON_PID 2>/dev/null
            wait $DEBUG_MON_PID 2>/dev/null
        fi
        
        # Log last ffmpeg stderr on disconnect
        if [ "$DEBUG_MODE" = "true" ] && [ -f "$DEBUG_RAW_FILE" ]; then
            debug_log "[EVENT] ffmpeg відключено, останні рядки stderr:"
            tail -c 4096 "$DEBUG_RAW_FILE" | tr '\r' '\n' | tail -n 10 | while read line; do
                debug_log "[FFMPEG] $line"
            done
            > "$DEBUG_RAW_FILE"
        fi
        
        log "Стрім відключено. Перепідключення через ${RECONNECT_DELAY}с..."
    else
        log "Сканер сканує, очікуємо захват... (перевірка знову через ${RECONNECT_DELAY}с)"
    fi
    
    sleep $RECONNECT_DELAY
done
