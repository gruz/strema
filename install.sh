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

# Release archives are built per-arch (see release.yml): arm64 keeps the
# historical unsuffixed name, x86_64 assets carry an -amd64 suffix.
case "$(uname -m)" in
    x86_64|amd64) ASSET_SUFFIX="-amd64" ;;
    *)            ASSET_SUFFIX="" ;;
esac

# Download and extract the strema archive into the current directory.
# Sets SOURCE_DIR variable. Exits on failure.
download_strema() {
    local tag="$VERSION"
    if [ "$VERSION" = "latest" ]; then
        get_latest_release
        if [ -n "$RATE_LIMITED" ]; then
            echo "$RATE_LIMIT_MSG"
            exit 1
        fi
        if [ -z "$LATEST_TAG" ]; then
            echo "❌ No releases found in $GITHUB_REPO."
            echo "   This is unexpected — please report this issue."
            exit 1
        fi
        tag="$LATEST_TAG"
    elif [ "$VERSION" = "master" ]; then
        echo "❌ 'master' is not available for remote installation from $GITHUB_REPO."
        echo "   The release repo only contains release archives, not source code."
        echo "   Use 'latest' or a specific version (e.g. v0.0.1-beta.05)."
        exit 1
    elif [ -f "$VERSION" ]; then
        # Install from a local archive (e.g. built via build_binaries.sh / build_in_docker.sh)
        echo "Installing from local archive: $VERSION"
        cp "$VERSION" strema.tar.gz
        tar -xzf strema.tar.gz
        SOURCE_DIR="$RELEASE_DIR_NAME"
        # Normalize VERSION to the release version carried inside the
        # archive — otherwise the VERSION file written below ends up
        # holding the local path that was passed on the command line.
        if [ -f "$SOURCE_DIR/VERSION" ]; then
            VERSION=$(tr -d '[:space:]' < "$SOURCE_DIR/VERSION")
        fi
        return
    fi
    echo "Downloading release $tag..."
    local ARCHIVE_URL="https://github.com/$GITHUB_REPO/releases/download/$tag/strema-$tag$ASSET_SUFFIX.tar.gz"
    # -C - resumes an interrupted download; some mirrors reject ranges, so
    # fall back to a plain fetch before declaring failure.
    curl -fsSL -C - -o strema.tar.gz "$ARCHIVE_URL" \
        || curl -fsSL -o strema.tar.gz "$ARCHIVE_URL" || {
        echo "❌ Download failed. Check if release $tag exists"
        exit 1
    }
    tar -xzf strema.tar.gz
    SOURCE_DIR="$RELEASE_DIR_NAME"
}

VERSION="${1:-latest}"

# A local archive argument may be relative — resolve it to an absolute
# path now, before any cd into temp dirs, so the -f checks in the
# git-mode guard and in download_strema see the same file. "local" is
# a mode keyword, not a path — never absolutize it.
if [ "$VERSION" != "local" ] && [ -f "$VERSION" ]; then
    VERSION="$(cd "$(dirname "$VERSION")" && pwd)/$(basename "$VERSION")"
fi

# Local install mode: use the source tree already present (e.g. pushed by deploy.sh dev/test)
LOCAL_INSTALL=false
if [ "$VERSION" = "local" ]; then
    LOCAL_INSTALL=true
fi

# Git mode: the script lives inside a source checkout (.git present) and no
# local archive was requested — update via git instead of a release tarball.
GIT_MODE=false
if [ -d "$SCRIPT_DIR/.git" ] && [ "$LOCAL_INSTALL" != "true" ] && [ ! -f "$VERSION" ]; then
    GIT_MODE=true
fi

# Tarball mode: download/extract a release archive (fresh install or update).
TARBALL_MODE=false
if [ "$LOCAL_INSTALL" != "true" ] && [ "$GIT_MODE" = "false" ]; then
    TARBALL_MODE=true
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

# Hub role: the same codebase runs as the central proxy on a server
# (e.g. a Hetzner VM) instead of a field device. Selected by
# STREMA_ROLE=hub on first install; afterwards the config/hub.enabled
# marker inside the install tree keeps updates in hub mode. Hub mode
# forces the service account to 'rpidrone' (the user all forpost-*
# units reference) and installs into its home, matching the device
# layout so units/config paths stay identical.
HUB_MODE=0
if [ "${STREMA_ROLE:-}" = "hub" ] || [ -f /home/rpidrone/strema/config/hub.enabled ]; then
    HUB_MODE=1
fi
if [ "$HUB_MODE" = "1" ]; then
    if ! id rpidrone >/dev/null 2>&1; then
        sudo useradd -m -s /bin/bash rpidrone
    fi
    REAL_USER="rpidrone"
    REAL_HOME=$(eval echo ~rpidrone)
    echo "🌐 Hub mode: installing the central proxy for user $REAL_USER"
fi

OLD_INSTALL_DIR="$REAL_HOME/FORPOST/strema"
NEW_INSTALL_DIR="$REAL_HOME/strema"
INSTALL_DIR="$NEW_INSTALL_DIR"

# Device-local config/state and logs that survive a tarball update: the
# tree is swapped wholesale, so these are moved (renamed) from the old
# tree into the new one — keep in sync with RSYNC_SOURCE_EXCLUDES in
# tools/deploy.sh. stream.conf.backup.* is intentionally NOT preserved.
LOCAL_CONFIG_FILES="stream.conf fleet.conf multiview_roster.json capture_backend.state descrambler_mode.state descrambler_stats.json descrambler_stats.clear mediamtx.env hub_registry.json"

