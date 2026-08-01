#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service
#
# Usage:
#   Remote install:    curl -fsSL https://raw.githubusercontent.com/gruz/strema-release/master/install.sh | bash
#   Specific version:  curl -fsSL https://raw.githubusercontent.com/gruz/strema-release/master/install.sh | bash -s v0.1.0
#   Local install:     ./install.sh

set -e

# Move to a safe directory early. When run via `curl | bash` the current
# directory is typically ~/strema, which gets deleted later in this script
# (sudo rm -rf "$INSTALL_DIR"). If we stay there, every subsequent getcwd()
# call fails with "shell-init: error retrieving current directory".
cd /tmp

REPO_BASE="strema-release"
GITHUB_REPO="gruz/$REPO_BASE"
# Release archives (built by scripts/build_binaries.sh) extract to a folder
# named "strema" regardless of the repo name. GitHub source archives instead
# use the "<repo>-<branch>" naming convention.
RELEASE_DIR_NAME="strema"

# Check GitHub API rate limit and print a helpful message if exhausted.
# GitHub unauthenticated API is limited to 60 requests/hour per IP. When the
# limit is hit, the API returns HTTP 403 with X-RateLimit-Remaining: 0.
# Sets RATE_LIMITED=1 if exhausted, otherwise leaves it unset.
# Args: $1 = curl HTTP status code, $2 = response headers (for reset time).
check_rate_limit() {
    local status="$1"
    local headers="$2"
    RATE_LIMITED=""
    if [ "$status" = "403" ]; then
        local remaining
        remaining=$(echo "$headers" | grep -i '^x-ratelimit-remaining:' | awk '{print $2}' | tr -d '\r')
        if [ "$remaining" = "0" ]; then
            local reset_ts reset_in
            reset_ts=$(echo "$headers" | grep -i '^x-ratelimit-reset:' | awk '{print $2}' | tr -d '\r')
            if [ -n "$reset_ts" ]; then
                reset_in=$(( (reset_ts - $(date +%s)) / 60 ))
                if [ "$reset_in" -lt 1 ]; then reset_in=1; fi
                RATE_LIMIT_MSG="❌ GitHub API rate limit exhausted (60 requests/hour for unauthenticated requests).
   Limit resets in ~${reset_in} minutes.
   Options:
     1. Wait and retry
     2. Install a specific version (bypasses the API):
        curl -fsSL https://raw.githubusercontent.com/gruz/strema-release/master/install.sh | bash -s v0.0.1-beta.05"
            else
                RATE_LIMIT_MSG="❌ GitHub API rate limit exhausted. Please wait and retry."
            fi
            RATE_LIMITED=1
        fi
    fi
}

