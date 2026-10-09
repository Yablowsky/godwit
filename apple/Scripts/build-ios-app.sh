#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
SCHEME="OlcRTCClient iOS"
DESTINATION="generic/platform=iOS Simulator"

usage() {
  cat <<'MSG'
Usage:
  ./apple/Scripts/build-ios-app.sh --olcrtc-root /path/to/olcrtc [destination]

The OlcRTC repository path can also be provided with OLCRTC_REPO_ROOT.
MSG
}

OLCRTC_ROOT_ARG=""
DESTINATION_SET=0
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
    --destination)
      DESTINATION="${2:-}"
      if [[ -z "$DESTINATION" ]]; then
        echo "--destination requires a value" >&2
        exit 1
      fi
      DESTINATION_SET=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$DESTINATION_SET" -eq 0 ]]; then
        DESTINATION="$1"
        DESTINATION_SET=1
        shift
      else
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

source "$APPLE_DIR/Scripts/olcrtc-root.sh"
OLCRTC_DIR="$(require_olcrtc_root "$OLCRTC_ROOT_ARG" "Usage: ./apple/Scripts/build-ios-app.sh --olcrtc-root /path/to/olcrtc [destination]")"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  cat <<'MSG'
Xcode is installed but not ready for iOS builds.

Run these once in Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

Then rerun:
  ./apple/Scripts/build-ios-app.sh
MSG
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  cat <<'MSG'
Xcode iOS SDK is not ready.

Run these once in Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

Then rerun:
  ./apple/Scripts/build-ios-app.sh
MSG
  exit 1
fi

"$APPLE_DIR/Scripts/build-xcframework.sh" --olcrtc-root "$OLCRTC_DIR"

if command -v xcodegen >/dev/null 2>&1; then
  (cd "$APPLE_DIR" && xcodegen generate)
fi

xcodebuild \
  -project "$APPLE_DIR/Godwit.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  build

echo "Built iOS app for: $DESTINATION"
