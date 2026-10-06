#!/bin/bash
# Installation script for Forpost Stream
# Installs dependencies and configures systemd service
#
# Usage:
#   Remote install:    curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash
#   Specific version:  curl -fsSL https://raw.githubusercontent.com/gruz/strema/master/install.sh | bash -s v0.1.0
#   Local install:     ./install.sh

set -e

# Resolve the script's own directory to an ABSOLUTE path before any cd.
# We need this later (e.g. for local install mode), but BASH_SOURCE[0] may
# be a relative path (like "./strema/install.sh"). Once we `cd /tmp` below,
# that relative path would no longer resolve, so capture it now.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Move to a safe directory early. When run via `curl | bash` the current
# directory is typically ~/strema, which gets deleted later in this script
# (sudo rm -rf "$INSTALL_DIR"). If we stay there, every subsequent getcwd()
# call fails with "shell-init: error retrieving current directory".
cd /tmp

REPO_BASE="strema"
GITHUB_REPO="gruz/$REPO_BASE"
# Release archives (built by tools/build_binaries.sh) extract to a folder
# named "strema" regardless of the repo name. GitHub source archives instead
# use the "<repo>-<branch>" naming convention.
RELEASE_DIR_NAME="strema"

# dzyga/dzyga_web are third-party vendor binaries, not part of the strema
# codebase. Canonical builds are published as release assets in the public
# repo $DZYGA_DIST_REPO — the installer always takes the LATEST release, so
# new vendor builds ship independently of strema releases. The SHA256SUMS.txt
# asset of that release is both the canonical-version reference (compared
# against the on-device binary) and the download integrity check.
DZYGA_DIST_REPO="gruz/strema-dist"
DZYGA_DIST_BASE="https://github.com/$DZYGA_DIST_REPO/releases/latest/download"
FORPOST_DIR="/home/rpidrone/FORPOST"

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
        curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/master/install.sh | bash -s v0.0.1-beta.05"
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
    elif [ -f "$VERSION" ]; then
        # Install from a local archive (e.g. built via build_binaries.sh / build_in_docker.sh)
        echo "Installing from local archive: $VERSION"
        cp "$VERSION" strema.tar.gz
        tar -xzf strema.tar.gz
        SOURCE_DIR="$RELEASE_DIR_NAME"
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

# Local install mode: use the source tree already present (e.g. pushed by deploy.sh dev/test)
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

# Install system dependencies BEFORE touching services — a package failure
# here aborts the install while everything is still running, instead of
# stranding the device half-updated with services stopped.
echo ""
echo "[1/5] Installing system dependencies..."
sudo apt-get update -qq || echo "⚠️  apt update failed, continuing..."
sudo apt-get install -y ffmpeg strace python3-flask python3-markdown iproute2 libpython3.11 inotify-tools python3-grpcio python3-protobuf v4l-utils sqlite3

# VPN tooling used by the web UI and fleet discovery. All packages are
# mandatory — a failure aborts the install (still before services are
# touched) so a missing dependency is a loud error, not a silent gap.
# The WireGuard kernel module is in-tree since 5.6, so wireguard-tools (wg,
# wg-quick) is all we need.
sudo apt-get install -y wireguard-tools
# tailscale is only packaged in newer Debian releases; fall back to the
# official installer (adds their apt repo) on older ones.
if ! command -v tailscale >/dev/null 2>&1; then
    sudo apt-get install -y tailscale \
        || curl -fsSL https://tailscale.com/install.sh | sudo sh
fi
sudo systemctl enable --now tailscaled

# Grant strace the CAP_SYS_PTRACE capability so the stream service (running
# as a non-root user) can attach to the root-owned dzyga process to read
# frequency via strace. Without this, get_frequency would need sudo on every
# call (every 2 seconds), flooding the journal with sudo log entries.
# libcap2-bin provides setcap/getcap; install silently if missing.
sudo dpkg -s libcap2-bin >/dev/null 2>&1 || sudo apt-get install -y libcap2-bin
sudo setcap cap_sys_ptrace+ep /usr/bin/strace 2>/dev/null || echo "⚠️  Could not set CAP_SYS_PTRACE on strace (frequency detection may need sudo)"

# Stop and remove all old forpost services FIRST
echo ""
echo "[2/5] Stopping and removing old services..."
STREAM_WAS_ACTIVE=false
STREAM_STATE=$(sudo systemctl is-active forpost-stream 2>/dev/null || true)
if [ "$STREAM_STATE" = "active" ] || [ "$STREAM_STATE" = "activating" ] || [ "$STREAM_STATE" = "reloading" ] || [ -f /tmp/.strema_stream_was_active ]; then
    STREAM_WAS_ACTIVE=true
    echo "📝 Stream service is running - will restart after update"