# Helper to get the latest stable release tag from GitHub (no jq required).
# If no stable release exists (only pre-releases/betas), falls back to the
# most recent pre-release. Sets LATEST_TAG global (empty if no releases found
# OR if rate-limited). Sets RATE_LIMITED=1 and RATE_LIMIT_MSG if rate-limited.
# Must be called directly (NOT via $()), so that globals propagate.
get_latest_release() {
    local status headers body TAG
    LATEST_TAG=""
    RATE_LIMITED=""
    RATE_LIMIT_MSG=""

    # Try stable "latest" release first (excludes pre-releases)
    headers=$(curl -sSL -D - -o /tmp/strema_api_body \
        "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null) || true
    status=$(echo "$headers" | head -1 | awk '{print $2}')
    check_rate_limit "$status" "$headers"
    if [ -n "$RATE_LIMITED" ]; then
        rm -f /tmp/strema_api_body
        return
    fi
    body=$(cat /tmp/strema_api_body 2>/dev/null)
    TAG=$(echo "$body" | grep -o '"tag_name": "[^"]*"' | head -1 \
        | sed 's/.*"tag_name": "//;s/"$//')
    rm -f /tmp/strema_api_body
    if [ -n "$TAG" ]; then
        LATEST_TAG="$TAG"
        return
    fi

    # No stable release — fall back to the most recent pre-release.
    # The /releases endpoint lists all releases (including pre-releases),
    # most recent first.
    headers=$(curl -sSL -D - -o /tmp/strema_api_body \
        "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=1" 2>/dev/null) || true
    status=$(echo "$headers" | head -1 | awk '{print $2}')
    check_rate_limit "$status" "$headers"
    if [ -n "$RATE_LIMITED" ]; then
        rm -f /tmp/strema_api_body
        return
    fi
    body=$(cat /tmp/strema_api_body 2>/dev/null)
    TAG=$(echo "$body" | grep -o '"tag_name": "[^"]*"' | head -1 \
        | sed 's/.*"tag_name": "//;s/"$//')
    rm -f /tmp/strema_api_body
    LATEST_TAG="$TAG"
}

# Download and extract the strema archive into the current directory.
# Sets SOURCE_DIR variable. Exits on failure.
download_strema() {
    if [ "$VERSION" = "latest" ]; then
        get_latest_release
        if [ -n "$RATE_LIMITED" ]; then
            echo "$RATE_LIMIT_MSG"
            rm -rf "$TMP_DIR"
            exit 1
        fi
        if [ -z "$LATEST_TAG" ]; then
            echo "❌ No releases found in $GITHUB_REPO."
            echo "   This is unexpected — please report this issue."
            rm -rf "$TMP_DIR"
            exit 1
        fi
        echo "Downloading latest release $LATEST_TAG..."
        local ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_TAG/strema-$LATEST_TAG.tar.gz"
        curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
            echo "❌ Download failed"
            rm -rf "$TMP_DIR"
            exit 1
        }
        tar -xzf strema.tar.gz
        SOURCE_DIR="$RELEASE_DIR_NAME"
    elif [ "$VERSION" = "master" ]; then
        echo "❌ 'master' is not available for remote installation from $GITHUB_REPO."
        echo "   The release repo only contains release archives, not source code."
        echo "   Use 'latest' or a specific version (e.g. v0.0.1-beta.05)."
        rm -rf "$TMP_DIR"
        exit 1
    else
        echo "Downloading release $VERSION..."
        local ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/strema-$VERSION.tar.gz"
        curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
            echo "❌ Download failed. Check if release $VERSION exists"
            rm -rf "$TMP_DIR"
            exit 1
        }
        tar -xzf strema.tar.gz
        SOURCE_DIR="$RELEASE_DIR_NAME"
    fi
}

VERSION="${1:-latest}"
[ -z "$VERSION" ] && VERSION="latest"

# Local install mode: use the source tree already present (e.g. pushed by debug_deploy.sh)
LOCAL_INSTALL=false
if [ "$VERSION" = "local" ]; then
    LOCAL_INSTALL=true
    VERSION="local"
fi

echo "=========================================="
echo "Installing Forpost Stream"
echo "=========================================="

# Determine real user (handle both 'bash' and 'sudo bash' cases)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(eval echo ~$SUDO_USER)
    echo "⚠️  Detected sudo - installing for user: $REAL_USER"
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

# Check if user has sudo access
if ! sudo -n true 2>/dev/null; then
    echo "❌ Error: This script requires sudo access"
    echo "   Please ensure your user has sudo privileges"
    exit 1
fi

# Stop and remove all old forpost services FIRST
echo ""
echo "[1/5] Stopping and removing old services..."
STREAM_WAS_ACTIVE=false
UDP_PROXY_WAS_ACTIVE=false
STREAM_STATE=$(sudo systemctl is-active forpost-stream 2>/dev/null || true)
UDP_STATE=$(sudo systemctl is-active forpost-udp-proxy 2>/dev/null || true)
if [ "$STREAM_STATE" = "active" ] || [ "$STREAM_STATE" = "activating" ] || [ "$STREAM_STATE" = "reloading" ] || [ -f /tmp/.forpost_stream_was_active ]; then
    STREAM_WAS_ACTIVE=true
    echo "📝 Stream service is running - will restart after update"
fi
if [ "$UDP_STATE" = "active" ] || [ "$UDP_STATE" = "activating" ] || [ "$UDP_STATE" = "reloading" ] || [ -f /tmp/.forpost_udp_proxy_was_active ]; then
    UDP_PROXY_WAS_ACTIVE=true
    echo "📝 UDP proxy is running - will restart after update"
fi

