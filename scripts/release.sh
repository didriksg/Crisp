#!/bin/bash
set -euo pipefail

# Crisp release script: builds a signed universal DMG with the Command Line
# Tools only (no Xcode), and optionally publishes the GitHub release. Default
# is a dry run: it builds and verifies the DMG but publishes nothing. Pass
# --publish to actually release.
#
# Usage:
#   ./scripts/release.sh v1.0.4 notes.md            # dry run: build DMG only
#   ./scripts/release.sh v1.0.4 notes.md --publish  # build + release
#
# notes.md is the release body (required for --publish; optional for dry run).

TAG="${1:?Usage: ./scripts/release.sh vX.Y.Z [notes.md] [--publish]}"
NOTES="${2:-}"
PUBLISH=false
for arg in "$@"; do [ "$arg" = "--publish" ] && PUBLISH=true; done
[ "${NOTES:-}" = "--publish" ] && NOTES=""

VERSION="${TAG#v}"                       # strip leading v for Info.plist
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/Crisp.app"
DMG="$ROOT/Crisp.dmg"

# A real release must ship complete translations; the dry run (CI on every PR)
# skips this so adding an English string doesn't block contributors — the
# maintainer fills the gaps before publishing.
if [ "$PUBLISH" = true ]; then
    echo "==> Checking translation completeness…"
    python3 "$ROOT/scripts/check-translations.py" Crisp/Resources/Localizable.xcstrings
fi

rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

"$ROOT/scripts/fetch-sparkle.sh"

echo "==> Compiling universal binary (arm64 + x86_64)…"
SRC=$(find Crisp -name '*.swift')
for a in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$a-apple-macos14.0" \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -F "$ROOT/vendor/Sparkle" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -U -Xlinker _SLSConfigureDisplayEnabled \
    -Xlinker -U -Xlinker _SLSGetDisplayList \
    $SRC -o "$BUILD/Crisp-$a"
done
lipo -create "$BUILD/Crisp-arm64" "$BUILD/Crisp-x86_64" -output "$APP/Contents/MacOS/Crisp"

# crispctl ships inside the bundle (Contents/MacOS/crispctl); Settings links it
# into /usr/local/bin and the Homebrew cask's binary stanza does the same. The
# source list mirrors the crispctl target in project.yml. No -parse-as-library:
# main.swift is top-level code.
echo "==> Compiling crispctl (arm64 + x86_64)…"
for a in arm64 x86_64; do
  swiftc -O -target "$a-apple-macos14.0" \
    Sources/crispctl/main.swift Crisp/Models/CrispControlModel.swift Crisp/Models/BrightnessKeySteps.swift \
    -o "$BUILD/crispctl-$a"
done
lipo -create "$BUILD/crispctl-arm64" "$BUILD/crispctl-x86_64" -output "$APP/Contents/MacOS/crispctl"

echo "==> Embedding Sparkle.framework…"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$ROOT/vendor/Sparkle/Sparkle.framework" "$APP/Contents/Frameworks/"
# Crisp is not sandboxed, so Sparkle's XPC services are dead weight; Sparkle's
# docs recommend deleting them (the dir and the top-level symlink to it, which
# would otherwise dangle). Stripping breaks the framework's signature seal,
# which is fine: the signing step below re-signs the framework either way.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

echo "==> Building app icon from asset catalog…"
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
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

echo "==> Compiling localizations from the String Catalog…"
# The CLT ship no xcstringstool, so generate <lang>.lproj/Localizable.strings
# ourselves; without this the bundle has zero localizations and ships en-only.
LANGS=$(python3 "$ROOT/scripts/xcstrings-compile.py" Crisp/Resources/Localizable.xcstrings "$APP/Contents/Resources")
LOC_XML=""; for l in $LANGS; do LOC_XML="${LOC_XML}<string>${l}</string>"; done
echo "    languages: $LANGS"

echo "==> Writing Info.plist / PkgInfo…"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Crisp</string>
	<key>CFBundleDisplayName</key><string>Crisp</string>
	<key>CFBundleIdentifier</key><string>com.crisp.app</string>
	<key>CFBundleExecutable</key><string>Crisp</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array>${LOC_XML}</array>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Crisp - Free &amp; Open Source</string>
	<key>NSAppleEventsUsageDescription</key><string>Crisp uses System Events to switch Dark Mode with the system's animated transition.</string>
	<key>SUFeedURL</key><string>https://crispmac.app/appcast.xml</string>
	<key>SUPublicEDKey</key><string>3UT7wZoXDzrAhwCMVS3DoPt2lcya9H/cvlyXliuPuhM=</string>
	<key>SUEnableAutomaticChecks</key><true/>
	<key>SUVerifyUpdateBeforeExtraction</key><true/>
	<key>SURequireSignedFeed</key><true/>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

