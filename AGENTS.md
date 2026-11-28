# Notes for agents working on Twinkle

## Scope

Twinkle is deliberately minimal and meant to be finished soon (see the README). Don't add UI surface: no preference panes, toolbar buttons, command palette or in-app editors. Configuration is a JSON file the user edits; a command is a menu item (that's how it gets a shortcut and is found by Alfred/Raycast). Permissions are denied, not prompted. If a feature seems to need more than that, ask first.

## Build, test, run

- `./build.sh release run` builds `build/Twinkle.app`, quits the running copy and opens the new one. It signs with the user's "Twinkle Local Signing" identity (scripts/make-signing-identity.sh) and the sandbox entitlements in `Resources/Twinkle.entitlements`; there is deliberately no ad-hoc fallback, and Twinkle refuses to start unsandboxed (Integrity.swift). Keep it that way.
- Signing with that identity can stop at a keychain password prompt only the user can answer. For your own testing use `./build.sh release run --unsafe --profile <folder>` instead: it builds `build/Twinkle Unsafe.app`, ad-hoc signed (no prompt), still sandboxed, under its own bundle identifier (so its own container, never the user's data), without the entitlements that reach outside it, and it won't start without a profile. Don't widen any of that.
- Twinkle › Restart Twinkle relaunches `build/Twinkle.app`, not the unsafe build. `scripts/hooks/post-commit` rebuilds it in the background after every commit (log in `build/post-commit.log`), so the user's Restart picks up each committed change. Git doesn't turn on checked-in hooks by itself: if `git config core.hooksPath` doesn't print `scripts/hooks`, run `git config core.hooksPath scripts/hooks` (once per clone) and tell the user you did and why. It needs the signing identity above; without it the hook's build just fails in the log.
- `./test.sh` runs the TwinkleCore tests (it finds the swift-testing plugin when only the Command Line Tools are installed; plain `swift test` fails there). `./test.sh -c release --filter fastOnABigHistory` for timings.
- `TWINKLE_PROFILE=<folder> ./debug.sh` inspects and drives a `--profile` Twinkle without screen recording (the user's own Twinkle doesn't listen to it, deliberately: anything could send it commands): it dumps state, window, page and dropdown images to the profile's `debug/` folder, and can open tabs, select tabs, type into the address field, press keys there, and run menu commands. See the top of `debug.sh`.

## Testing against real sites

- For HTTP testing (cookies, redirects, headers, JSON, status codes) use **httpbun.com**, e.g. `https://httpbun.com/cookies/set?name=value`, `https://httpbun.com/cookies`, `https://httpbun.com/get`, `https://httpbun.com/redirect-to?url=…`. **Never use httpbin.org.**
- Use example.com for a plain page.

## The user's data

Twinkle's sandbox container (`~/Library/Containers/dev.twinkle.Twinkle/`) holds the user's real session, history, bookmarks, containers, settings and cookies. macOS keeps it from other apps, you included; don't ask the user to grant access to it.

- **Test in a separate profile, not the user's running Twinkle**: `./build.sh release run --unsafe --profile <folder>` starts a second Twinkle that keeps everything in `<folder>` (use the scratchpad; it must be under `/tmp`, the only place the sandbox lets it write), with its own cookies and compiled filter lists, and only quits/replaces that profile's instance. Drive it with `TWINKLE_PROFILE=<folder> ./debug.sh …`; its dumps land in `<folder>/debug/`. Plain `./build.sh release run` quits and restarts the user's own Twinkle, so only do that when they ask. When you're done, quit your test Twinkle and delete its profile folder.
- You can't read the user's own Twinkle's files, and it ignores debug.sh; test in a profile. If something can only be checked in their Twinkle, ask them to check it.
- Don't print history or cookies wholesale; they hold private addresses and tokens.

## Git

- Commit every change as soon as it's done and verified; never leave the working copy dirty. A follow-up fix to the same change can amend that commit.
