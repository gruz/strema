#!/bin/bash
# Update script for Forpost Stream
# Downloads and installs a new version from GitHub releases

set -e

GITHUB_REPO="gruz/strema"
REQUESTED_VERSION="$1"

# Determine installation directory
# When run via systemd-run, we need to find the actual installation
if [ -d "/home/rpidrone/strema" ]; then
    INSTALL_DIR="/home/rpidrone/strema"
elif [ -n "$SUDO_USER" ]; then
    ORIGINAL_HOME=$(eval echo ~$SUDO_USER)
    INSTALL_DIR="$ORIGINAL_HOME/strema"
else
    # Fallback: try to find strema directory
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

# Download release archive
ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$REQUESTED_VERSION/strema-$REQUESTED_VERSION.tar.gz"
CHECKSUM_URL="https://github.com/$GITHUB_REPO/releases/download/$REQUESTED_VERSION/checksums.txt"

echo ""
echo "Downloading $ARCHIVE_URL..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

if ! curl -fsSL -o "strema-$REQUESTED_VERSION.tar.gz" "$ARCHIVE_URL"; then
    echo "❌ Error: Failed to download release archive"
    rm -rf "$TMP_DIR"
    exit 1
fi

# Verify checksum
echo "Verifying checksum..."
if curl -fsSL -o checksums.txt "$CHECKSUM_URL" 2>/dev/null; then
    if sha256sum -c checksums.txt 2>/dev/null | grep -q "strema-$REQUESTED_VERSION.tar.gz: OK"; then
        echo "✅ Checksum verified"
    else
        echo "❌ Error: Checksum verification failed"
        rm -rf "$TMP_DIR"
        exit 1
    fi
else
    echo "⚠️  Warning: Could not download checksums, skipping verification"
fi

# Backup current config
echo ""
echo "Backing up configuration..."
if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
    cp "$INSTALL_DIR/config/stream.conf" "$TMP_DIR/stream.conf.backup"
    echo "✅ Config backed up"
else
    echo "⚠️  No config to backup"
fi

# Check if stream was running before stopping
STREAM_WAS_ACTIVE=false
if systemctl is-active forpost-stream 2>/dev/null | grep -q "active"; then
    STREAM_WAS_ACTIVE=true
    echo "Stream is currently active, will restart after update"
fi

# Stop services
echo ""
echo "Stopping services..."
systemctl stop forpost-stream 2>/dev/null || true
systemctl stop forpost-udp-proxy 2>/dev/null || true
systemctl stop forpost-stream-web 2>/dev/null || true

# Extract archive
echo ""
echo "Extracting new version..."
tar -xzf "strema-$REQUESTED_VERSION.tar.gz"

# Remove old installation (except config, logs, and .git)
echo "Removing old files..."
if [ -d "$INSTALL_DIR" ]; then
    # Keep config, logs, and .git directory (for development)
    mv "$INSTALL_DIR/config" "$TMP_DIR/config.backup" 2>/dev/null || true
    mv "$INSTALL_DIR/logs" "$TMP_DIR/logs.backup" 2>/dev/null || true
    mv "$INSTALL_DIR/.git" "$TMP_DIR/git.backup" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
fi

# Install new version
echo "Installing new version..."
mkdir -p "$(dirname "$INSTALL_DIR")"
mv strema "$INSTALL_DIR"

# Fix ownership to match installation directory owner
INSTALL_DIR_PARENT=$(dirname "$INSTALL_DIR")
INSTALL_DIR_OWNER=$(stat -c '%U:%G' "$INSTALL_DIR_PARENT" 2>/dev/null || echo "root:root")
if [ "$INSTALL_DIR_OWNER" != "root:root" ]; then
    echo "Setting ownership to $INSTALL_DIR_OWNER..."
    chown -R "$INSTALL_DIR_OWNER" "$INSTALL_DIR"
fi

# Restore config and logs
if [ -d "$TMP_DIR/config.backup" ]; then
    rm -rf "$INSTALL_DIR/config"
    mv "$TMP_DIR/config.backup" "$INSTALL_DIR/config"
    echo "✅ Config restored"
fi

if [ -d "$TMP_DIR/logs.backup" ]; then
    rm -rf "$INSTALL_DIR/logs"
    mv "$TMP_DIR/logs.backup" "$INSTALL_DIR/logs"
    echo "✅ Logs restored"
fi

# Restore .git directory if it existed (for development)
if [ -d "$TMP_DIR/git.backup" ]; then
    mv "$TMP_DIR/git.backup" "$INSTALL_DIR/.git"
    echo "✅ Git repository preserved"
    
    # Clean up git working directory to avoid uncommitted changes
    cd "$INSTALL_DIR"
    if [ -d ".git" ]; then
        # Reset any tracked files that were modified during update
        git reset --hard HEAD 2>/dev/null || true
        # Clean untracked files that match .gitignore
        git clean -fd 2>/dev/null || true
        echo "✅ Git working directory cleaned"
    fi
fi

# Restore specific config file if backed up separately
if [ -f "$TMP_DIR/stream.conf.backup" ]; then
    cp "$TMP_DIR/stream.conf.backup" "$INSTALL_DIR/config/stream.conf"
fi

# Set permissions
echo ""
echo "Setting permissions..."
chmod +x "$INSTALL_DIR/scripts/"*.sh
chmod +x "$INSTALL_DIR/web/web_config.py"

# Update systemd services
echo ""
echo "Updating systemd services..."
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/systemd/forpost-stream.service" > /etc/systemd/system/forpost-stream.service
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/systemd/forpost-stream-config.path" > /etc/systemd/system/forpost-stream-config.path
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/systemd/forpost-stream-web.service" > /etc/systemd/system/forpost-stream-web.service
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/systemd/forpost-stream-watchdog.service" > /etc/systemd/system/forpost-stream-watchdog.service
sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$INSTALL_DIR/systemd/forpost-udp-proxy.service" > /etc/systemd/system/forpost-udp-proxy.service
cp "$INSTALL_DIR/systemd/forpost-stream-restart.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/forpost-stream-autorestart.timer" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/forpost-stream-autorestart.service" /etc/systemd/system/
cp "$INSTALL_DIR/systemd/forpost-stream-watchdog.timer" /etc/systemd/system/
systemctl daemon-reload

# Start services
echo ""
echo "Starting services..."
systemctl start forpost-stream-web
systemctl start forpost-stream-config.path
systemctl start forpost-stream-watchdog.timer

# Restart stream if it was active before update
if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    echo "Restarting stream service (was active before update)..."
    systemctl start forpost-stream
fi

# Cleanup
cd /
rm -rf "$TMP_DIR"

echo ""
echo "=========================================="
echo "✅ Update complete!"
echo "=========================================="
echo ""
echo "Updated from $CURRENT_VERSION to $REQUESTED_VERSION"
echo ""
echo "Web interface: http://$(hostname -I | awk '{print $1}'):8081"
echo ""