# Move preserved config files and the whole logs dir from the old tree to
# the new one. Rename (mv) is used instead of copy so multi-hundred-MB
# log stores do not get duplicated on the SD card. hub.enabled is
# recreated by the hub-mode block after the swap.
link_local_state() {
    local old_dir="$1" new_dir="$2" f
    for f in $LOCAL_CONFIG_FILES; do
        if [ -f "$old_dir/config/$f" ]; then
            mkdir -p "$new_dir/config"
            mv -f "$old_dir/config/$f" "$new_dir/config/$f"
        fi
    done
    if [ -d "$old_dir/logs" ]; then
        rm -rf "$new_dir/logs"
        mv "$old_dir/logs" "$new_dir/logs"
    fi
}

# Install systemd units from a tree's systemd/ dir, rewriting
# __INSTALL_DIR__ and skipping files whose rendered content is unchanged.
# Args: $1 = tree dir, $2 = "force" to install unconditionally.
install_units() {
    local tree="$1" force="${2:-}"
    local file name tmp changed=0
    for file in "$tree/systemd"/*; do
        [ -f "$file" ] || continue
        name=$(basename "$file")
        if grep -q "__INSTALL_DIR__" "$file"; then
            tmp="/tmp/$name.install-$$"
            sudo sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$file" > "$tmp"
        else
            tmp="$file"
        fi
        if [ "$force" = "force" ] || ! sudo cmp -s "$tmp" "/etc/systemd/system/$name" 2>/dev/null; then
            if [ "$tmp" != "$file" ]; then
                sudo mv "$tmp" "/etc/systemd/system/$name"
            else
                sudo cp "$file" "/etc/systemd/system/$name"
            fi
            changed=1
        elif [ "$tmp" != "$file" ]; then
            rm -f "$tmp"
        fi
    done
    [ "$changed" = "1" ] && sudo systemctl daemon-reload
    return 0
}

# Remove /etc forpost-* unit files that are no longer shipped by the tree
# (renamed/removed units, stale drop-ins handled separately below).
remove_stale_units() {
    local service_file name
    for service_file in /etc/systemd/system/forpost-*.service \
                       /etc/systemd/system/forpost-*.timer \
                       /etc/systemd/system/forpost-*.path; do
        [ -f "$service_file" ] || [ -L "$service_file" ] || continue
        name=$(basename "$service_file")
        [ -f "$INSTALL_DIR/systemd/$name" ] && continue
        sudo rm -f "$service_file"
    done
    return 0
}

# ==========================================================================
# Phase 1 — prepare everything that can fail or take time while all
# services keep running: packages, the new tree (download/extract/verify),
# mediamtx and dzyga vendor binaries. Only after this succeeds do we touch
# running services, so a network failure aborts the update harmlessly.
# ==========================================================================
echo ""
echo "[1/6] Installing system dependencies..."

# The release binary is a Nuitka --standalone build: it carries its own
# Python runtime inside scripts/strema.dist/, so no libpython package is
# needed regardless of the distro's Python version.
# Probe first: apt-get update + install only runs when something is
# actually missing — on repeat updates this saves a slow package-index
# refresh on field links.
DEPS="ffmpeg strace python3-flask python3-markdown iproute2 inotify-tools python3-grpcio python3-protobuf v4l-utils sqlite3 wireguard-tools libcap2-bin"
MISSING_DEPS=""
for pkg in $DEPS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $pkg"
done
if [ -n "$MISSING_DEPS" ]; then
    sudo apt-get update -qq || echo "⚠️  apt update failed, continuing..."
    sudo apt-get install -y --no-install-recommends $MISSING_DEPS
else
    echo "   All dependencies already installed — skipping apt"
fi

# VPN tooling used by the web UI and fleet discovery. All packages are
# mandatory — a failure aborts the install (still before services are
# touched) so a missing dependency is a loud error, not a silent gap.
# The WireGuard kernel module is in-tree since 5.6, so wireguard-tools (wg,
# wg-quick) is all we need.
# tailscale is only packaged in newer Debian releases; fall back to the
# official installer (adds their apt repo) on older ones. pkgs.tailscale.com
# sits behind CloudFront and answers 403 to some egress IPs/regions — the
# last resort is our own mirror of the pinned tarball attached to a fixed
# strema-dist release tag (github.com must work anyway for the strema
# archive). The tag is pinned: 'latest' moves whenever publish.sh ships new
# dzyga binaries and would lose this asset.
TAILSCALE_VERSION=1.104.1
TAILSCALE_TGZ_SHA256=f60294374967f3dfd8cf57bbbd474d6cfce32d123e3a8ddeab82a87940daa806

install_tailscale_mirror() {
    # The strema-dist mirror asset is arm64-only — on other arches it
    # would install an arm64 tailscaled that can never run.
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *) echo "📥 tailscale: strema-dist mirror has no $(uname -m) build — skipping"
           return 1 ;;
    esac
    local name="tailscale_${TAILSCALE_VERSION}_arm64"
    local url="https://github.com/gruz/strema-dist/releases/download/v1.0.0/${name}.tgz"
    local tmp rc
    echo "📥 tailscale: official sources unreachable, using strema-dist mirror"
    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL "$url" -o "$tmp/$name.tgz" \
            || ! echo "$TAILSCALE_TGZ_SHA256  $tmp/$name.tgz" | sha256sum -c - >/dev/null \
            || ! tar -xzf "$tmp/$name.tgz" -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    # The bundled unit expects ExecStart=/usr/sbin/tailscaled — install to
    # the exact paths it references, not /usr/local/bin.
    sudo install -m755 "$tmp/$name/tailscaled" /usr/sbin/tailscaled \
        && sudo install -m755 "$tmp/$name/tailscale" /usr/bin/tailscale \
        && sudo install -m644 "$tmp/$name/systemd/tailscaled.service" \
                /etc/systemd/system/tailscaled.service \
        && sudo install -m644 "$tmp/$name/systemd/tailscaled.defaults" \
                /etc/default/tailscaled \
        && sudo mkdir -p /var/lib/tailscale \
        && sudo systemctl daemon-reload
    rc=$?
    rm -rf "$tmp"
    return $rc
}

# Validate a sudoers fragment (read from stdin) and install it into
# /etc/sudoers.d/<name>. Skips with a warning when validation fails.
install_sudoers() {
    local name="$1" tmp
    tmp=$(mktemp)
    cat > "$tmp"
    chmod 440 "$tmp"
    if sudo visudo -cf "$tmp" >/dev/null 2>&1; then
        # install(1) sets root ownership — sudo ignores sudoers.d files
        # not owned by root.
        sudo install -o root -g root -m 440 "$tmp" "/etc/sudoers.d/$name"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    echo "⚠️  $name sudoers failed validation — skipping"
    return 1
}

if ! command -v tailscale >/dev/null 2>&1; then
    # The official installer's `curl | sh` reports sh's exit status, which
    # masks a failed download — check `command -v` after each step instead
    # of trusting the chain.
    sudo apt-get install -y tailscale || true
    if ! command -v tailscale >/dev/null 2>&1; then
        curl -fsSL https://tailscale.com/install.sh | sudo sh || true
    fi
    command -v tailscale >/dev/null 2>&1 || install_tailscale_mirror
elif [ ! -f /etc/apt/sources.list.d/tailscale.list ]; then
    # Mirror/manual tarball installs have no apt repo, so tailscale would
    # never update. When pkgs.tailscale.com is reachable again, hand the
    # install back to the official package: the .deb owns the same
    # /usr/sbin|/usr/bin paths and the node state lives in
    # /var/lib/tailscale, so repo-managed updates take over seamlessly
    # (no re-auth needed). If the site is still blocked, keep the tarball.
    echo "📥 tailscale installed without apt repo — trying the official installer"
    curl -fsSL https://tailscale.com/install.sh | sudo sh || true
fi
sudo systemctl enable --now tailscaled

# Grant strace the CAP_SYS_PTRACE capability so the stream service (running
# as a non-root user) can attach to the root-owned dzyga process to read
# frequency via strace. Without this, get_frequency would need sudo on every
# call (every 2 seconds), flooding the journal with sudo log entries.
# libcap2-bin provides setcap/getcap; installed via $DEPS above.
sudo setcap cap_sys_ptrace+ep /usr/bin/strace 2>/dev/null || echo "⚠️  Could not set CAP_SYS_PTRACE on strace (frequency detection may need sudo)"

# ---- Stage the new tree / source BEFORE touching any service ----------
# Everything fallible (download, extract, archive verification, mediamtx
# and dzyga vendor fetches) happens here, while the old install keeps
# running. A failure exits with services untouched.
STAGING_DIR=""
SOURCE_DIR=""
OLD_DIR=""
PREFETCH_DIR=""
DZYGA_SUMS=""
RESTART_SCOPE="full"
OLD_HEAD=""
STREAM_WAS_ACTIVE=false

# Never leave staging/prefetch dirs behind on an early exit (set -e).
# OLD_DIR ($INSTALL_DIR.old-*) is deliberately NOT cleaned here — it is the
# rollback copy and is removed only after verification passes.
cleanup_staging() {
    [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ] && rm -rf "$STAGING_DIR"
    [ -n "$PREFETCH_DIR" ] && [ -d "$PREFETCH_DIR" ] && rm -rf "$PREFETCH_DIR"
    return 0
}
trap cleanup_staging EXIT

echo ""
echo "[2/6] Preparing new version..."

# Remember stream state and consume uninstall→install marker files before
# anything is stopped. Markers are created by uninstall.sh to carry service
# state across an uninstall→install cycle; they are consumed immediately so
# a failed install cannot leave a stale marker for a later run.
STREAM_STATE=$(sudo systemctl is-active forpost-stream 2>/dev/null || true)
if [ "$STREAM_STATE" = "active" ] || [ "$STREAM_STATE" = "activating" ] || [ "$STREAM_STATE" = "reloading" ] || [ -f /tmp/.strema_stream_was_active ]; then
    STREAM_WAS_ACTIVE=true
    echo "📝 Stream service is running - will restart after update"
fi
sudo rm -f /tmp/.strema_stream_was_active /tmp/.strema_udp_proxy_was_active 2>/dev/null || true

if [ "$TARBALL_MODE" = "true" ]; then
    # Stage the release archive next to the install dir (same filesystem,
    # so the final mv is a rename, not a copy). Hidden name keeps it out of
    # the way of the running services.
    STAGING_DIR="$REAL_HOME/.strema-update-$$"
    mkdir -p "$STAGING_DIR"
    cd "$STAGING_DIR"
    download_strema
    # download_strema leaves SOURCE_DIR relative to the staging dir — make
    # it absolute before leaving, or every later check/mv resolves wrong.
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
    cd "$REAL_HOME"

    # Verify the archive payload NOW — a truncated download must abort
    # before services are stopped, not after.
    if [ ! -d "$SOURCE_DIR/systemd" ] || [ -z "$(ls -A "$SOURCE_DIR/systemd" 2>/dev/null)" ]; then
        echo "❌ Error: No systemd unit files found in $SOURCE_DIR/systemd/"
        echo "   The downloaded archive appears to be incomplete."
        rm -rf "$STAGING_DIR"
        exit 1
    fi

    # Pre-install mediamtx into the staged tree. It is idempotent
    # (sha256-marker skip) and its failure is fatal by design — running it
    # here means a download failure aborts while services still run; the
    # post-swap call below becomes a no-op.
    if [ -x "$SOURCE_DIR/scripts/strema" ]; then
        sudo STREMA_INSTALL_DIR="$SOURCE_DIR" "$SOURCE_DIR/scripts/strema" install_mediamtx \
            || { echo "❌ mediamtx install failed — RTSP mounts would stay dead. Fix the cause and rerun install.sh"; rm -rf "$STAGING_DIR"; exit 1; }
    else
        sudo python3 "$SOURCE_DIR/scripts/install_mediamtx.py" \
            || { echo "❌ mediamtx install failed — RTSP mounts would stay dead. Fix the cause and rerun install.sh"; rm -rf "$STAGING_DIR"; exit 1; }
    fi

    # Decide how much of the fleet needs a restart. Only for UPDATES onto
    # an existing binary install: compare the compiled binary and the
    # remaining tree directly instead of trusting release metadata.
    #   strema.bin identical + only data files differ (web assets,
    #   templates, docs, installer scripts) → "light": nothing is stopped,
    #   only forpost-stream-web restarts.
    #   Anything else (scripts, systemd, config, vendor assets, missing or
    #   different binary) → "full": the classic stop-everything path.
    if [ -d "$INSTALL_DIR" ] \
       && [ -f "$INSTALL_DIR/scripts/strema.dist/strema.bin" ] \
       && [ -f "$SOURCE_DIR/scripts/strema.dist/strema.bin" ]; then
        OLD_BIN_SHA=$(sudo sha256sum "$INSTALL_DIR/scripts/strema.dist/strema.bin" 2>/dev/null | cut -d' ' -f1)
        NEW_BIN_SHA=$(sha256sum "$SOURCE_DIR/scripts/strema.dist/strema.bin" | cut -d' ' -f1)
        if [ -n "$OLD_BIN_SHA" ] && [ "$OLD_BIN_SHA" = "$NEW_BIN_SHA" ]; then
            # Binary code is identical — diff the rest of the tree.
            # Excluded: compiled dist (hashed above), runtime state that is
            # carried over anyway (logs/, preserved config files), and VCS
            # noise. "Only in" lines are normalized to repo-relative paths.
            # The final grep -vE drops runtime-generated artifacts that a
            # live tree always has but a fresh tarball never ships:
            # code_core.txt (diagnostic dump, gitignored) and the
            # install-time mediamtx download under scripts/assets/.
            DIFF_PATHS=$(diff -qr \
                --exclude=strema.dist --exclude=logs --exclude=.git \
                --exclude=__pycache__ --exclude='*.pyc' \
                --exclude=stream.conf --exclude=fleet.conf \
                --exclude=multiview_roster.json --exclude=capture_backend.state \
                --exclude=descrambler_mode.state --exclude=descrambler_stats.json \
                --exclude=descrambler_stats.clear --exclude=mediamtx.env \
                --exclude=hub_registry.json --exclude=hub.enabled \
                --exclude=VERSION --exclude=CHANGED.txt \
                "$INSTALL_DIR" "$SOURCE_DIR" 2>/dev/null \
                | sed -e "s|^Files $INSTALL_DIR/||; s| and $SOURCE_DIR/.* differ$||" \
                      -e "s|^Only in $INSTALL_DIR/\(.*\): |\1/|" \
                      -e "s|^Only in $SOURCE_DIR/\(.*\): |\1/|" \
                      -e "s|^Only in $INSTALL_DIR: ||" \
                      -e "s|^Only in $SOURCE_DIR: ||" \
                | grep -v '^$' \
                | grep -vE '(^|/)code_core\.txt$|^scripts/assets/mediamtx' || true)
            RESTART_SCOPE="light"
            while IFS= read -r rel; do
                [ -z "$rel" ] && continue
                case "$rel" in
                    */*)
                        case "$rel" in
                            web/static/*|web/templates/*|docs/*|tests/*|tools/*|.github/*|.devin/*|.vscode/*) ;;
                            *) RESTART_SCOPE="full"; break ;;
                        esac ;;
                    *)
                        case "$rel" in
                            *.md|install.sh|uninstall.sh|pytest.ini|requirements-test.txt|.gitignore|AGENTS.md|code_core.txt) ;;
                            *) RESTART_SCOPE="full"; break ;;
                        esac ;;
                esac
            done <<< "$DIFF_PATHS"
            if [ "$RESTART_SCOPE" = "light" ]; then
                echo "   Binary unchanged, only non-runtime files differ — light update (stream keeps running)"
            fi
        fi
    fi

    # Prefetch vendor dzyga binaries while the network is (still) free —
    # the swap itself below only moves local files.
    if [ -d "$FORPOST_DIR" ]; then
        DZYGA_SUMS=$(curl -fsSL --connect-timeout 15 "$DZYGA_DIST_BASE/SHA256SUMS.txt" 2>/dev/null || true)
        if [ -n "$DZYGA_SUMS" ]; then
            for name in dzyga dzyga_web; do
                target="$FORPOST_DIR/$name"
                [ -f "$target" ] || continue
                want=$(echo "$DZYGA_SUMS" | awk -v f="$name" '$2==f {print $1}')
                [ -z "$want" ] && continue
                cur=$(sudo sha256sum "$target" 2>/dev/null | cut -d' ' -f1)
                [ -n "$cur" ] && [ "$cur" = "$want" ] && continue
                PREFETCH_DIR="${PREFETCH_DIR:-$(mktemp -d /tmp/strema-dzyga-XXXXXX)}"
                if curl -fsSL --connect-timeout 15 -o "$PREFETCH_DIR/$name" "$DZYGA_DIST_BASE/$name" \
                   && echo "$want  $PREFETCH_DIR/$name" | sha256sum -c - >/dev/null 2>&1; then
                    echo "📥 $name: new canonical build downloaded (applied after update)"
                else
                    echo "⚠️  $name: prefetch failed — keeping existing binary"
                    rm -f "$PREFETCH_DIR/$name"
                fi
            done
        fi
    fi
elif [ "$GIT_MODE" = "true" ]; then
    # Git installation: update the checkout in place. Record HEAD so a
    # failed verification can roll the tree back.
    INSTALL_DIR="$SCRIPT_DIR"
    if [ "$INSTALL_DIR" != "$NEW_INSTALL_DIR" ]; then
        echo "⚠️  Warning: Git installation is at $INSTALL_DIR"
        echo "   Expected location: $NEW_INSTALL_DIR"
        echo "   Continuing with current location..."
    fi
    cd "$INSTALL_DIR"
    OLD_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "💾 Stashing local changes..."
        git stash push -m "Auto-stash before install.sh update $(date +%Y%m%d_%H%M%S)"
    fi
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
    cd /tmp
elif [ "$LOCAL_INSTALL" = "true" ]; then
    INSTALL_DIR="$SCRIPT_DIR"
fi

# Migrate a legacy FORPOST/strema install to ~/strema before the swap.
if [ -d "$OLD_INSTALL_DIR" ] && [ "$TARBALL_MODE" = "true" ]; then
    if [ ! -d "$NEW_INSTALL_DIR" ]; then
        echo ""
        echo "⚠️  Found old installation at: $OLD_INSTALL_DIR"
        echo "   Migrating to new location: $NEW_INSTALL_DIR"
        mv "$OLD_INSTALL_DIR" "$NEW_INSTALL_DIR"
        echo "✅ Migration complete"
        echo "   Note: Old directory $REAL_HOME/FORPOST still exists (may contain other files)"
    else
        echo "⚠️  Found installations in both locations:"
        echo "   Old: $OLD_INSTALL_DIR"
        echo "   New: $NEW_INSTALL_DIR"
        echo "   Using new location. You can manually remove old one."
    fi
fi

# ==========================================================================
# Phase 2 — downtime window. In "full" scope all services (except the web
# UI, which must survive to host this very update) are stopped and stale
# unit files removed. In "light" scope nothing is stopped: the tree swap
# below is two renames and running processes keep their (identical) code.
# ==========================================================================
echo ""
echo "[3/6] Switching to new version..."

if [ "$RESTART_SCOPE" = "full" ]; then
    echo "Stopping services..."
    for service in forpost-stream forpost-udp-proxy forpost-stream-autorestart.timer \
                   forpost-stream-config.path forpost-stream-watchdog.timer \
                   forpost-power-settings forpost-mediamtx forpost-capture \
                   forpost-hub-relay forpost-hub-webfw forpost-dzyga-proxy; do
        sudo systemctl stop "$service" 2>/dev/null || true
        sudo systemctl disable "$service" 2>/dev/null || true
    done

    # Unit files are NOT deleted here: services are already stopped+disabled,
    # and phase 3 reinstalls shipped units only when their content changed
    # (remove_stale_units drops the ones no longer shipped).

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
else
    echo "Light update — services keep running, only the web UI restarts."
fi

# Swap the install tree. mv is a rename on the same filesystem: the old
# tree stays available as $OLD_DIR for rollback until verification
# passes, and there is no window where ~/strema does not exist.
if [ "$TARBALL_MODE" = "true" ]; then
    if [ -d "$INSTALL_DIR" ]; then
        OLD_DIR="$INSTALL_DIR.old-$$"
        mv "$INSTALL_DIR" "$OLD_DIR"
        if ! mv "$SOURCE_DIR" "$INSTALL_DIR"; then
            echo "❌ Failed to move new tree into place — restoring previous install"
            mv "$OLD_DIR" "$INSTALL_DIR"
            rm -rf "$STAGING_DIR"
            exit 1
        fi
        link_local_state "$OLD_DIR" "$INSTALL_DIR"
        echo "✅ Previous version kept at $OLD_DIR until verification passes"
    else
        mv "$SOURCE_DIR" "$INSTALL_DIR"
    fi
fi
SCRIPT_DIR="$INSTALL_DIR"

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
    # Specific version like v0.1.0 - strip 'v' prefix; local archive installs
    # normalized VERSION to the archive's VERSION file in download_strema,
    # and LOCAL_INSTALL writes "local" here exactly like before.
    echo "${VERSION#v}" > "$INSTALL_DIR/VERSION"
fi

# ==========================================================================
# Phase 3 — configure the new tree and bring services back.
# ==========================================================================
echo ""
echo "[4/6] Configuring services..."

chmod +x "$SCRIPT_DIR/scripts/"*.sh "$SCRIPT_DIR/scripts/"*.py \
    "$SCRIPT_DIR/web/"web_config.py 2>/dev/null || true

# MediaMTX (the device's RTSP server) is not part of the release tarball —
# every install/update already requires internet for the archive itself, so
# the pinned binary is downloaded here and checksum-verified. For tarball
# installs it was already fetched into the staged tree above and this call
# is a fast no-op; for git/local installs it does the real work. Failure is
# FATAL: a silent miss leaves forpost-mediamtx dead (ConditionPathExists)
# while the install reports success — a broken device that looks healthy.
# STREMA_INSTALL_DIR is required when the binary runs outside systemd (see
# the handle_config_change call below for the rationale).
if [ -x "$SCRIPT_DIR/scripts/strema" ]; then
    sudo STREMA_INSTALL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/scripts/strema" install_mediamtx \
        || { echo "❌ mediamtx install failed — RTSP mounts would stay dead. Fix the cause and rerun install.sh"; exit 1; }
else
    sudo python3 "$SCRIPT_DIR/scripts/install_mediamtx.py" \
        || { echo "❌ mediamtx install failed — RTSP mounts would stay dead. Fix the cause and rerun install.sh"; exit 1; }
fi

# Hub mode: swap the device mediamtx config for the publisher hub one
# and drop the marker that keeps future installs in hub mode. The unit
# ConditionPathExists on forpost-hub-relay reads the same marker.
if [ "$HUB_MODE" = "1" ]; then
    cp "$SCRIPT_DIR/config/mediamtx_hub.yml" "$SCRIPT_DIR/config/mediamtx.yml"
    touch "$SCRIPT_DIR/config/hub.enabled"
    chown rpidrone:rpidrone "$SCRIPT_DIR/config/mediamtx.yml" \
        "$SCRIPT_DIR/config/hub.enabled" 2>/dev/null || true

    # Fleet discovery runs `sudo -n tailscale status` as the service
    # user. On devices that user has full sudo; on a hub rpidrone is a
    # plain account, so grant a narrow read-only rule for the status
    # command only.
    install_sudoers strema-tailscale <<EOF
$REAL_USER ALL=(root) NOPASSWD: /usr/bin/tailscale status, /usr/sbin/tailscale status
EOF

    # Hub self-update via web: the service user has no general sudo on a
    # hub, so /api/updates/install cannot run install.sh directly like on
    # devices. Install a root-owned helper plus a narrow sudoers rule —
    # the helper validates the version argument and runs the official
    # install.sh pipeline as root (hub mode is kept via hub.enabled).
    HUB_UPDATE_BIN=/usr/local/bin/strema-hub-update
    if [ -f "$SCRIPT_DIR/scripts/hub_self_update.sh" ]; then
        # Stamp the real install dir into the helper — it is not always
        # /home/rpidrone/strema (dev/source installs may differ).
        HUB_UPD_SRC=$(mktemp)
        sed "s|^INSTALL_DIR=.*|INSTALL_DIR=$SCRIPT_DIR|" \
            "$SCRIPT_DIR/scripts/hub_self_update.sh" > "$HUB_UPD_SRC"
        sudo install -o root -g root -m 755 "$HUB_UPD_SRC" "$HUB_UPDATE_BIN"
        rm -f "$HUB_UPD_SRC"
        install_sudoers strema-update <<EOF
$REAL_USER ALL=(root) NOPASSWD: $HUB_UPDATE_BIN *
EOF
    fi
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
# Also preserved: the config snapshot and cached firmware version (a light
# update must not invalidate them — handle_config_change would otherwise
# restart the stream on the next unrelated config edit) and the web-update
# log, which is this very install's stdout when triggered from the UI.
sudo sh -c 'for f in /tmp/strema_*; do
    case "$f" in
        */strema_config_snapshot.conf|*/strema_dzyga_fw_version.txt|*/strema_web_update.log) ;;
        *) rm -f "$f" ;;
    esac
