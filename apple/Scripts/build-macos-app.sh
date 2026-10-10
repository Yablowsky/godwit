#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_DIR="$APPLE_DIR/.build/Godwit.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

usage() {
  cat <<'MSG'
Usage:
  ./apple/Scripts/build-macos-app.sh --olcrtc-root /path/to/olcrtc

The OlcRTC repository path can also be provided with OLCRTC_REPO_ROOT.
MSG
}

OLCRTC_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --olcrtc-root)
      OLCRTC_ROOT_ARG="${2:-}"
      if [[ -z "$OLCRTC_ROOT_ARG" ]]; then
        echo "--olcrtc-root requires a path" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

source "$APPLE_DIR/Scripts/olcrtc-root.sh"
OLCRTC_DIR="$(require_olcrtc_root "$OLCRTC_ROOT_ARG" "Usage: ./apple/Scripts/build-macos-app.sh --olcrtc-root /path/to/olcrtc")"

"$APPLE_DIR/Scripts/build-macos-cli.sh" --olcrtc-root "$OLCRTC_DIR"

cd "$APPLE_DIR"
swift build -c "$CONFIGURATION" --product OlcRTCClientMac

SWIFT_BINARY="$APPLE_DIR/.build/arm64-apple-macosx/$CONFIGURATION/OlcRTCClientMac"
if [ ! -x "$SWIFT_BINARY" ]; then
  SWIFT_BINARY="$APPLE_DIR/.build/$CONFIGURATION/OlcRTCClientMac"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$SWIFT_BINARY" "$MACOS_DIR/Godwit"
cp "$APPLE_DIR/.build/olcrtc-macos" "$RESOURCES_DIR/olcrtc-macos"
cp "$APPLE_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Godwit</string>
  <key>CFBundleIdentifier</key>
  <string>com.egorozh.godwit.legacy.macos.dev</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Godwit</string>
  <key>CFBundleDisplayName</key>
  <string>Godwit Legacy</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/Godwit" "$RESOURCES_DIR/olcrtc-macos"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "Built $APP_DIR"
echo "Run it with:"
echo "  open \"$APP_DIR\""
