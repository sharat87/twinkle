#!/usr/bin/env bash
# Runs the TwinkleCore tests. With only the Command Line Tools installed (no
# Xcode), SwiftPM doesn't find the swift-testing macro plugin on its own.
set -euo pipefail
cd "$(dirname "$0")"
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$plugins" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
