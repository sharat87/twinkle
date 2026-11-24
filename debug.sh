#!/usr/bin/env bash
# Asks the running Twinkle to dump its state, then prints it.
#   ./debug.sh                          dump state
#   ./debug.sh open <url> [container]   open a tab, optionally in a container
# Writes state.json, window.png, page.png to ~/Library/Application Support/Twinkle/debug/.
set -euo pipefail
cd "$(dirname "$0")"
dir="$HOME/Library/Application Support/Twinkle/debug"
tool=.build/post-notification
[[ -x "$tool" && "$tool" -nt scripts/post-notification.swift ]] || swiftc -o "$tool" scripts/post-notification.swift
if [[ "${1:-}" == "open" ]]; then
  "$tool" dev.twinkle.debug.open "$2"$'\t'"${3:-}"
  exit 0
fi
rm -f "$dir/state.json"
"$tool" dev.twinkle.debug.dump
for _ in $(seq 1 20); do [[ -f "$dir/state.json" ]] && break; sleep 0.25; done
for _ in $(seq 1 20); do [[ -f "$dir/page.png" || -f "$dir/page-error.txt" ]] && break; sleep 0.25; done
cat "$dir/state.json"
[[ -f "$dir/page-error.txt" ]] && cat "$dir/page-error.txt"
echo
echo "Images: $dir/window.png $dir/page.png"
