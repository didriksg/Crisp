#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="Crisp"
SCHEME="Crisp"
BUILD_DIR="$(pwd)/build"
DMG_NAME="${APP_NAME}.dmg"

echo "=== Building ${APP_NAME} Release ==="

# Clean and build Release (skip Xcode's codesign; we'll sign manually after stripping xattrs)
xcodebuild -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | tail -20

# Find the .app
APP_PATH=$(find "$BUILD_DIR" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: ${APP_NAME}.app not found in build output"
  exit 1
fi
echo "Found app: $APP_PATH"

# Strip extended attributes (resource forks, .DS_Store detritus) before signing
echo "=== Stripping extended attributes ==="
xattr -cr "$APP_PATH"

# Ad-hoc code sign
echo "=== Signing ==="
codesign --force --deep --sign - "$APP_PATH"

# Create staging directory for DMG
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Create DMG
echo "=== Creating DMG ==="
DMG_OUTPUT="$(pwd)/${DMG_NAME}"
rm -f "$DMG_OUTPUT"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_OUTPUT"

echo "=== Done ==="
echo "DMG: $DMG_OUTPUT"
ls -lh "$DMG_OUTPUT"
