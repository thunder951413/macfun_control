#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${FANBAR_VERSION:-1.0.0}"
BUILD_NUMBER="${FANBAR_BUILD_NUMBER:-1}"
BUILD_DIR="$ROOT/.build/app"
APP="$BUILD_DIR/FanBar.app"
MACOS="$APP/Contents/MacOS"
HELPERS="$APP/Contents/Library/HelperTools"
DAEMONS="$APP/Contents/Library/LaunchDaemons"
ARM_BINARY="$BUILD_DIR/FanBar-arm64"
INTEL_BINARY="$BUILD_DIR/FanBar-x86_64"
ARM_HELPER="$BUILD_DIR/FanBarHelper-arm64"
INTEL_HELPER="$BUILD_DIR/FanBarHelper-x86_64"

rm -rf "$APP"
mkdir -p "$MACOS" "$HELPERS" "$DAEMONS"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid FANBAR_VERSION or FANBAR_BUILD_NUMBER" >&2
  exit 1
fi

for arch in arm64 x86_64; do
  arch_build="$BUILD_DIR/swift-$arch"
  swift build \
    --package-path "$ROOT" \
    --build-path "$arch_build" \
    --configuration release \
    --arch "$arch"
  bin_path="$(swift build --package-path "$ROOT" --build-path "$arch_build" --configuration release --arch "$arch" --show-bin-path)"
  cp "$bin_path/FanBar" "$BUILD_DIR/FanBar-$arch"
  cp "$bin_path/FanBarHelper" "$BUILD_DIR/FanBarHelper-$arch"
done

lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$MACOS/FanBar"
lipo -create "$ARM_HELPER" "$INTEL_HELPER" -output "$HELPERS/FanBarHelper"
rm -f "$ARM_BINARY" "$INTEL_BINARY" "$ARM_HELPER" "$INTEL_HELPER"

cat > "$DAEMONS/local.fanbar.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.fanbar.helper</string>
  <key>BundleProgram</key>
  <string>Contents/Library/HelperTools/FanBarHelper</string>
  <key>MachServices</key>
  <dict>
    <key>local.fanbar.helper</key>
    <true/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>FanBar</string>
  <key>CFBundleIdentifier</key>
  <string>local.fanbar</string>
  <key>CFBundleName</key>
  <string>FanBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
plutil -lint "$DAEMONS/local.fanbar.helper.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

SIGN_IDENTITY="${FANBAR_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No development signing identity found; the privileged helper cannot be registered." >&2
  exit 1
fi

TIMESTAMP_ARGS=(--timestamp)
if [[ "${FANBAR_CODESIGN_TIMESTAMP:-}" == "none" ]]; then
  TIMESTAMP_ARGS=(--timestamp=none)
fi
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" --identifier local.fanbar.helper --sign "$SIGN_IDENTITY" "$HELPERS/FanBarHelper"
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP"

echo "$APP"
