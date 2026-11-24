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
cp "$(dirname "$bin")/twinkle-query" "$app/Contents/MacOS/twinkle-query"
cp Resources/Info.plist "$app/Contents/Info.plist"
# The icon is drawn by a script; redrawn only when the script changes.
icon=.build/AppIcon.icns
[[ -f "$icon" && "$icon" -nt scripts/make-icon.swift ]] || swift scripts/make-icon.swift "$icon"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run locally.
codesign --force --sign - "$app" >/dev/null
echo "Built $app"

# The Alfred workflow: double-click build/Twinkle Address.alfredworkflow to
# install or update it.
wf=build/workflow
rm -rf "$wf" "build/Twinkle Address.alfredworkflow"
mkdir -p "$wf"
cp alfred/info.plist "$wf/info.plist"
sips -s format png -z 256 256 "$icon" --out "$wf/icon.png" >/dev/null
(cd "$wf" && zip -qr "../Twinkle Address.alfredworkflow" .)
rm -rf "$wf"

if [[ "${2:-}" == "run" ]]; then
  for _ in 1 2 3; do open "$PWD/$app" && break; sleep 1; done
fi