# Consume the marker files immediately. They are created by uninstall.sh to
# carry service state across an uninstall→install cycle. If we leave them and
# the install fails (set -e), a later install would see a stale marker and
# start the stream even though the user had stopped it.
# NOTE: uninstall.sh runs as root (auto-elevates), so the markers are root-
# owned. We need sudo to remove them.
sudo rm -f /tmp/.forpost_stream_was_active /tmp/.forpost_udp_proxy_was_active 2>/dev/null || true

# Stop all services except web interface (to allow online updates to complete)
for service in forpost-stream forpost-udp-proxy forpost-stream-autorestart.timer \
               forpost-stream-config.path forpost-stream-watchdog.timer \
               forpost-power-settings; do
    sudo systemctl stop "$service" 2>/dev/null || true
    sudo systemctl disable "$service" 2>/dev/null || true
done

# Remove old service files (web will be updated but not stopped)
for service_file in /etc/systemd/system/forpost-*.service /etc/systemd/system/forpost-*.timer /etc/systemd/system/forpost-*.path; do
    [ -f "$service_file" ] || continue
    service_name=$(basename "$service_file")
    # Skip web service to allow online update to complete
    if [ "$service_name" != "forpost-stream-web.service" ]; then
        sudo rm -f "$service_file"
    fi
done

sudo systemctl daemon-reload

# Now analyze what we have and what to do
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# In local install mode we use the source tree already on the device
if [ "$LOCAL_INSTALL" = "true" ]; then
    INSTALL_DIR="$SCRIPT_DIR"
fi

OLD_INSTALL_DIR="$REAL_HOME/FORPOST/strema"
NEW_INSTALL_DIR="$REAL_HOME/strema"

# Check for migration
if [ -d "$OLD_INSTALL_DIR" ] && [ ! -d "$NEW_INSTALL_DIR" ]; then
    echo ""
    echo "⚠️  Found old installation at: $OLD_INSTALL_DIR"
    echo "   Migrating to new location: $NEW_INSTALL_DIR"
    mv "$OLD_INSTALL_DIR" "$NEW_INSTALL_DIR"
    echo "✅ Migration complete"
    echo "   Note: Old directory $REAL_HOME/FORPOST still exists (may contain other files)"
    INSTALL_DIR="$NEW_INSTALL_DIR"
elif [ -d "$OLD_INSTALL_DIR" ] && [ -d "$NEW_INSTALL_DIR" ]; then
    echo "⚠️  Found installations in both locations:"
    echo "   Old: $OLD_INSTALL_DIR"
    echo "   New: $NEW_INSTALL_DIR"
    echo "   Using new location. You can manually remove old one."
    INSTALL_DIR="$NEW_INSTALL_DIR"
else
    INSTALL_DIR="$NEW_INSTALL_DIR"
fi

# Check installation type and update files
if [ -d "$SCRIPT_DIR/.git" ] && [ "$LOCAL_INSTALL" != "true" ]; then
    # Git installation
    echo ""
    echo "📁 Git installation detected"
    
    if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
        echo "⚠️  Warning: Git installation is at $SCRIPT_DIR"
        echo "   Expected location: $INSTALL_DIR"
        echo "   Continuing with current location..."
        INSTALL_DIR="$SCRIPT_DIR"
    fi
    
    cd "$INSTALL_DIR"
    
    # Stash local changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "💾 Stashing local changes..."
        git stash push -m "Auto-stash before install.sh update $(date +%Y%m%d_%H%M%S)"
    fi
    
    # Update from git
    echo "Updating from git..."
    git fetch origin
    
    if [ "$VERSION" = "latest" ]; then
        echo "Pulling latest from master..."
        git reset --hard origin/master
    else
        echo "Checking out version $VERSION..."
        git fetch --tags
        git reset --hard "$VERSION"
    fi
    
    echo "✅ Git update complete"
    
