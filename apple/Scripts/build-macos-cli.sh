#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPLE_DIR="$ROOT_DIR/apple"
OUT="$APPLE_DIR/.build/olcrtc-macos"

usage() {
  cat <<'MSG'
Usage:
  ./apple/Scripts/build-macos-cli.sh --olcrtc-root /path/to/olcrtc

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
OLCRTC_DIR="$(require_olcrtc_root "$OLCRTC_ROOT_ARG" "Usage: ./apple/Scripts/build-macos-cli.sh --olcrtc-root /path/to/olcrtc")"

mkdir -p "$(dirname "$OUT")"
source "$APPLE_DIR/build-versions.env"
export GOTOOLCHAIN="go$GODWIT_GO_VERSION"
cd "$OLCRTC_DIR"

go build \
  -trimpath \
  -ldflags="-s -w" \
  -o "$OUT" \
  ./cmd/olcrtc

echo "Built $OUT"
