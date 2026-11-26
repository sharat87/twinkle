#!/usr/bin/env bash
# Builds build/Twinkle.app.
# Usage: ./build.sh [debug|release] [run] [--profile <folder>] [--unsafe]
# With --profile, runs a separate Twinkle that keeps everything in <folder>
# (created if missing) and leaves the usual one, and its data, alone.
# --unsafe (with --profile) builds build/Twinkle Unsafe.app instead: ad-hoc
# signed, so no keychain password is asked for, for testing. It has its own
# bundle identifier and so its own sandbox container, can't reach the usual
# Twinkle's data, and won't start without a profile.
set -euo pipefail
cd "$(dirname "$0")"

config=release
run=""
profile=""
unsafe=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    debug|release) config="$1" ;;
    run) run=1 ;;
    --profile) mkdir -p "$2"; profile="$(cd "$2" && pwd -P)"; shift ;;
    --unsafe) unsafe=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
if [[ -n "$unsafe" && -z "$profile" ]]; then
  echo "--unsafe needs --profile <folder under /tmp>: the unsafe build only runs with a test profile." >&2
  exit 1
fi

# Signed with this Mac's own identity and sandboxed. No ad-hoc fallback: an
# unsigned or ad-hoc Twinkle would leave its cookies readable by any app.
# (The unsafe build is ad-hoc, but has a container of its own; see above.)
identity="Twinkle Local Signing"
if [[ -z "$unsafe" ]] && ! security find-identity -p codesigning | grep -q "\"$identity\""; then
  echo "No \"$identity\" identity in your keychain. Run scripts/make-signing-identity.sh once, then build again." >&2
  exit 1
fi

# The running Twinkles for this profile (none: the usual one), found by the
# instance.lock each one holds open. A restarted Twinkle has no --profile
# argument, so arguments only tell old builds, which hold no lock, apart.
lock_dir="${profile:-$HOME/Library/Containers/dev.twinkle.Twinkle/Data/Library/Application Support/Twinkle}"
instances() {
  local locked
  locked="$(lsof -a -c Twinkle -Fpn 2>/dev/null | awk -v want="$lock_dir/instance.lock" '
    /^p/ { pid = substr($0, 2) } /^n/ { if (substr($0, 2) == want) print pid; if ($0 ~ /\/instance\.lock$/) any[pid] = 1 }
    END { for (p in any) print "any " p }')"
  for pid in $(pgrep -x Twinkle); do
    if grep -qx "$pid" <<<"$locked"; then echo "$pid"; continue; fi
    grep -qx "any $pid" <<<"$locked" && continue
    args="$(ps -o args= -p "$pid" || true)"
    if [[ -n "$profile" ]]; then
      [[ "$args " == *"--profile $profile "* ]] && echo "$pid"
    else
      [[ "$args" != *"--profile "* ]] && echo "$pid"
    fi
  done
  true
}
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/Twinkle"

app="build/Twinkle.app"
[[ -n "$unsafe" ]] && app="build/Twinkle Unsafe.app"
if [[ -n "$run" ]]; then
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
if [[ -n "$unsafe" ]]; then
  # Its own identifier (Integrity.unsafeBundleID), and none of the
  # entitlements that reach outside its container: not the usual Twinkle's
  # old data, nor Safari's. Only /tmp, for the profile.
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.twinkle.Twinkle.unsafe" \
    -c "Set :CFBundleName Twinkle Unsafe" -c "Set :CFBundleDisplayName Twinkle Unsafe" "$plist"
  entitlements=".build/Twinkle-unsafe.entitlements"
  cp Resources/Twinkle.entitlements "$entitlements"
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.temporary-exception.files.home-relative-path.read-only" \
    -c "Delete :com.apple.security.temporary-exception.files.home-relative-path.read-write" "$entitlements"
  codesign --force --options runtime --entitlements "$entitlements" --sign - "$app" >/dev/null
else
  # Sandboxed, signed with the identity checked above.
  codesign --force --options runtime --entitlements Resources/Twinkle.entitlements --sign "$identity" "$app" >/dev/null
fi
echo "Built $app"

if [[ -n "$run" ]]; then
  if [[ -n "$profile" ]]; then
    for _ in 1 2 3; do open -n "$PWD/$app" --args --profile "$profile" && break; sleep 1; done
  else
    for _ in 1 2 3; do open "$PWD/$app" && break; sleep 1; done
  fi
fi