elif [ "$LOCAL_INSTALL" != "true" ]; then
    # Remote installation (fresh or update)
    if [ -d "$INSTALL_DIR" ]; then
        echo ""
        echo "🌐 Remote installation - updating"
    else
        echo ""
        echo "🌐 Remote installation - fresh install"
    fi
    
    # Backup config if it exists (safe to call even when file is missing)
    if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
        TMP_BACKUP="/tmp/strema_config_backup_$$"
        cp "$INSTALL_DIR/config/stream.conf" "$TMP_BACKUP"
    fi
    
    # Download and extract
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    download_strema
    
    # Replace / install files
    sudo rm -rf "$INSTALL_DIR"
    mkdir -p "$REAL_HOME"
    mv "$SOURCE_DIR" "$INSTALL_DIR"
    
    # Restore config if backup was created
    if [ -n "$TMP_BACKUP" ] && [ -f "$TMP_BACKUP" ]; then
        cp "$TMP_BACKUP" "$INSTALL_DIR/config/stream.conf"
        rm -f "$TMP_BACKUP"
    fi
    
    cd "$REAL_HOME"
    rm -rf "$TMP_DIR"
    echo "✅ Download complete"
fi

# Create/update VERSION file (not tracked in git, so must be generated)
if [ "$VERSION" = "master" ]; then
    echo "master" > "$INSTALL_DIR/VERSION"
elif [ "$VERSION" = "latest" ]; then
    # Reuse LATEST_TAG from download_strema if available (remote install);
    # otherwise query the API (git install path).
    if [ -z "$LATEST_TAG" ]; then
        get_latest_release
    fi
    if [ -n "$LATEST_TAG" ]; then
        echo "${LATEST_TAG#v}" > "$INSTALL_DIR/VERSION"
    else
        # Could not determine (rate limited or no releases) — use "unknown"
        # rather than failing the whole install after a successful download.
        echo "unknown" > "$INSTALL_DIR/VERSION"
    fi
else
    # Specific version like v0.1.0 - strip 'v' prefix
    echo "${VERSION#v}" > "$INSTALL_DIR/VERSION"
fi

SCRIPT_DIR="$INSTALL_DIR"

# install.sh already restores stream.conf from backup above; make sure it
# is owned by the real user because the web service (User=rpidrone) needs
# write access and this script runs as root during remote updates.
if [ -f "$SCRIPT_DIR/config/stream.conf" ] && [ -n "$REAL_USER" ]; then
    chown "$REAL_USER:" "$SCRIPT_DIR/config/stream.conf" 2>/dev/null || true
fi

# Install dependencies (requires sudo)
echo ""
echo "[2/5] Installing system dependencies..."
sudo apt-get update -qq || echo "⚠️  apt update failed, continuing..."
sudo apt-get install -y ffmpeg strace python3-flask iproute2 jq libpython3.11

# Grant strace the CAP_SYS_PTRACE capability so the stream service (running
# as a non-root user) can attach to the root-owned dzyga process to read
# frequency via strace. Without this, get_frequency would need sudo on every
# call (every 2 seconds), flooding the journal with sudo log entries.
# libcap2-bin provides setcap/getcap; install silently if missing.
sudo dpkg -s libcap2-bin >/dev/null 2>&1 || sudo apt-get install -y libcap2-bin 2>/dev/null || true
sudo setcap cap_sys_ptrace+ep /usr/bin/strace 2>/dev/null || echo "⚠️  Could not set CAP_SYS_PTRACE on strace (frequency detection may need sudo)"

# Prepare project files
echo ""
echo "[3/5] Preparing project files..."
chmod +x "$SCRIPT_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/"*.py 2>/dev/null || true
chmod +x "$SCRIPT_DIR/web/"web_config.py 2>/dev/null || true
# Remove any leftover source / debug artifacts from closed releases
rm -rf "$SCRIPT_DIR/.git" 2>/dev/null || true
mkdir -p "$SCRIPT_DIR/logs"
# Migrate log ownership: stream and udp-proxy services now run as rpidrone
# (previously as root), so old root-owned log files must be re-owned to let
# the services append to and rotate them.
if [ -n "$REAL_USER" ]; then
    sudo chown -R "$REAL_USER:$REAL_USER" "$SCRIPT_DIR/logs" 2>/dev/null || true
fi

# Clean up old temporary files from previous versions (migration)
sudo rm -f /tmp/dzyga_* 2>/dev/null || true
# Remove dzyga MD5 cache so get_frequency.sh recalculates it on first call
rm -f /tmp/dzyga.md5 2>/dev/null || true

echo "✅ Files ready"

