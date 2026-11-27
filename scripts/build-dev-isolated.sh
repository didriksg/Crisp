#!/bin/bash
# Build an isolated development copy of Crisp inside build/dev/Crisp Dev.app.
#
# Isolation guarantees:
#   - Never touches, kills, or modifies /Applications/Crisp.app
#   - Unique bundle identifier: com.reconditum.crisp (isolated UserDefaults domain)
#   - Independent app name and executable: "Crisp Dev" / CrispDev (isolated process)
#   - Isolated Application Support directory, single-instance lock, and control socket
#     (enforced at runtime via AppIsolation when CFBundleIdentifier != com.crisp.app)
#   - Upstream Sparkle automatic updates disabled (CrispDisableUpdater = true, no SUFeedURL)
#   - Ad-hoc code signed by default (requires no Apple Developer credentials)
#
# Usage:
#   ./scripts/build-dev-isolated.sh            # build build/dev/Crisp Dev.app
#   ./scripts/build-dev-isolated.sh --launch   # build and launch the isolated dev app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=true ;;
        *)
            echo "Usage: $0 [--launch]" >&2
            exit 2
            ;;
    esac
done

BUNDLE_ID="${CRISP_DEV_BUNDLE_ID:-com.reconditum.crisp}"
APP_NAME="Crisp Dev"
EXECUTABLE_NAME="CrispDev"
DEV_BUILD_ROOT="$ROOT/build/dev"
APP="$DEV_BUILD_ROOT/${APP_NAME}.app"

if [ "$BUNDLE_ID" = "com.crisp.app" ]; then
    echo "error: refusing to build isolated dev bundle with production bundle ID com.crisp.app" >&2
    exit 1
fi

VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
ARCH="$(uname -m)"

"$ROOT/scripts/fetch-sparkle.sh"

mkdir -p "$DEV_BUILD_ROOT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "==> Compiling isolated Crisp Dev ($BUNDLE_ID, $VERSION-$BUILD, $ARCH)..."
SRC=$(find Crisp -name '*.swift' | sort)
# shellcheck disable=SC2086 # SRC is a list of Swift source paths
swiftc -O -swift-version 6 -parse-as-library \
    -target "${ARCH}-apple-macos14.0" \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
    -F "$ROOT/vendor/Sparkle" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -U -Xlinker _SLSConfigureDisplayEnabled \
    -Xlinker -U -Xlinker _SLSGetDisplayList \
    -Xlinker -U -Xlinker _SLSSetDisplayRotation \
    $SRC -o "$APP/Contents/MacOS/$EXECUTABLE_NAME"

echo "==> Embedding Sparkle.framework (updater disabled for isolated build)..."
cp -R "$ROOT/vendor/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

echo "==> Building app icon..."
ICONSET="$DEV_BUILD_ROOT/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
ICONS="Crisp/Assets.xcassets/AppIcon.appiconset"
cp "$ICONS/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICONS/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONS/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICONS/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Compiling localizations..."
LANGS=$(python3 "$ROOT/scripts/xcstrings-compile.py" Crisp/Resources/Localizable.xcstrings "$APP/Contents/Resources")
LOC_XML=""
for lang in $LANGS; do
    LOC_XML="${LOC_XML}<string>${lang}</string>"
done

echo "==> Writing isolated Info.plist..."
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key><string>${EXECUTABLE_NAME}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array>${LOC_XML}</array>
	<key>CFBundleShortVersionString</key><string>${VERSION}-dev</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Crisp - Free &amp; Open Source (Isolated Dev Build)</string>
	<key>NSAppleEventsUsageDescription</key><string>Crisp Dev uses System Events to switch Dark Mode with the system's animated transition.</string>
	<key>CrispDisableUpdater</key><true/>
	<key>SUEnableAutomaticChecks</key><false/>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing isolated bundle..."
xattr -cr "$APP"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$SPARKLE_FW/Versions/B/Autoupdate"
codesign --force --sign - "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --sign - "$SPARKLE_FW"
codesign --force --sign - --entitlements Crisp/Crisp.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built isolated dev bundle: $APP"
echo "    Bundle ID: $BUNDLE_ID"
echo "    Executable: $EXECUTABLE_NAME ($ARCH)"
echo "    Sparkle updates: DISABLED"
echo "    Official /Applications/Crisp.app: UNTOUCHED"

if [ "$LAUNCH" = true ]; then
    echo "==> Launching $APP..."
    open "$APP"
fi
