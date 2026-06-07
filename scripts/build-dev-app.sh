#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_NAME="BokslTab"
BUNDLE_ID="dev.boksl.BokslTab"
BUILD_DIR="$ROOT_DIR/.build"
APP_DIR="$BUILD_DIR/dev-app/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release --package-path "$ROOT_DIR"
  SOURCE_BINARY="$BUILD_DIR/release/$APP_NAME"
else
  swift build --package-path "$ROOT_DIR"
  SOURCE_BINARY="$BUILD_DIR/debug/$APP_NAME"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SOURCE_BINARY" "$EXECUTABLE_PATH"
chmod +x "$EXECUTABLE_PATH"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleDisplayName</key>
  <string>BokslTab</string>
  <key>CFBundleExecutable</key>
  <string>BokslTab</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>BokslTab</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Local development uses a stable designated requirement so macOS TCC permissions
# such as Accessibility survive normal source changes. Plain ad-hoc signing
# defaults to a cdhash-only requirement, which changes whenever the binary changes.
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign \
    --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP_DIR" >/dev/null
else
  codesign \
    --force \
    --sign "$CODESIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP_DIR" >/dev/null
fi
codesign --verify --verbose "$APP_DIR" >/dev/null

echo "$APP_DIR"
