#!/bin/bash
# Simplified update script for Forpost Stream
# Uses uninstall + install approach for simplicity and reliability

set -e

GITHUB_REPO="gruz/strema"
REQUESTED_VERSION="$1"

# Determine installation directory
if [ -d "/home/rpidrone/strema" ]; then
    INSTALL_DIR="/home/rpidrone/strema"
elif [ -n "$SUDO_USER" ]; then
    ORIGINAL_HOME=$(eval echo ~$SUDO_USER)
    INSTALL_DIR="$ORIGINAL_HOME/strema"
else
    for user_home in /home/*; do
        if [ -d "$user_home/strema" ]; then
            INSTALL_DIR="$user_home/strema"
            break
        fi
    done
    
    if [ -z "$INSTALL_DIR" ]; then
        echo "❌ Error: Could not find strema installation directory"
        exit 1
    fi
fi

if [ -z "$REQUESTED_VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 v0.1.1"
    exit 1
fi

# Auto-elevate with sudo if not root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

echo "=========================================="
echo "Updating Forpost Stream to $REQUESTED_VERSION"
echo "=========================================="

# Get current version
CURRENT_VERSION="unknown"
if [ -f "$INSTALL_DIR/VERSION" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/VERSION")
fi

echo "Current version: $CURRENT_VERSION"
echo "Target version: $REQUESTED_VERSION"

# Create temporary directory for backup
TMP_BACKUP=$(mktemp -d)
trap "rm -rf $TMP_BACKUP" EXIT

# Backup configuration
echo ""
echo "Backing up configuration..."
if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
    cp "$INSTALL_DIR/config/stream.conf" "$TMP_BACKUP/stream.conf"
    echo "✅ Config backed up to $TMP_BACKUP/stream.conf"
else
    echo "⚠️  No config to backup"
fi

# Backup logs directory
if [ -d "$INSTALL_DIR/logs" ]; then
    cp -r "$INSTALL_DIR/logs" "$TMP_BACKUP/logs"
    echo "✅ Logs backed up"
fi

# Check if stream was running
STREAM_WAS_ACTIVE=false
if systemctl is-active forpost-stream 2>/dev/null | grep -q "active"; then
    STREAM_WAS_ACTIVE=true
    echo "✅ Stream service is active (will restart after update)"
fi

# Download new version
echo ""
echo "Downloading version $REQUESTED_VERSION..."
ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$REQUESTED_VERSION/strema-$REQUESTED_VERSION.tar.gz"
CHECKSUM_URL="https://github.com/$GITHUB_REPO/releases/download/$REQUESTED_VERSION/checksums.txt"

TMP_DOWNLOAD=$(mktemp -d)
cd "$TMP_DOWNLOAD"

if ! curl -fsSL -o "strema-$REQUESTED_VERSION.tar.gz" "$ARCHIVE_URL"; then
    echo "❌ Error: Failed to download release archive"
    exit 1
fi

# Verify checksum
echo "Verifying checksum..."
if curl -fsSL -o checksums.txt "$CHECKSUM_URL" 2>/dev/null; then
    if sha256sum -c checksums.txt 2>/dev/null | grep -q "strema-$REQUESTED_VERSION.tar.gz: OK"; then
        echo "✅ Checksum verified"
    else
        echo "❌ Error: Checksum verification failed"
        exit 1
    fi
else
    echo "⚠️  Warning: Could not download checksums, skipping verification"
fi

# Extract to temporary location
echo "Extracting archive..."
tar -xzf "strema-$REQUESTED_VERSION.tar.gz"
NEW_VERSION_DIR="$TMP_DOWNLOAD/strema"

# Uninstall old version
echo ""
echo "Uninstalling old version..."
if [ -f "$INSTALL_DIR/uninstall.sh" ]; then
    bash "$INSTALL_DIR/uninstall.sh"
else
    echo "⚠️  uninstall.sh not found, stopping services manually..."
    systemctl stop forpost-stream 2>/dev/null || true
    systemctl stop forpost-udp-proxy 2>/dev/null || true
    systemctl stop forpost-stream-web 2>/dev/null || true
    systemctl stop forpost-stream-config.path 2>/dev/null || true
    systemctl stop forpost-stream-watchdog.timer 2>/dev/null || true
    systemctl stop forpost-dzyga-monitor.timer 2>/dev/null || true
fi

# Remove old installation directory
echo "Removing old installation..."
rm -rf "$INSTALL_DIR"

# Move new version to installation directory
echo "Installing new version..."
mkdir -p "$(dirname "$INSTALL_DIR")"
mv "$NEW_VERSION_DIR" "$INSTALL_DIR"

# Restore configuration
if [ -f "$TMP_BACKUP/stream.conf" ]; then
    echo "Restoring configuration..."
    cp "$TMP_BACKUP/stream.conf" "$INSTALL_DIR/config/stream.conf"
    echo "✅ Config restored"
fi

# Restore logs
if [ -d "$TMP_BACKUP/logs" ]; then
    echo "Restoring logs..."
    rm -rf "$INSTALL_DIR/logs"
    cp -r "$TMP_BACKUP/logs" "$INSTALL_DIR/logs"
    echo "✅ Logs restored"
fi

# Run installation
echo ""
echo "Running installation..."
cd "$INSTALL_DIR"
bash "$INSTALL_DIR/install.sh"

# Trigger config change handler to restore auto-restart timer and other settings
echo ""
echo "Restoring configuration-dependent services..."
if [ -f "$INSTALL_DIR/scripts/handle_config_change.sh" ]; then
    # Force re-apply all settings by removing snapshot
    rm -f "$INSTALL_DIR/config/.stream.conf.snapshot"
    bash "$INSTALL_DIR/scripts/handle_config_change.sh"
    echo "✅ Configuration settings applied"
fi

# Restart stream if it was active
if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    echo ""
    echo "Restarting stream service..."
    
    # Check if UDP proxy should be started
    CONFIG_FILE="$INSTALL_DIR/config/stream.conf"
    if [ -f "$CONFIG_FILE" ]; then
        USE_UDP_PROXY=$(grep "^USE_UDP_PROXY=" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "true")
        
        if [ "$USE_UDP_PROXY" = "true" ]; then
            systemctl start forpost-udp-proxy 2>/dev/null || true
        fi
    fi
    
    systemctl start forpost-stream
    echo "✅ Stream service restarted"
fi

# Cleanup download directory
cd /
rm -rf "$TMP_DOWNLOAD"

echo ""
echo "=========================================="
echo "✅ Update complete!"
echo "=========================================="
echo ""
echo "Updated from $CURRENT_VERSION to $REQUESTED_VERSION"
echo ""
echo "Web interface: http://$(hostname -I | awk '{print $1}'):8081"
echo ""