done' 2>/dev/null || true
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
    # Single whitelisted entry point — it dispatches to the strema binary or
    # strema.py itself, so the rule works for both release and source trees.
    if install_sudoers strema-fleet <<EOF
stremaadm ALL=($REAL_USER) NOPASSWD: $SCRIPT_DIR/scripts/fleet_admin_entry.sh, $SCRIPT_DIR/scripts/fleet_admin_entry.sh *
EOF
    then
        echo "✅ stremaadm fleet-admin account ready (login: stremaadm)"
    fi
fi

# Apply prefetched vendor dzyga binaries downloaded during phase 1. The
# checksum was already verified against the release's SHA256SUMS.txt; the
# actual swap (backup, service restart, owner/mode restore, md5-cache
# cleanup) is delegated to update_binary — the same implementation the web
# UI and fleet updates use.
if [ -n "$PREFETCH_DIR" ] && [ -d "$PREFETCH_DIR" ]; then
    for f in "$PREFETCH_DIR"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        want=$(echo "$DZYGA_SUMS" | awk -v n="$name" '$2==n {print $1}')
        if [ -n "$want" ] && echo "$want  $f" | sha256sum -c - >/dev/null 2>&1; then
            echo "🔄 $name: applying canonical build"
            if [ -x "$INSTALL_DIR/scripts/strema" ]; then
                STREMA_INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/strema" update_binary "$name" "$f" || true
            elif [ -f "$INSTALL_DIR/scripts/update_binary.py" ]; then
                python3 "$INSTALL_DIR/scripts/update_binary.py" "$name" "$f" || true
            fi
        fi
    done
    rm -rf "$PREFETCH_DIR"