# Sign with a Developer ID + hardened runtime when CRISP_SIGN_ID is set (release),
# else ad-hoc so dry runs and contributor/CI builds still work without a cert. A
# notarizable build needs the hardened runtime (--options runtime) and a secure
# timestamp; ad-hoc gets neither and can't be notarized anyway. (b00d.0)
# Sparkle's nested executables get signed individually, inside-out, then the app
# WITHOUT --deep: --deep would stamp the app's entitlements onto nested code and
# Sparkle's docs explicitly warn against it.
xattr -cr "$APP"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_NESTED=("$SPARKLE_FW/Versions/B/Autoupdate" "$SPARKLE_FW/Versions/B/Updater.app" "$SPARKLE_FW" "$APP/Contents/MacOS/crispctl")
if [ -n "${CRISP_SIGN_ID:-}" ]; then
  echo "==> Signing (Developer ID: $CRISP_SIGN_ID, hardened runtime)…"
  for item in "${SPARKLE_NESTED[@]}"; do
    codesign --force --options runtime --timestamp --sign "$CRISP_SIGN_ID" "$item"
  done
  codesign --force --options runtime --timestamp \
    --entitlements Crisp/Crisp.entitlements --sign "$CRISP_SIGN_ID" "$APP"
else
  echo "==> Signing (ad-hoc — set CRISP_SIGN_ID for a notarizable build)…"
  for item in "${SPARKLE_NESTED[@]}"; do
    codesign --force --sign - "$item"
  done
  codesign --force --sign - --entitlements Crisp/Crisp.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP"

# Notarize the app and staple the ticket BEFORE packaging, so the app validates
# offline once dragged out of the DMG and the DMG's sha256 (computed below) is the
# final artifact. Runs only with a Developer ID signature plus a stored notarytool
# profile — create it once with:
#   xcrun notarytool store-credentials <profile> \
#     --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>
# Skipped otherwise so unsigned dry runs still produce a DMG. (b00d.0)
if [ -n "${CRISP_SIGN_ID:-}" ] && [ -n "${CRISP_NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (profile: $CRISP_NOTARY_PROFILE)…"
  ditto -c -k --keepParent "$APP" "$BUILD/Crisp.zip"
  xcrun notarytool submit "$BUILD/Crisp.zip" --keychain-profile "$CRISP_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
elif [ -n "${CRISP_SIGN_ID:-}" ]; then
  echo "==> WARNING: signed with Developer ID but CRISP_NOTARY_PROFILE unset — NOT notarized."
fi

echo "==> Building DMG…"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Crisp -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Sign, notarize and staple the DMG itself, not just the app inside it. The app
# is already stapled above, so it runs offline once dragged across, but a
# downloaded DMG carries the quarantine flag and Gatekeeper assesses the disk
# image when it is opened. Order matters and all three steps are needed:
#   - unsigned + ticket  -> "rejected: no usable signature" (a ticket alone is
#     not enough; spctl has no signature to attach it to)
#   - signed, no ticket  -> "rejected: Unnotarized Developer ID"
#   - signed + notarized + stapled -> accepted, and offline, since the ticket
#     travels in the file instead of needing a lookup with Apple.
# codesign and stapler each rewrite the DMG, so both must land before the
# sha256 below: that hash is what the Homebrew cask pins, and a mismatch fails
# every brew install.
if [ -n "${CRISP_SIGN_ID:-}" ] && [ -n "${CRISP_NOTARY_PROFILE:-}" ]; then
  echo "==> Signing the DMG…"
  codesign --force --timestamp --sign "$CRISP_SIGN_ID" "$DMG"
  echo "==> Notarizing the DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$CRISP_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature "$DMG"
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "==> Built $DMG"
echo "    version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"), archs $(lipo -archs "$APP/Contents/MacOS/Crisp"), sha256 $SHA"
echo "    crispctl archs $(lipo -archs "$APP/Contents/MacOS/crispctl")"

if [ "$PUBLISH" != true ]; then
  echo "==> Dry run. Pass --publish to create the release and regenerate the appcast."
  exit 0
fi

[ -n "$NOTES" ] && [ -f "$NOTES" ] || { echo "ERROR: --publish needs a notes file: ./scripts/release.sh $TAG notes.md --publish"; exit 1; }

# Keep project.yml (the Xcode build path) in sync with the version we shipped.
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${VERSION}\"/" project.yml

echo "==> Creating GitHub release ${TAG}…"
gh release create "$TAG" --title "Crisp ${TAG}" --notes-file "$NOTES" "$DMG"

# Sparkle reads docs/appcast.xml via GitHub Pages. generate_appcast signs the
# DMG with the EdDSA key from the login Keychain (created once with
# ./vendor/Sparkle/bin/generate_keys) and points the enclosure at the release
# asset uploaded above.
# ponytail: single-entry appcast, latest release only; old installs only ever
# need the newest version. Embed HTML release notes here if ever wanted.
echo "==> Generating Sparkle appcast…"
APPCAST_STAGE="$BUILD/appcast"; mkdir -p "$APPCAST_STAGE"
cp "$DMG" "$APPCAST_STAGE/Crisp.dmg"
"$ROOT/vendor/Sparkle/bin/generate_appcast" \
  --download-url-prefix "https://github.com/didriksg/Crisp/releases/download/${TAG}/" \
  --link "https://github.com/didriksg/Crisp/releases" \
  -o "$ROOT/docs/appcast.xml" "$APPCAST_STAGE"

echo "==> Released ${TAG}."
echo "==> ACTION REQUIRED: commit and push docs/appcast.xml (+ project.yml bump)."
echo "    In-app updates go live only once GitHub Pages serves the new appcast."
echo "    homebrew/cask picks the release up by autobump (runs every 3 hours);"
echo "    if it hasn't after a day: brew bump-cask-pr crisp --version ${VERSION}"
