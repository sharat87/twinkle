#!/usr/bin/env bash
# Builds build/Twinkle.app. Usage: ./build.sh [debug|release] [run [--profile <folder>]]
# With --profile, runs a separate Twinkle that keeps everything in <folder>
# (created if missing) and leaves the usual one, and its data, alone.
set -euo pipefail
cd "$(dirname "$0")"

config="${1:-release}"
profile=""
if [[ "${3:-}" == "--profile" ]]; then
  mkdir -p "$4"
  profile="$(cd "$4" && pwd -P)"
fi

# The running Twinkles for this profile (none: the usual one).
instances() {
  for pid in $(pgrep -x Twinkle); do
    args="$(ps -o args= -p "$pid" || true)"
    if [[ -n "$profile" ]]; then
      [[ "$args" == *"--profile $profile" ]] && echo "$pid"
    else
      [[ "$args" != *"--profile "* ]] && echo "$pid"
    fi
  done
  true
}
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/Twinkle"

app="build/Twinkle.app"
if [[ "${2:-}" == "run" ]]; then
  # Quit the running copy first (it saves its session) and wait for it to
  # go, or Launch Services may refuse to open the new one (error -600).
  pids="$(instances)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do [[ -z "$(instances)" ]] && break; sleep 0.1; done
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Twinkle"
cp Resources/Info.plist "$app/Contents/Info.plist"
# The icon is drawn by a script; redrawn only when the script changes.
icon=.build/AppIcon.icns
[[ -f "$icon" && "$icon" -nt scripts/make-icon.swift ]] || swift scripts/make-icon.swift "$icon"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run locally.
codesign --force --sign - "$app" >/dev/null
echo "Built $app"

if [[ "${2:-}" == "run" ]]; then
  if [[ -n "$profile" ]]; then
    for _ in 1 2 3; do open -n "$PWD/$app" --args --profile "$profile" && break; sleep 1; done
  else
    for _ in 1 2 3; do open "$PWD/$app" && break; sleep 1; done
  fi
fi
