#!/usr/bin/env bash
# Builds build/Twinkle.app. Usage: ./build.sh [debug|release] [run]
set -euo pipefail
cd "$(dirname "$0")"

config="${1:-release}"
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/Twinkle"

app="build/Twinkle.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Twinkle"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Ad-hoc signature: enough to run locally.
codesign --force --sign - "$app" >/dev/null
echo "Built $app"

if [[ "${2:-}" == "run" ]]; then
  pkill -x Twinkle 2>/dev/null || true
  open "$app"
fi
