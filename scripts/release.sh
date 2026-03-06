#!/bin/bash
set -euo pipefail

# Usage: ./scripts/release.sh <version> [build_number]
# Example: ./scripts/release.sh 0.2.0 2

VERSION="${1:?Usage: $0 <version> [build_number]}"
BUILD_NUMBER="${2:-$(date +%s)}"

echo "==> Building Livekeet v${VERSION} (build ${BUILD_NUMBER})"

# Build release .app and create DMG
make dmg VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER"

# Notarize
echo ""
echo "==> Notarizing..."
make notarize VERSION="$VERSION"

# Copy DMG to docs/ for appcast generation
cp "dist/Livekeet-${VERSION}.dmg" docs/

# Generate appcast
echo ""
echo "==> Generating appcast..."
SPARKLE_BIN=".sparkle/bin/generate_appcast"
if [ ! -f "$SPARKLE_BIN" ]; then
    echo "Error: Sparkle tools not found at .sparkle/bin/"
    echo "Download them: curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz | tar xf - -C .sparkle"
    exit 1
fi
"$SPARKLE_BIN" docs/

echo ""
echo "==> Done! Next steps:"
echo "  1. git add docs/"
echo "  2. git commit -m 'Release v${VERSION}'"
echo "  3. git push origin main"
echo "  4. gh release create v${VERSION} dist/Livekeet-${VERSION}.dmg --title 'v${VERSION}'"