# Install systemd services
echo ""
echo "[4/5] Installing systemd services..."
if [ ! -d "$SCRIPT_DIR/systemd" ] || [ -z "$(ls -A "$SCRIPT_DIR/systemd" 2>/dev/null)" ]; then
    echo "❌ Error: No systemd unit files found in $SCRIPT_DIR/systemd/"
    echo "   The downloaded archive appears to be incomplete."
    echo "   Try specifying a version explicitly:"
    echo "     curl -fsSL https://raw.githubusercontent.com/gruz/strema-release/master/install.sh | bash -s v0.0.1-beta.05"
    exit 1
fi
for file in "$SCRIPT_DIR/systemd"/*; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    if grep -q "__INSTALL_DIR__" "$file"; then
        sudo sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$file" > "/tmp/$name"
        sudo mv "/tmp/$name" "/etc/systemd/system/$name"
    else
        sudo cp "$file" "/etc/systemd/system/$name"
    fi
done

sudo systemctl daemon-reload

# Start services
echo ""
echo "[5/5] Starting services..."

# Always start these services
sudo systemctl enable --now forpost-stream-web
sudo systemctl enable --now forpost-stream-config.path
sudo systemctl enable --now forpost-stream-watchdog.timer

# Enable on boot only (don't start now)
sudo systemctl enable forpost-power-settings 2>/dev/null || true

# Disable by default (controlled via web UI)
sudo systemctl disable forpost-stream 2>/dev/null || true
sudo systemctl disable forpost-udp-proxy 2>/dev/null || true
sudo systemctl disable forpost-stream-autorestart.timer 2>/dev/null || true

# Apply configuration settings (autostart, auto-restart, etc.)
# Remove snapshot so handle_config_change.sh re-applies all settings from config
rm -f /tmp/forpost_config_snapshot.conf 2>/dev/null || true
if [ -f "$SCRIPT_DIR/config/stream.conf" ]; then
    echo "Applying configuration settings..."
    if [ -x "$SCRIPT_DIR/scripts/handle_config_change" ]; then
        "$SCRIPT_DIR/scripts/handle_config_change" 2>/dev/null || true
    else
        python3 "$SCRIPT_DIR/scripts/handle_config_change.py" 2>/dev/null || true
    fi
fi

# Restart services if they were running before update
if [ "$UDP_PROXY_WAS_ACTIVE" = "true" ]; then
    echo "Restarting UDP proxy service..."
    sudo systemctl start forpost-udp-proxy || true
fi
sudo rm -f /tmp/.forpost_udp_proxy_was_active 2>/dev/null || true

if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    echo "Restarting stream service..."
    sudo systemctl start forpost-stream || true
    # Give the service a moment to become active; if it failed, the web UI can be used to start it
    sleep 2
    if ! sudo systemctl is-active --quiet forpost-stream 2>/dev/null; then
        echo "⚠️  Stream service did not become active after start. It can be started manually from the web UI."
    fi
fi
sudo rm -f /tmp/.forpost_stream_was_active 2>/dev/null || true

# Restart web service to pick up new code
sudo systemctl restart forpost-stream-web

echo "✅ Services configured"

# Show info
echo ""
echo "=========================================="
echo "[6/6] Installation complete!"
echo "=========================================="
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo "🌐 Web Interface: http://$IP_ADDRESS:8081"
echo ""
echo "Useful commands:"
echo "  sudo systemctl status forpost-stream-web"
echo "  sudo systemctl status forpost-stream"
echo "  tail -f $SCRIPT_DIR/logs/stream.log"
echo ""

# Cleanup debug access after a closed-source install
cleanup_debug_access() {
    local ssh_dir="$REAL_HOME/.ssh"
    if [ -f "$ssh_dir/strema-debug" ] || [ -f "$ssh_dir/strema-debug.pub" ]; then
        echo "🔒 Removing temporary debug SSH keys..."
        rm -f "$ssh_dir/strema-debug" "$ssh_dir/strema-debug.pub"
    fi
    if [ -f "$ssh_dir/known_hosts" ]; then
        if grep -q "github.com" "$ssh_dir/known_hosts" 2>/dev/null; then
            echo "🔒 Removing github.com from known_hosts..."
            sed -i '/github.com/d' "$ssh_dir/known_hosts"
        fi
    fi
}

cleanup_debug_access
