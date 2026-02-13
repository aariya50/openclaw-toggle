#!/bin/bash
# build-app.sh — Build OpenClawToggle.app from Swift Package Manager
#
# Usage:
#   ./build-app.sh           # Debug build
#   ./build-app.sh release   # Release build
#
# Output: ./build/OpenClawToggle.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-debug}"
if [[ "$CONFIG" == "release" ]]; then
    BUILD_FLAGS="-c release"
    BUILD_DIR=".build/release"
else
    BUILD_FLAGS=""
    BUILD_DIR=".build/debug"
fi

APP_NAME="OpenClawToggle"
APP_BUNDLE="build/${APP_NAME}.app"
VERSION=$(grep -A1 CFBundleShortVersionString Info.plist | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Building ${APP_NAME} v${VERSION} (${CONFIG})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Step 1: Build with SPM ─────────────────────────────────────────
echo "→ swift build ${BUILD_FLAGS}..."
swift build ${BUILD_FLAGS}

# ── Step 2: Create .app bundle structure ───────────────────────────
echo "→ Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# ── Step 3: Copy binary ───────────────────────────────────────────
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# ── Step 4: Copy Info.plist ────────────────────────────────────────
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"

# ── Step 5: Copy resources ────────────────────────────────────────
if [[ -f "Resources/alfred-icon.png" ]]; then
    cp "Resources/alfred-icon.png" "${APP_BUNDLE}/Contents/Resources/"
fi

# Copy .icns file if it exists
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
fi

# ── Step 6: Create PkgInfo ────────────────────────────────────────
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "✅ Built: ${APP_BUNDLE}"
echo "   Version: ${VERSION}"
echo "   Binary:  $(du -sh "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" | cut -f1)"
echo ""
echo "To run:  open ${APP_BUNDLE}"
echo "To install:  cp -r ${APP_BUNDLE} /Applications/"