fi
# Missing FORPOST dir means this is not an original FORPOST device — skip.
if [ ! -d "$FORPOST_DIR" ]; then
    echo "⚠️  $FORPOST_DIR not found — not a FORPOST device, skipping dzyga update"
elif [ -z "$DZYGA_SUMS" ]; then
    echo "⚠️  dzyga SHA256SUMS.txt unavailable — cannot tell if update needed, skipping"
fi

# Install systemd services — only units whose rendered content actually
# changed are rewritten (a daemon-reload is still required afterwards).
# In "light" scope the tree's systemd/ payload is provably identical to the
# running one, so the whole step is skipped.
echo ""
echo "[5/6] Installing systemd services..."
if [ "$RESTART_SCOPE" = "full" ]; then
    if [ ! -d "$SCRIPT_DIR/systemd" ] || [ -z "$(ls -A "$SCRIPT_DIR/systemd" 2>/dev/null)" ]; then
        echo "❌ Error: No systemd unit files found in $SCRIPT_DIR/systemd/"
        echo "   The downloaded archive appears to be incomplete."
        echo "   Try specifying a version explicitly:"
        echo "     curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/master/install.sh | bash -s v0.0.1-beta.05"
        exit 1
    fi
    remove_stale_units
    install_units "$SCRIPT_DIR"
