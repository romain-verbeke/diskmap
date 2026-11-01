#!/bin/zsh
# Runs tests. With only the Command Line Tools, the Testing framework must be located explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
libs="$(xcode-select -p)/Library/Developer/usr/lib"
swift test -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs" "$@"
