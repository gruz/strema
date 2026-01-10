#!/bin/bash
# Uninstall script for Forpost Stream service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Removing Forpost Stream services..."

# Source service manager for centralized service handling
source "$SCRIPT_DIR/scripts/service_manager.sh"
uninstall_all_services "$SCRIPT_DIR"

echo "Forpost Stream services removed."