fi

# Start services
sudo systemctl enable --now forpost-stream-web
# RTSP server: always-on like the web UI. Its UDP sources are
# fire-and-forget, so it runs regardless of stream state; with the binary
# absent (failed download, dev deploy) ConditionPathExists keeps it
# inactive without crash-looping. On the hub it is the publisher ingest.
sudo systemctl enable --now forpost-mediamtx 2>/dev/null || true

if [ "$HUB_MODE" = "1" ]; then
    # Hub: relay fan-out on top of mediamtx ingest + web UI
    # (multiview/status). No camera, encoder, dzyga or device services —
    # the hub has no video hardware.
    sudo systemctl enable --now forpost-hub-relay 2>/dev/null || true
    # Kernel-level :8081 lockdown — the web API is unauthenticated by
    # the LAN-trust design, so on a public-IP hub it must not answer
    # the WAN at all (defense in depth with the Flask guard).
    sudo systemctl enable --now forpost-hub-webfw 2>/dev/null || true
else
    sudo systemctl enable --now forpost-stream-config.path
    sudo systemctl enable --now forpost-stream-watchdog.timer

    # Dzyga TCP shim: isolates the dzyga daemon's blocking frame broadcast from
    # slow remote :9999/:9998 consumers. Harmless when no remote clients exist;
    # ConditionPathExists skips it on devices without the dzyga binary.
    sudo systemctl enable --now forpost-dzyga-proxy 2>/dev/null || true

    # Camera capture: always-on like mediamtx — it owns /dev/videoX and fans
    # raw packets out to the encoder input and the mediamtx raw mounts. It
    # runs even when the mediamtx download failed: the encoder input is the
    # camsrc feed, so the RTSP mounts are the only thing that stays dead.
    # rtsp-server is masked unconditionally (install_mediamtx), so it can
    # no longer hold the camera hostage.
    # Free the camera node from any stale holder (dead service remnants,
    # an orphaned ffmpeg) so forpost-capture can open it cleanly. Every
    # legitimate holder was stopped above or masked (rtsp-server). In
    # "light" scope nothing was stopped, so only kill a holder when the
    # capture service itself is not running.
    if [ "$RESTART_SCOPE" = "full" ]; then
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
    fi
    sudo systemctl enable --now forpost-capture 2>/dev/null || true

    # Enable on boot only (don't start now). In "light" scope these
    # disables are skipped: handle_config_change does not run either, so
    # removing the boot symlinks here would silently change the next
    # boot's autostart state on an update that changed no config.
    sudo systemctl enable forpost-power-settings 2>/dev/null || true
    if [ "$RESTART_SCOPE" = "full" ]; then
        # Disable by default (controlled via web UI)
        sudo systemctl disable forpost-stream 2>/dev/null || true
        sudo systemctl disable forpost-stream-autorestart.timer 2>/dev/null || true
    fi
