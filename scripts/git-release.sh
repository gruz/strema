#!/bin/bash
# Automated release script for strema project
# Usage: 
#   git release              - auto-increment patch version (v1.0.7 -> v1.0.8)
#   git release v1.1.0       - create specific version
#   git release beta         - create beta release (auto-increment with -beta.N suffix)
#   git release v1.1.0-beta.1 - create specific beta version

set -e

REQUESTED_VERSION="$1"

# Get the latest tag
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")

# Function to increment version
increment_version() {
    local version=$1
    local type=$2  # patch, minor, major
    
    # Remove 'v' prefix and any suffix like -beta.1
    version=${version#v}
    version=${version%%-*}
    
    IFS='.' read -r major minor patch <<< "$version"
    
    case $type in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch|*)
            patch=$((patch + 1))
            ;;
    esac
    
    echo "v${major}.${minor}.${patch}"
}

# Determine new version
if [ -z "$REQUESTED_VERSION" ]; then
    # Auto-increment patch version
    NEW_VERSION=$(increment_version "$LATEST_TAG" "patch")
    echo "📦 Auto-incrementing version: $LATEST_TAG -> $NEW_VERSION"
elif [ "$REQUESTED_VERSION" = "beta" ]; then
    # Create beta version
    BASE_VERSION=$(increment_version "$LATEST_TAG" "patch")
    
    # Find latest beta number for this base version
    BETA_TAGS=$(git tag -l "${BASE_VERSION}-beta.*" 2>/dev/null | sort -V | tail -1)
    if [ -n "$BETA_TAGS" ]; then
        BETA_NUM=$(echo "$BETA_TAGS" | grep -oP 'beta\.\K\d+')
        BETA_NUM=$((BETA_NUM + 1))
    else
        BETA_NUM=1
    fi
    
    NEW_VERSION="${BASE_VERSION}-beta.${BETA_NUM}"
    echo "🧪 Creating beta release: $NEW_VERSION"
elif [[ "$REQUESTED_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]; then
    # Specific version provided
    NEW_VERSION="$REQUESTED_VERSION"
    echo "📦 Creating release: $NEW_VERSION"
else
    echo "❌ Error: Invalid version format"
    echo ""
    echo "Usage:"
    echo "  git release              - auto-increment patch (v1.0.7 -> v1.0.8)"
    echo "  git release v1.1.0       - create specific version"
    echo "  git release beta         - create beta release"
    echo "  git release v1.1.0-beta.1 - create specific beta version"
    exit 1
fi

# Check if tag already exists
if git rev-parse "$NEW_VERSION" >/dev/null 2>&1; then
    echo "❌ Error: Tag $NEW_VERSION already exists"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "⚠️  Warning: You have uncommitted changes"
    read -p "Do you want to commit them now? (y/n): " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git add .
        read -p "Commit message: " -r COMMIT_MSG
        git commit -m "$COMMIT_MSG"
    else
        echo "❌ Aborted: Please commit or stash your changes first"
        exit 1
    fi
fi

# Update VERSION file
echo "${NEW_VERSION#v}" > VERSION
git add VERSION
git commit -m "chore: bump version to $NEW_VERSION" --allow-empty

# Create and push tag
echo ""
echo "Creating tag $NEW_VERSION..."
git tag "$NEW_VERSION"

echo "Pushing to origin..."
git push origin master
git push origin "$NEW_VERSION"

echo ""
echo "✅ Release $NEW_VERSION created and pushed!"
echo ""
echo "🔗 GitHub will automatically create the release at:"
echo "   https://github.com/gruz/strema/releases/tag/$NEW_VERSION"
echo ""
echo "Next steps:"
echo "1. Wait for GitHub Actions to build the release (if configured)"
echo "2. Edit release notes on GitHub if needed"
echo "3. Users can update via: sudo ~/strema/scripts/update.sh $NEW_VERSION"
