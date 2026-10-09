#!/usr/bin/env bash

require_olcrtc_root() {
  local scripts_dir
  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$scripts_dir/../build-versions.env"
  local raw="${1:-${OLCRTC_REPO_ROOT:-}}"
  local usage="${2:-Set OLCRTC_REPO_ROOT=/path/to/olcrtc or pass --olcrtc-root /path/to/olcrtc.}"

  if [[ -z "$raw" ]]; then
    echo "OlcRTC repository path is required." >&2
    echo "$usage" >&2
    echo "Or export OLCRTC_REPO_ROOT=/path/to/olcrtc before running multiple scripts." >&2
    exit 1
  fi

  local resolved
  if [[ "$raw" == /* ]]; then
    resolved="$raw"
  else
    resolved="$(cd "$raw" 2>/dev/null && pwd)" || {
      echo "OlcRTC repository path does not exist: $raw" >&2
      exit 1
    }
  fi

  if [[ ! -f "$resolved/go.mod" || ! -d "$resolved/mobile" || ! -d "$resolved/pkg/olcrtc" ]]; then
    echo "Invalid OlcRTC repository path: $resolved" >&2
    echo "Expected go.mod, mobile/, and pkg/olcrtc/ under the provided path." >&2
    exit 1
  fi

  local revision
  revision="$(git -C "$resolved" rev-parse HEAD 2>/dev/null)" || {
    echo "OlcRTC must be a Git checkout at $OLCRTC_REVISION." >&2
    exit 1
  }
  if [[ "$revision" != "$OLCRTC_REVISION" ]]; then
    echo "OlcRTC revision mismatch: expected $OLCRTC_REVISION, got $revision." >&2
    echo "Prepare a separate checkout at the pinned revision; do not overwrite a working server checkout." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$resolved" status --porcelain --untracked-files=normal)" ]]; then
    echo "OlcRTC checkout has local changes. Use a clean checkout for this build." >&2
    exit 1
  fi

  printf '%s\n' "$resolved"
}
