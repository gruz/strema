#!/bin/bash
# Fix permissions for Forpost Stream project
# Ensures consistent ownership and permissions across all files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "Fixing permissions for Forpost Stream..."

# Determine the correct owner (user who owns the project directory)
PROJECT_OWNER=$(stat -c '%U:%G' "$PROJECT_ROOT" 2>/dev/null || echo "rpidrone:rpidrone")

echo "Project owner: $PROJECT_OWNER"
echo "Project root: $PROJECT_ROOT"

# Fix ownership of project files
echo "Setting ownership of project files..."
chown -R "$PROJECT_OWNER" "$PROJECT_ROOT"

# Fix permissions for scripts (executable)
echo "Setting executable permissions on scripts..."
chmod +x "$PROJECT_ROOT/scripts/"*.sh
chmod +x "$PROJECT_ROOT/web/web_config.py"
chmod +x "$PROJECT_ROOT/update.sh" 2>/dev/null || true

# Fix permissions for config and logs (readable/writable)
echo "Setting permissions on config and logs..."
chmod 644 "$PROJECT_ROOT/config/"*
chmod 755 "$PROJECT_ROOT/config"
chmod 644 "$PROJECT_ROOT/logs/"* 2>/dev/null || true
chmod 755 "$PROJECT_ROOT/logs"

# Fix permissions for temporary files
# NOTE: This is only needed for migration from old versions.
# New code (start_stream.sh, update_dynamic_overlay.sh, update_frequency.sh) 
# already creates files with correct permissions (chmod 666) on every write.
echo "Fixing temporary files (migration from old versions)..."
if [ -f "/tmp/dzyga_dynamic_overlay.txt" ]; then
    chown www-data:www-data /tmp/dzyga_dynamic_overlay.txt
    chmod 666 /tmp/dzyga_dynamic_overlay.txt
fi

if [ -f "/tmp/dzyga_last_freq_dynamic.txt" ]; then
    chown www-data:www-data /tmp/dzyga_last_freq_dynamic.txt
    chmod 666 /tmp/dzyga_last_freq_dynamic.txt
fi

if [ -f "/tmp/dzyga_freq.txt" ]; then
    chown www-data:www-data /tmp/dzyga_freq.txt
    chmod 666 /tmp/dzyga_freq.txt
fi

if [ -f "/tmp/get_frequency.lock" ]; then
    chown root:root /tmp/get_frequency.lock
    chmod 666 /tmp/get_frequency.lock
fi

if [ -f "/tmp/dzyga_scanning_state.txt" ]; then
    chown www-data:www-data /tmp/dzyga_scanning_state.txt
    chmod 666 /tmp/dzyga_scanning_state.txt
fi

echo "✅ Permissions fixed successfully!"
