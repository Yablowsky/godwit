#!/usr/bin/env bash

prepare_mobile_tools() {
  local scripts_dir
  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$scripts_dir/../build-versions.env"
  export GOTOOLCHAIN="go$GODWIT_GO_VERSION"
  local tools_dir="$scripts_dir/../.build/mobile-tools/bin"
  mkdir -p "$tools_dir"

  local tool
  for tool in gomobile gobind; do
    if [[ ! -x "$tools_dir/$tool" ]] || ! go version -m "$tools_dir/$tool" | awk -v wanted="$GOMOBILE_VERSION" '
      $1 == "mod" && $2 == "golang.org/x/mobile" && $3 == wanted { found = 1 }
      END { exit !found }
    '; then
      GOBIN="$tools_dir" go install "golang.org/x/mobile/cmd/$tool@$GOMOBILE_VERSION"
    fi
  done
  export PATH="$tools_dir:$PATH"
  gomobile init
}