fi

# Consume the marker files immediately. They are created by uninstall.sh to
# carry service state across an uninstall→install cycle. If we leave them and
# the install fails (set -e), a later install would see a stale marker and
# start the stream even though the user had stopped it.
# NOTE: uninstall.sh runs as root (auto-elevates), so the markers are root-
# owned. We need sudo to remove them.
sudo rm -f /tmp/.strema_stream_was_active /tmp/.strema_udp_proxy_was_active 2>/dev/null || true

# Stop all services except web interface (to allow online updates to complete)
for service in forpost-stream forpost-udp-proxy forpost-stream-autorestart.timer \
               forpost-stream-config.path forpost-stream-watchdog.timer \
               forpost-power-settings forpost-mediamtx forpost-capture; do
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

# --- Update hygiene: artifacts left behind by older versions -----------
# Drop-in directories for units that were renamed or removed — the glob
# above only deletes files, not <unit>.d directories.
for dropin in /etc/systemd/system/forpost-*.service.d /etc/systemd/system/forpost-*.timer.d; do
    [ -d "$dropin" ] || continue
    sudo rm -rf "$dropin"
done
# Orphaned wants/requires symlinks: `systemctl disable` only removes
# symlinks for units it can still load; once a unit file is gone they stay
# behind and keep the unit visible as "not-found".
sudo find /etc/systemd/system -type l \( -path '*.wants/*' -o -path '*.requires/*' \) \
    -name 'forpost-*' -delete 2>/dev/null || true
# Phantom masks and residual failed-state records from removed units —
# a mask symlink at the unit path was deleted above, but units masked by
# very old versions may also linger in systemd's runtime state.
sudo systemctl unmask 'forpost-*' 2>/dev/null || true
sudo systemctl reset-failed 'forpost-*' 2>/dev/null || true

sudo systemctl daemon-reload

# Now analyze what we have and what to do
# (SCRIPT_DIR was resolved to an absolute path at the top of the script,
#  before the `cd /tmp` that makes relative BASH_SOURCE paths unresolvable.)

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
    
    # Backup config and logs if they exist (safe to call even when missing)
    if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
        TMP_BACKUP="/tmp/strema_config_backup_$$"
        cp "$INSTALL_DIR/config/stream.conf" "$TMP_BACKUP"
    fi
    if [ -f "$INSTALL_DIR/config/fleet.conf" ]; then
        TMP_FLEET_BACKUP="/tmp/strema_fleet_config_backup_$$"
        cp "$INSTALL_DIR/config/fleet.conf" "$TMP_FLEET_BACKUP"
    fi
    if [ -d "$INSTALL_DIR/logs" ]; then
        TMP_LOGS_BACKUP="/tmp/strema_logs_backup_$$"
        cp -a "$INSTALL_DIR/logs" "$TMP_LOGS_BACKUP" 2>/dev/null || TMP_LOGS_BACKUP=""
    fi
    
    # Download and extract
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    download_strema
    
    # Replace / install files
    sudo rm -rf "$INSTALL_DIR"
    mkdir -p "$REAL_HOME"
    mv "$SOURCE_DIR" "$INSTALL_DIR"
    
    # Restore config and logs if backups were created
    if [ -n "$TMP_BACKUP" ] && [ -f "$TMP_BACKUP" ]; then
        cp "$TMP_BACKUP" "$INSTALL_DIR/config/stream.conf"
        rm -f "$TMP_BACKUP"
    fi
    if [ -n "$TMP_FLEET_BACKUP" ] && [ -f "$TMP_FLEET_BACKUP" ]; then
        cp "$TMP_FLEET_BACKUP" "$INSTALL_DIR/config/fleet.conf"
        rm -f "$TMP_FLEET_BACKUP"
    fi
    if [ -n "$TMP_LOGS_BACKUP" ] && [ -d "$TMP_LOGS_BACKUP" ]; then
        mkdir -p "$INSTALL_DIR/logs"
        cp -a "$TMP_LOGS_BACKUP/." "$INSTALL_DIR/logs/"
        rm -rf "$TMP_LOGS_BACKUP"
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

