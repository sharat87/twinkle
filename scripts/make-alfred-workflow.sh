#!/usr/bin/env bash
# Builds build/Twinkle.alfredworkflow from alfred/: `t <query>` in Alfred
# searches Twinkle's bookmarks and history (AppleScript `search`).
# Usage: scripts/make-alfred-workflow.sh [install]
# With install, opens it so Alfred imports it (or updates the one it has).
set -euo pipefail
cd "$(dirname "$0")/.."

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp alfred/info.plist alfred/search.js "$stage/"
swift scripts/make-alfred-icons.swift "$stage"
# The workflow's own icon is Twinkle's.
icon=.build/AppIcon.icns
[[ -f "$icon" && "$icon" -nt scripts/make-icon.swift ]] || swift scripts/make-icon.swift "$icon"
sips -s format png -Z 256 "$icon" --out "$stage/icon.png" >/dev/null

mkdir -p build
out="$PWD/build/Twinkle.alfredworkflow"
rm -f "$out"
(cd "$stage" && zip -qr "$out" .)
echo "Built build/Twinkle.alfredworkflow"
[[ "${1:-}" == "install" ]] && open "$out"
true
