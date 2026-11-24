#!/usr/bin/env bash
# Builds build/Twinkle.app. Usage: ./build.sh [debug|release] [run]
set -euo pipefail
cd "$(dirname "$0")"

config="${1:-release}"
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/Twinkle"

app="build/Twinkle.app"
if [[ "${2:-}" == "run" ]]; then
  # Quit the running copy first (it saves its session) and wait for it to
  # go, or Launch Services may refuse to open the new one (error -600).
  pkill -x Twinkle 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -x Twinkle >/dev/null || break; sleep 0.1; done
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Twinkle"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Ad-hoc signature: enough to run locally.
codesign --force --sign - "$app" >/dev/null
echo "Built $app"

if [[ "${2:-}" == "run" ]]; then
  for _ in 1 2 3; do open "$PWD/$app" && break; sleep 1; done
fi
