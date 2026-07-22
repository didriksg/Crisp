#!/bin/bash
# Crisp — Build & Package Script
# Usage:  ./build.sh
# Output: build/Crisp.dmg

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Crisp.xcarchive"
APP_EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$APP_EXPORT_DIR/Crisp.app"
DMG_PATH="$BUILD_DIR/Crisp.dmg"

echo "==> Cleaning build dir…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release)…"
xcodebuild \
    -scheme Crisp \
    -configuration Release \
    archive \
    -archivePath "$ARCHIVE_PATH" \
    | grep -E "error:|warning:|Build succeeded|** ARCHIVE"

echo "==> Exporting .app…"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$APP_EXPORT_DIR" \
    -exportOptionsPlist "$PROJECT_ROOT/ExportOptions.plist" \
    | grep -E "error:|Export succeeded"

echo "==> Creating DMG…"
hdiutil create \
    -volname "Crisp" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "Done! Output:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
echo ""
echo "Note: App is unsigned. Users must right-click → Open to bypass Gatekeeper."
