#!/bin/bash
# Check for available updates from GitHub releases
# Returns JSON with available versions
# Usage: check_updates.sh [channel] [force]
#   channel: stable (default) or beta
#   force: any value to force refresh cache

GITHUB_REPO="gruz/strema"
CHANNEL="${1:-stable}"
FORCE_REFRESH="${2}"

# Determine installation directory
if [ -n "$SUDO_USER" ]; then
    ORIGINAL_HOME=$(eval echo ~$SUDO_USER)
else
    ORIGINAL_HOME="$HOME"
fi
INSTALL_DIR="$ORIGINAL_HOME/strema"

# Cache configuration
CACHE_DIR="$INSTALL_DIR/.cache"
CACHE_FILE="$CACHE_DIR/updates_${CHANNEL}.json"
CACHE_TTL=3600  # 1 hour in seconds

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# Check if cache is valid
if [ -z "$FORCE_REFRESH" ] && [ -f "$CACHE_FILE" ]; then
    CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))
    if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
        # Cache is still valid, return cached data
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# Get current version
CURRENT_VERSION="unknown"
if [ -f "$INSTALL_DIR/VERSION" ]; then
    CURRENT_VERSION=$(cat "$INSTALL_DIR/VERSION")
elif [ -f "$(dirname "$0")/../VERSION" ]; then
    CURRENT_VERSION=$(cat "$(dirname "$0")/../VERSION")
fi

# Fetch releases from GitHub API
RELEASES=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases" 2>/dev/null)

# Handle case when API returns empty or fails
if [ -z "$RELEASES" ] || [ "$RELEASES" = "[]" ]; then
    # No releases available, but we can still show master
    FILTERED="[]"
    LATEST=""
else
    # Filter releases based on channel
    if [ "$CHANNEL" = "stable" ]; then
        # Only stable releases (no pre-release flag)
        FILTERED=$(echo "$RELEASES" | jq '[.[] | select(.prerelease == false)]')
    else
        # All releases (including beta)
        FILTERED="$RELEASES"
    fi
    
    # Get latest release version
    LATEST=$(echo "$FILTERED" | jq -r '.[0].tag_name // empty')
fi

# Get latest commit info from master branch
MASTER_COMMIT=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/commits/master" 2>/dev/null | jq -r '.sha[0:7] // empty')
MASTER_DATE=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/commits/master" 2>/dev/null | jq -r '.commit.committer.date // empty')

# Build releases array with master branch as first option
# Always include master, even if API fails (fallback for rate limiting)
if [ -n "$MASTER_COMMIT" ]; then
    MASTER_ENTRY='[{
        "version": "master",
        "name": "Latest Development (master)",
        "published_at": "'$MASTER_DATE'",
        "prerelease": false,
        "body": "Найновіша версія з гілки master. Містить всі останні функції та виправлення.\n\nCommit: '$MASTER_COMMIT'",
        "download_url": "https://github.com/'$GITHUB_REPO'/archive/refs/heads/master.tar.gz"
    }]'
else
    # Fallback when GitHub API is unavailable (rate limiting)
    CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    MASTER_ENTRY='[{
        "version": "master",
        "name": "Latest Development (master)",
        "published_at": "'$CURRENT_DATE'",
        "prerelease": false,
        "body": "Найновіша версія з гілки master. Містить всі останні функції та виправлення.",
        "download_url": "https://github.com/'$GITHUB_REPO'/archive/refs/heads/master.tar.gz"
    }]'
fi

# Build releases array from GitHub releases
RELEASES_JSON=$(echo "$FILTERED" | jq -c '[.[] | {
    version: .tag_name,
    name: .name,
    published_at: .published_at,
    prerelease: .prerelease,
    body: .body,
    download_url: (.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url)
}]')

# Combine master entry with releases
COMBINED_RELEASES=$(echo "$MASTER_ENTRY $RELEASES_JSON" | jq -s 'add')

# Check if update available (comparing with latest release, not master)
HAS_UPDATE=false
if [ -n "$LATEST" ] && [ "$LATEST" != "v$CURRENT_VERSION" ]; then
    HAS_UPDATE=true
fi

# Build output JSON
OUTPUT=$(cat << EOF
{
    "current": "$CURRENT_VERSION",
    "latest": "${LATEST#v}",
    "has_update": $HAS_UPDATE,
    "channel": "$CHANNEL",
    "releases": $COMBINED_RELEASES
}
EOF
)

# Save to cache
echo "$OUTPUT" > "$CACHE_FILE"

# Output result
echo "$OUTPUT"
