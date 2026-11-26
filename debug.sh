#!/usr/bin/env bash
# Asks the running Twinkle to dump its state, then prints it.
#   ./debug.sh                          dump state
#   ./debug.sh open <url> [container]   open a tab, optionally in a container
#                                       ("temporary" makes a temporary one)
#   ./debug.sh select <index>           bring a tab to the front
#   ./debug.sh type <text>              ⌘L, then type into the address field
#   ./debug.sh key <down|up|enter|cmd-enter|tab|escape|delete>
#   ./debug.sh key <ctrl-tab|ctrl-shift-tab|ctrl-up>   ⌃Tab switcher: step, let go of ⌃
#   ./debug.sh press <keys>             key presses to wherever the focus is: text, {return},
#                                       {escape}, {delete}, {tab}, {cmd-i}, {cmd-return}; `action` for ⇧ shortcuts
#   ./debug.sh action <selector:>        run a menu command
#   ./debug.sh mouse <button>           click a mouse button mid-window (3 back, 4 forward)
#   ./debug.sh mouse "left <x> <y>"     left-click at x, y points from the window's top left
#   ./debug.sh appearance <light|dark|system>   for screenshots of both
#   ./debug.sh applescript <script>     run AppleScript inside a tell to Twinkle, print the result
# Writes state.json, window.png, page.png (switcher.png while the ⌃Tab list is up) to Twinkle's folder in its sandbox
# container (~/Library/Containers/dev.twinkle.Twinkle/…/Twinkle/debug/).
# TWINKLE_PROFILE=<folder> ./debug.sh … drives the Twinkle started with
# `./build.sh release run --profile <folder>` instead, and its files are in <folder>/debug/.
set -euo pipefail
cd "$(dirname "$0")"
# The usual Twinkle is sandboxed: its dumps are in its container, which
# macOS keeps from other apps (debug.sh included) unless you allow it.
dir="$HOME/Library/Containers/dev.twinkle.Twinkle/Data/Library/Application Support/Twinkle/debug"
suffix=""
if [[ -n "${TWINKLE_PROFILE:-}" ]]; then
  profile="$(cd "$TWINKLE_PROFILE" && pwd -P)"
  dir="$profile/debug"
  suffix=":$profile"
fi
tool=.build/post-notification
[[ -x "$tool" && "$tool" -nt scripts/post-notification.swift ]] || swiftc -o "$tool" scripts/post-notification.swift
if [[ "${1:-}" == "open" ]]; then
  "$tool" "dev.twinkle.debug.open$suffix" "$2"$'\t'"${3:-}"
  exit 0
fi
if [[ "${1:-}" == "applescript" ]]; then
  rm -f "$dir/applescript.txt"
  "$tool" "dev.twinkle.debug.applescript$suffix" "$2"
  for _ in $(seq 1 40); do [[ -f "$dir/applescript.txt" ]] && break; sleep 0.25; done
  cat "$dir/applescript.txt"
  exit 0
fi
if [[ "${1:-}" =~ ^(select|type|key|press|action|mouse|appearance)$ ]]; then
  "$tool" "dev.twinkle.debug.$1$suffix" "${2:-}"
  exit 0
fi
rm -f "$dir/state.json"
"$tool" "dev.twinkle.debug.dump$suffix"
for _ in $(seq 1 20); do [[ -f "$dir/state.json" ]] && break; sleep 0.25; done
for _ in $(seq 1 20); do [[ -f "$dir/page.png" || -f "$dir/page-error.txt" ]] && break; sleep 0.25; done
cat "$dir/state.json"
[[ -f "$dir/page-error.txt" ]] && cat "$dir/page-error.txt"
echo
echo "Images: $dir/window.png $dir/page.png"
