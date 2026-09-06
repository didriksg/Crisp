#!/bin/bash
# Crisp — fast dev build & run (no Xcode needed, Command Line Tools only).
#
# Compiles the binary with swiftc, swaps it into the installed /Applications/Crisp.app,
# syncs the version from project.yml, re-signs (stable identity if present, else ad
# hoc), and relaunches. One command.
# For a release DMG (needs full Xcode) use ./build.sh instead. See docs/BUILDING.md.
#
# Override the target app with:  CRISP_APP=/path/to/Crisp.app ./dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
APP="${CRISP_APP:-/Applications/Crisp.app}"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found." >&2
    echo "Install Crisp once (DMG or ./build.sh) so there's a bundle to swap into." >&2
    exit 1
fi

# Single source of truth for the version: project.yml.
VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

./scripts/fetch-sparkle.sh

echo "==> Compiling Crisp $VERSION ($BUILD)..."
mkdir -p build
clang -O2 -fobjc-arc -mmacosx-version-min=14.0 -c Crisp/Audio/SoftwareVolumeEngine.m -o build/SoftwareVolumeEngine.o
swiftc -O -swift-version 5 -strict-concurrency=minimal -parse-as-library -module-cache-path build/ModuleCache \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
    -F vendor/Sparkle -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
    Crisp/Views/*.swift Crisp/Utilities/*.swift \
    build/SoftwareVolumeEngine.o -o Crisp-bin

echo "==> Swapping into ${APP}..."
pkill -x Crisp 2>/dev/null || true
sleep 1
cp Crisp-bin "$APP/Contents/MacOS/Crisp"
# The binary links Sparkle at @rpath, so the target bundle needs the framework
# too (an install from a pre-Sparkle release won't have it). Refresh it on
# every swap so vendor/ and the bundle can't drift; the re-sign below restores
# the seal broken by the XPCServices strip.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R vendor/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Keep the installed bundle's reported version in step with project.yml,
# since the binary swap doesn't regenerate Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Sparkle keys, absent when swapping into a pre-Sparkle install: without them
# the updater logs errors and prompts for check permission on second launch.
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSAudioCaptureUsageDescription" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAudioCaptureUsageDescription string Crisp captures system audio locally on your selected output to apply experimental software volume. Nothing is recorded or uploaded." "$PLIST"
for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://crispmac.app/appcast.xml" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string 3UT7wZoXDzrAhwCMVS3DoPt2lcya9H/cvlyXliuPuhM=" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$PLIST"
xattr -cr "$APP"
# Sign with a stable self-signed identity when one exists, so macOS keeps the
# Accessibility grant across rebuilds. Ad-hoc signing changes the code hash every
# build, which invalidates the CGEventTap permission the brightness keys rely on,
# forcing a re-grant after every deploy. Create the identity once: Keychain Access >
# Certificate Assistant > Create a Certificate, name "Crisp Dev", Self Signed Root,
# type Code Signing. Falls back to ad-hoc when it is absent.
SIGN_ID="${CRISP_SIGN_ID:-Crisp Dev}"
# No -v: a self-signed identity is reported "not trusted" and excluded by -v, but
# codesign still signs with it fine, and that's all we need (a stable designated
# requirement so TCC keeps the grant across rebuilds).
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "==> Signing with identity: $SIGN_ID"
else
    echo "==> Signing ad hoc ($SIGN_ID not found; Accessibility will reset each build)"
    SIGN_ID="-"
fi
# Framework first (its seal broke when XPCServices got stripped), then the app,
# no --deep. Autoupdate/Updater.app inside keep Sparkle's own valid signatures.
codesign --force -s "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force -s "$SIGN_ID" --entitlements Crisp/Crisp.entitlements "$APP"

echo "==> Launching..."
open "$APP"
echo "Done. Crisp $VERSION running."
