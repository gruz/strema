#!/bin/bash

# Shared function to detect RTSP server type and return appropriate transport
# Returns: "tcp" or "udp"
detect_rtsp_transport() {
    # Auto-detect RTSP server type and set appropriate transport
    # VLC RTSP server (cvlc) only supports UDP transport
    # Custom rtsp_server supports TCP transport
    if systemctl is-active rtsp-server >/dev/null 2>&1; then
        RTSP_CMD=$(systemctl show -p ExecStart --value rtsp-server 2>/dev/null | grep -o 'path=[^ ]*' | cut -d= -f2)
        if echo "$RTSP_CMD" | grep -q "cvlc\|vlc"; then
            echo "udp"
        elif echo "$RTSP_CMD" | grep -q "rtsp_server"; then
            echo "tcp"
        else
            echo "tcp"
        fi
    else
        echo "tcp"
    fi
}

# If script is sourced, just define the function
# If executed directly, call the function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    detect_rtsp_transport
fi