fi

# Apply configuration settings (autostart, auto-restart, etc.)
# Remove snapshot so handle_config_change.sh re-applies all settings from config.
# Skipped entirely in "light" scope: the config tree is provably unchanged,
# and with no snapshot present handle_config_change would restart the
# stream unconditionally — exactly what a light update must not do.
if [ "$RESTART_SCOPE" = "full" ] && [ "$HUB_MODE" != "1" ] && [ -f "$SCRIPT_DIR/config/stream.conf" ]; then
    rm -f /tmp/strema_config_snapshot.conf 2>/dev/null || true
    # Drop the cached DZYGA firmware version so the web service re-reads it
    # via the OLED menu after this install (it may have been re-flashed).
    rm -f /tmp/strema_dzyga_fw_version.txt 2>/dev/null || true
    echo "Applying configuration settings..."
    # handle_config_change.py runs `systemctl enable/disable`, which needs
    # root. When invoked from systemd (forpost-stream-config.service) it runs
    # as root already; here we're invoked from install.sh as the regular
    # user, so elevate explicitly.
    if [ -x "$SCRIPT_DIR/scripts/strema" ]; then
        # The strema binary can't derive its install dir from __file__ (it's
        # a bundled Nuitka standalone executable), so it relies on
        # STREMA_INSTALL_DIR — normally set by tools/patch_systemd_for_binaries.py
        # in the systemd unit files, but this direct invocation from
        # install.sh needs it set explicitly too, or it silently can't find
        # config/stream.conf and skips applying autostart settings.
        sudo STREMA_INSTALL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/scripts/strema" handle_config_change 2>/dev/null || true
    else
        sudo python3 "$SCRIPT_DIR/scripts/handle_config_change.py" 2>/dev/null || true
    fi
