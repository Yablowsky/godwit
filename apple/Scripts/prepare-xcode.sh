#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"

usage() {
  cat <<'MSG'
Usage:
  ./apple/Scripts/prepare-xcode.sh --olcrtc-root /path/to/olcrtc

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
OLCRTC_DIR="$(require_olcrtc_root "$OLCRTC_ROOT_ARG" "Usage: ./apple/Scripts/prepare-xcode.sh --olcrtc-root /path/to/olcrtc")"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  cat <<'MSG'
Xcode is required for iOS/macOS app builds.

Install Xcode from the App Store or Apple Developer Downloads. If it is already
installed, finish setup from Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

After that, rerun this script.
MSG
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  cat <<'MSG'
Xcode is installed, but the iOS SDK is not ready yet.

Run these once in Terminal:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

After that, rerun this script.
MSG
  exit 1
fi

"$APPLE_DIR/Scripts/build-xcframework.sh" --olcrtc-root "$OLCRTC_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "xcodegen is not installed. Install it, then run: cd apple && xcodegen generate"
    exit 1
  fi
fi

cd "$APPLE_DIR"
xcodegen generate

echo "Ready: $APPLE_DIR/Godwit.xcodeproj"
