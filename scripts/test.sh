#!/bin/zsh
# Offline unit tests. Command Line Tools ship Swift Testing outside the default search path.
set -eu
cd "${0:A:h:h}"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
  exec swift test -Xswiftc -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib" "$@"
fi
exec swift test "$@"
