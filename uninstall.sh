#!/bin/bash
# Uninstall script for Forpost Stream service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Removing Forpost Stream services..."

# Source service manager for centralized service handling
if [ ! -f "$SCRIPT_DIR/scripts/service_manager.sh" ] && [ -f "$SCRIPT_DIR/scripts/service_manager.sh.template" ]; then
    cp "$SCRIPT_DIR/scripts/service_manager.sh.template" "$SCRIPT_DIR/scripts/service_manager.sh"
fi
source "$SCRIPT_DIR/scripts/service_manager.sh"
cleanup_old_services "$SCRIPT_DIR"
uninstall_all_services "$SCRIPT_DIR"

echo "Forpost Stream services removed."