fi

# Restart services if they were running before update. Only in "full"
# scope — a light update never stopped them.
if [ "$RESTART_SCOPE" = "full" ] && [ "$HUB_MODE" != "1" ] && [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    echo "Restarting stream service..."
    sudo systemctl start forpost-stream || true
    # Give the service a moment to become active; if it failed, the web UI can be used to start it
    sleep 2
    if ! sudo systemctl is-active --quiet forpost-stream 2>/dev/null; then
        echo "⚠️  Stream service did not become active after start. It can be started manually from the web UI."
    fi
fi
sudo rm -f /tmp/.strema_stream_was_active 2>/dev/null || true

# Restart web service to pick up new code/assets (always — even a light
# update needs the new ASSET_VERSION so browsers refetch static files).
sudo systemctl restart forpost-stream-web

echo "✅ Services configured"

# ==========================================================================
# Phase 4 — verify, then either drop the old tree or roll back to it.
# ==========================================================================
echo ""
echo "[6/6] Verifying installation..."

rollback_install() {
    echo "❌ Update verification failed — rolling back to the previous version..."
    if [ -n "$OLD_DIR" ] && [ -d "$OLD_DIR" ]; then
        local FAILED_DIR="$INSTALL_DIR.failed-$$"
        mv "$INSTALL_DIR" "$FAILED_DIR" 2>/dev/null || true
        mv "$OLD_DIR" "$INSTALL_DIR"
        # Return the preserved device state to the restored tree.
        local f
        for f in $LOCAL_CONFIG_FILES; do
            [ -f "$FAILED_DIR/config/$f" ] && mv -f "$FAILED_DIR/config/$f" "$INSTALL_DIR/config/" 2>/dev/null || true
        done
        if [ -d "$FAILED_DIR/logs" ]; then
            rm -rf "$INSTALL_DIR/logs" 2>/dev/null || true
            mv "$FAILED_DIR/logs" "$INSTALL_DIR/logs" 2>/dev/null || true
        fi
        # Reinstall the previous units and bring back the previous service
        # set — mirrors the normal enable block below.
        install_units "$INSTALL_DIR" force
        sudo systemctl enable --now forpost-stream-web forpost-mediamtx 2>/dev/null || true
        if [ "$HUB_MODE" = "1" ]; then
            sudo systemctl enable --now forpost-hub-relay forpost-hub-webfw 2>/dev/null || true
        else
            sudo systemctl enable --now forpost-stream-config.path forpost-stream-watchdog.timer \
                forpost-dzyga-proxy forpost-capture 2>/dev/null || true
            if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
                sudo systemctl start forpost-stream 2>/dev/null || true
            fi
        fi
        rm -f /tmp/strema_config_snapshot.conf /tmp/strema_dzyga_fw_version.txt 2>/dev/null || true
        if [ "$HUB_MODE" != "1" ] && [ -f "$INSTALL_DIR/config/stream.conf" ]; then
            if [ -x "$INSTALL_DIR/scripts/strema" ]; then
                sudo STREMA_INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/strema" handle_config_change 2>/dev/null || true
            else
                sudo python3 "$INSTALL_DIR/scripts/handle_config_change.py" 2>/dev/null || true
            fi
        fi
        sudo systemctl restart forpost-stream-web 2>/dev/null || true
        rm -rf "$FAILED_DIR"
        echo "↩️  Rolled back to the previous installation ($OLD_DIR restored)"
    elif [ "$GIT_MODE" = "true" ] && [ -n "$OLD_HEAD" ]; then
        # Git installs have no tree copy — roll back via git itself.
        echo "↩️  Rolling back git checkout to $OLD_HEAD..."
        cd "$INSTALL_DIR" 2>/dev/null || exit 1
        git reset --hard "$OLD_HEAD" || true
        git stash pop 2>/dev/null || true
        cd /tmp
        install_units "$INSTALL_DIR" force
        sudo systemctl enable --now forpost-stream-web forpost-mediamtx 2>/dev/null || true
        if [ "$HUB_MODE" != "1" ]; then
            sudo systemctl enable --now forpost-stream-config.path forpost-stream-watchdog.timer \
                forpost-dzyga-proxy forpost-capture 2>/dev/null || true
            if [ "$STREAM_WAS_ACTIVE" = "true" ]; then
                sudo systemctl start forpost-stream 2>/dev/null || true
            fi
            rm -f /tmp/strema_config_snapshot.conf 2>/dev/null || true
            if [ -f "$INSTALL_DIR/config/stream.conf" ]; then
                if [ -f "$INSTALL_DIR/scripts/strema" ]; then
                    sudo STREMA_INSTALL_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/strema" handle_config_change 2>/dev/null || true
                else
                    sudo python3 "$INSTALL_DIR/scripts/handle_config_change.py" 2>/dev/null || true
                fi
            fi
        fi
        sudo systemctl restart forpost-stream-web 2>/dev/null || true
        echo "↩️  Rolled back git checkout to $OLD_HEAD"
    else
        echo "⚠️  No previous installation available — leaving the new tree in place."
        echo "   Recover manually: rerun install.sh with the previous version tag,"
        echo "   or restore from your own backup. Logs: /tmp/strema_web_update.log"
    fi
    exit 1
}

VERIFY_OK=true

# The web API must answer on localhost — loopback is explicitly allowed by
# the hub :8081 firewall, so this check works on hubs too.
WEB_OK=false
for _ in $(seq 1 30); do
    if curl -fsS --max-time 5 http://127.0.0.1:8081/api/version >/dev/null 2>&1; then
        WEB_OK=true
        break
    fi
    sleep 3
done
if [ "$WEB_OK" != "true" ]; then
    echo "⚠️  Web interface did not come up on :8081"
    VERIFY_OK=false
fi

# The stream must be active again when a full-scope update restarted it.
# "activating" counts as healthy: Type=simple flips through it on every
# (re)start and a crash-loop still reports activating between restarts.
if [ "$RESTART_SCOPE" = "full" ] && [ "$HUB_MODE" != "1" ] && [ "$STREAM_WAS_ACTIVE" = "true" ]; then
    STREAM_OK=false
    for _ in $(seq 1 30); do
        STREAM_STATE=$(sudo systemctl is-active forpost-stream 2>/dev/null || true)
        if [ "$STREAM_STATE" = "active" ] || [ "$STREAM_STATE" = "activating" ]; then
            STREAM_OK=true
            break
        fi
        sleep 3
    done
    if [ "$STREAM_OK" != "true" ]; then
        echo "⚠️  forpost-stream is not active after update (state: ${STREAM_STATE:-unknown})"
        VERIFY_OK=false
    fi
fi

if [ "$VERIFY_OK" != "true" ]; then
    rollback_install
fi

# Verification passed — the previous tree is no longer needed. The old
# tree can hold root-owned artifacts (e.g. __pycache__ written by
# sudo-run helpers), so a plain rm -rf as the service user fails partway
# — escalate to sudo and never let cleanup abort a good install.
if [ -n "$OLD_DIR" ] && [ -d "$OLD_DIR" ]; then
    rm -rf "$OLD_DIR" 2>/dev/null || sudo rm -rf "$OLD_DIR" 2>/dev/null || true
fi
rm -rf "$STAGING_DIR" 2>/dev/null || true

echo ""
echo "=========================================="
echo "✅ Installation complete!"
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
