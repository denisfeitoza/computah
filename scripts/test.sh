#!/bin/zsh
# Offline unit tests. Command Line Tools ship Swift Testing outside the default search path.
set -eu
cd "${0:A:h:h}"
# Command Line Tools 27 ship a macOS 27 SDK whose SwiftUI needs a macro plugin that only Xcode
# provides. Without Xcode, build against the newest macOS 26 SDK that is still installed.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
  older_sdk="$(ls -d "$(xcode-select -p)"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
  if [[ -n "$older_sdk" ]] && ! find "$(xcode-select -p)" -iname '*SwiftUIMacros*' -print -quit | grep -q .; then
    export SDKROOT="$older_sdk"
  fi
fi
# iCloud-synced folders add Finder metadata that breaks codesigning the test bundle.
scratch="$HOME/Library/Caches/computah/test-build"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
  exec swift test --scratch-path "$scratch" -Xswiftc -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib" "$@"
fi
exec swift test --scratch-path "$scratch" "$@"