# Prepare project files
echo ""
echo "[3/5] Preparing project files..."
chmod +x "$SCRIPT_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/"*.py 2>/dev/null || true
chmod +x "$SCRIPT_DIR/web/"web_config.py 2>/dev/null || true

# MediaMTX (the device's RTSP server) is not part of the release tarball —
# every install/update already requires internet for the archive itself, so
# the pinned binary is downloaded here and checksum-verified. Failure is
# non-fatal: forpost-mediamtx.service has ConditionPathExists and the
# legacy rtsp-server is masked unconditionally — forpost-capture always
# owns the camera, so only the RTSP mounts stay dead on a failed download.
# STREMA_INSTALL_DIR is required when the binary runs outside systemd (see
# the handle_config_change call below for the rationale).
if [ -x "$SCRIPT_DIR/scripts/strema" ]; then
    sudo STREMA_INSTALL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/scripts/strema" install_mediamtx || true
else
    sudo python3 "$SCRIPT_DIR/scripts/install_mediamtx.py" || true
fi
# Remove any leftover source / debug artifacts from closed releases
rm -rf "$SCRIPT_DIR/.git" 2>/dev/null || true
# Stale bytecode caches — matters on local/dev installs where the tree is
# reused across updates (a renamed module could keep a stale .pyc). A
# no-op on fresh extracts.
find "$SCRIPT_DIR" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -name '*.pyc' -delete 2>/dev/null || true
mkdir -p "$SCRIPT_DIR/logs"
# Logs moved to SQLite (logs/strema.db): remove legacy operational *.log
# files and their rotations. fleet-audit* is intentionally preserved — it is
# a separate append-only security audit trail, not diagnostic telemetry.
for f in "$SCRIPT_DIR"/logs/*.log "$SCRIPT_DIR"/logs/*.log.* \
         "$SCRIPT_DIR"/logs/*.old "$SCRIPT_DIR"/logs/*.gz; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
        fleet-audit*) continue ;;
    esac
    rm -f "$f" 2>/dev/null || true
done

# Ensure the entire project tree is owned by the real user.
# When install.sh runs via sudo (remote install, curl|bash, deploy.sh), file
# operations (mv, mkdir, chmod) execute as root and leave root-owned files.
# The web and stream services run as $REAL_USER and need write access to
# config/, logs/, and the state file in /tmp. A single recursive chown here
# supersedes the per-file chown calls that previously only fixed stream.conf
# and logs/ individually.
if [ -n "$REAL_USER" ]; then
    sudo chown -R "$REAL_USER:$REAL_USER" "$SCRIPT_DIR" 2>/dev/null || true
fi

# Clean up our temp files from previous run. Do NOT remove
# /tmp/dzyga_freq_current.txt — dzyga creates it only on frequency change,
# so deleting it would leave us blind until the next frequency change.
sudo rm -f /tmp/strema_* 2>/dev/null || true
# Also clean up old-name files from previous versions (migration)
sudo rm -f /tmp/dzyga_freq.txt /tmp/dzyga_scanning_state.txt \
          /tmp/dzyga_dynamic_overlay.txt /tmp/dzyga_last_freq_dynamic.txt \
          /tmp/dzyga.md5 /tmp/forpost_config_snapshot.conf 2>/dev/null || true

echo "✅ Files ready"

# Fleet operator account 'stremaadm': SSH login restricted to `strema
# fleet-admin` commands, executed as $REAL_USER through a sudoers whitelist.
# The account itself has no sudo rights and no access to the service user's
# files. Password is the fleet-wide documented default; change it anytime
# with `sudo passwd stremaadm`.
STREMAADM_SHELL=/usr/local/bin/stremaadm-shell
if [ -f "$SCRIPT_DIR/scripts/stremaadm_shell.sh" ]; then
    sudo sed -e "s|__INSTALL_DIR__|$SCRIPT_DIR|g" -e "s|__REAL_USER__|$REAL_USER|g" \
        "$SCRIPT_DIR/scripts/stremaadm_shell.sh" > /tmp/stremaadm-shell.$$
    sudo mv "/tmp/stremaadm-shell.$$" "$STREMAADM_SHELL"
    sudo chmod 755 "$STREMAADM_SHELL"
    if ! id stremaadm >/dev/null 2>&1; then
        sudo useradd -m -s "$STREMAADM_SHELL" stremaadm \
            || echo "⚠️  Could not create stremaadm user"
    else
        sudo usermod -s "$STREMAADM_SHELL" stremaadm || true
    fi
    echo 'stremaadm:forpost' | sudo chpasswd || true
    SUDOERS_TMP=$(mktemp)
    # Single whitelisted entry point — it dispatches to the strema binary or
    # strema.py itself, so the rule works for both release and source trees.
    cat > "$SUDOERS_TMP" <<EOF
stremaadm ALL=($REAL_USER) NOPASSWD: $SCRIPT_DIR/scripts/fleet_admin_entry.sh, $SCRIPT_DIR/scripts/fleet_admin_entry.sh *
EOF
    chmod 440 "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
        # install(1) sets root ownership — sudo ignores sudoers.d files
        # not owned by root.
        sudo install -o root -g root -m 440 "$SUDOERS_TMP" /etc/sudoers.d/strema-fleet
        rm -f "$SUDOERS_TMP"
        echo "✅ stremaadm fleet-admin account ready (login: stremaadm)"
    else
        rm -f "$SUDOERS_TMP"
        echo "⚠️  strema-fleet sudoers failed validation — skipping"
    fi
fi

# Replace one vendor binary when the on-device build differs from the
# canonical one. Args: $1 = component name (dzyga|dzyga_web),
# $2 = canonical sha256 from the release's SHA256SUMS.txt (empty = unknown,
#      MISSING_ENTRY = sums file present but has no entry for this asset).
update_dzyga_component() {
    local name="$1" want_sha="$2"
    local target="$FORPOST_DIR/$name"
    [ -f "$target" ] || return 0
    if [ -z "$want_sha" ]; then
        echo "⚠️  $name: SHA256SUMS.txt unavailable — cannot tell if update needed, skipping"
        return 0
    elif [ "$want_sha" = "MISSING_ENTRY" ]; then
        echo "⚠️  $name: no checksum entry in SHA256SUMS.txt — skipping"
        return 0
    fi
    local cur_sha
    cur_sha=$(sudo sha256sum "$target" 2>/dev/null | cut -d' ' -f1)
    [ -n "$cur_sha" ] || return 0
    [ "$cur_sha" = "$want_sha" ] && return 0   # already the canonical build
    echo "🔄 $name: differs from the canonical build — updating"
    local tmp="/tmp/strema_dzyga_dist_$name"
    if ! curl -fsSL --connect-timeout 15 -o "$tmp" "$DZYGA_DIST_BASE/$name"; then
        echo "⚠️  $name: download failed — keeping existing binary"
        return 0
    fi
    if ! echo "$want_sha  $tmp" | sha256sum -c - >/dev/null 2>&1; then
        echo "⚠️  $name: checksum mismatch — keeping existing binary"
        rm -f "$tmp"
        return 0
    fi
    # Delegate the swap (backup, service stop/start, owner/mode restore,
    # md5-cache cleanup) to the single implementation shared by the web UI
    # and fleet updates — see remote_script() in scripts/update_binary.py.
    if [ -x "$INSTALL_DIR/scripts/strema" ]; then
        STREMA_INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/strema" update_binary "$name" "$tmp" || true
    elif [ -f "$INSTALL_DIR/scripts/update_binary.py" ]; then
        python3 "$INSTALL_DIR/scripts/update_binary.py" "$name" "$tmp" || true
    else
        echo "⚠️  $name: update_binary helper not found — keeping existing binary"
    fi
    rm -f "$tmp"
    return 0
}

# Update vendor binaries that differ from the canonical dist release.
# Missing FORPOST dir means this is not an original FORPOST device — skip.
if [ -d "$FORPOST_DIR" ]; then
    dzyga_sums=$(curl -fsSL --connect-timeout 15 "$DZYGA_DIST_BASE/SHA256SUMS.txt" 2>/dev/null || true)
    dzyga_sum_for() {
        if [ -z "$dzyga_sums" ]; then echo; return; fi
        local s
        s=$(echo "$dzyga_sums" | awk -v f="$1" '$2==f {print $1}')
        echo "${s:-MISSING_ENTRY}"
    }
    update_dzyga_component "dzyga" "$(dzyga_sum_for dzyga)" || true
    update_dzyga_component "dzyga_web" "$(dzyga_sum_for dzyga_web)" || true
    unset -f dzyga_sum_for
else
    echo "⚠️  $FORPOST_DIR not found — not a FORPOST device, skipping dzyga update"
fi

# Install systemd services
echo ""
echo "[4/5] Installing systemd services..."
if [ ! -d "$SCRIPT_DIR/systemd" ] || [ -z "$(ls -A "$SCRIPT_DIR/systemd" 2>/dev/null)" ]; then
    echo "❌ Error: No systemd unit files found in $SCRIPT_DIR/systemd/"
    echo "   The downloaded archive appears to be incomplete."
    echo "   Try specifying a version explicitly:"
    echo "     curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/master/install.sh | bash -s v0.0.1-beta.05"
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
# RTSP server: always-on like the web UI. Its UDP sources are
# fire-and-forget, so it runs regardless of stream state; with the binary
# absent (failed download, dev deploy) ConditionPathExists keeps it
# inactive without crash-looping.
sudo systemctl enable --now forpost-mediamtx 2>/dev/null || true

# Camera capture: always-on like mediamtx — it owns /dev/videoX and fans
# raw packets out to the encoder input and the mediamtx raw mounts. It
# runs even when the mediamtx download failed: the encoder input is the
# camsrc feed, so the RTSP mounts are the only thing that stays dead.
# rtsp-server is masked unconditionally (install_mediamtx), so it can
# no longer hold the camera hostage.
# Free the camera node from any stale holder (dead service remnants,
# an orphaned ffmpeg) so forpost-capture can open it cleanly. Every
# legitimate holder was stopped above or masked (rtsp-server).
VIDEO_NODE=$(grep -h -oP '^VIDEO_DEVICE=\K\S+' "$SCRIPT_DIR/config/defaults.conf" "$SCRIPT_DIR/config/stream.conf" 2>/dev/null | tr -d '"'"'" | tail -1)
case "$VIDEO_NODE" in
    devvideo*) VIDEO_NODE="/dev/video${VIDEO_NODE#devvideo}" ;;
    /dev/*)    : ;;
    *)         VIDEO_NODE="" ;;
esac
if [ -n "$VIDEO_NODE" ] && [ -e "$VIDEO_NODE" ] && \
   sudo fuser "$VIDEO_NODE" >/dev/null 2>&1; then
    echo "⚠️  $VIDEO_NODE still held by a stale process — releasing"
    sudo fuser -k "$VIDEO_NODE" 2>/dev/null || true
fi
sudo systemctl enable --now forpost-capture 2>/dev/null || true

# Enable on boot only (don't start now)
sudo systemctl enable forpost-power-settings 2>/dev/null || true

# Disable by default (controlled via web UI)
sudo systemctl disable forpost-stream 2>/dev/null || true
sudo systemctl disable forpost-stream-autorestart.timer 2>/dev/null || true

# Apply configuration settings (autostart, auto-restart, etc.)
# Remove snapshot so handle_config_change.sh re-applies all settings from config
rm -f /tmp/strema_config_snapshot.conf 2>/dev/null || true
# Drop the cached DZYGA firmware version so the web service re-reads it
# via the OLED menu after this install (it may have been re-flashed).
rm -f /tmp/strema_dzyga_fw_version.txt 2>/dev/null || true
if [ -f "$SCRIPT_DIR/config/stream.conf" ]; then
    echo "Applying configuration settings..."
    # handle_config_change.py runs `systemctl enable/disable`, which needs
    # root. When invoked from systemd (forpost-stream-config.service) it runs
    # as root already; here we're invoked from install.sh as the regular
    # user, so elevate explicitly.
    if [ -x "$SCRIPT_DIR/scripts/strema" ]; then
        # The strema binary can't derive its install dir from __file__ (it's
        # a bundled Nuitka onefile executable), so it relies on
        # STREMA_INSTALL_DIR — normally set by tools/patch_systemd_for_binaries.py
        # in the systemd unit files, but this direct invocation from
        # install.sh needs it set explicitly too, or it silently can't find
        # config/stream.conf and skips applying autostart settings.
        sudo STREMA_INSTALL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/scripts/strema" handle_config_change 2>/dev/null || true
    else
        sudo python3 "$SCRIPT_DIR/scripts/handle_config_change.py" 2>/dev/null || true
    fi
fi

# Restart services if they were running before update
if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    echo "Restarting stream service..."
    sudo systemctl start forpost-stream || true
    # Give the service a moment to become active; if it failed, the web UI can be used to start it
    sleep 2
    if ! sudo systemctl is-active --quiet forpost-stream 2>/dev/null; then
        echo "⚠️  Stream service did not become active after start. It can be started manually from the web UI."
    fi
fi
sudo rm -f /tmp/.strema_stream_was_active 2>/dev/null || true

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
echo "  $SCRIPT_DIR/scripts/strema logs -f   # live stream log (SQLite store)"
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
