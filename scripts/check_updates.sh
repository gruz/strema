#!/bin/bash
# Check for available updates from GitHub releases
# Returns JSON with available versions

GITHUB_REPO="gruz/strema"
CHANNEL="${1:-stable}"

# Determine installation directory
if [ -n "$SUDO_USER" ]; then
    ORIGINAL_HOME=$(eval echo ~$SUDO_USER)
else
    ORIGINAL_HOME="$HOME"
fi
INSTALL_DIR="$ORIGINAL_HOME/strema"  # stable or beta

# Get current version
CURRENT_VERSION="unknown"
if [ -f "$INSTALL_DIR/VERSION" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/VERSION")
elif [ -f "$(dirname "$0")/../VERSION" ]; then
    CURRENT_VERSION=$(cat "$(dirname "$0")/../VERSION")
fi

# Fetch releases from GitHub API
RELEASES=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases" 2>/dev/null)

if [ -z "$RELEASES" ]; then
    echo '{"error": "Failed to fetch releases", "current": "'$CURRENT_VERSION'"}'
    exit 1
fi

# Filter releases based on channel
if [ "$CHANNEL" = "stable" ]; then
    # Only stable releases (no pre-release flag)
    FILTERED=$(echo "$RELEASES" | jq '[.[] | select(.prerelease == false)]')
else
    # All releases (including beta)
    FILTERED="$RELEASES"
fi

# Get latest version
LATEST=$(echo "$FILTERED" | jq -r '.[0].tag_name // empty')

# Build releases array
RELEASES_JSON=$(echo "$FILTERED" | jq -c '[.[] | {
    version: .tag_name,
    name: .name,
    published_at: .published_at,
    prerelease: .prerelease,
    body: .body,
    download_url: (.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url)
}]')

# Check if update available
HAS_UPDATE=false
if [ -n "$LATEST" ] && [ "$LATEST" != "v$CURRENT_VERSION" ]; then
    HAS_UPDATE=true
fi

# Output JSON
cat << EOF
{
    "current": "$CURRENT_VERSION",
    "latest": "${LATEST#v}",
    "has_update": $HAS_UPDATE,
    "channel": "$CHANNEL",
    "releases": $RELEASES_JSON
}
EOF
