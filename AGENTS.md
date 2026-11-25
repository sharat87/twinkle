# Notes for agents working on Twinkle

## Scope

Twinkle is deliberately minimal and meant to be finished soon (see the README). Don't add UI surface: no preference panes, toolbar buttons, command palette or in-app editors. Configuration is a JSON file the user edits; a command is a menu item (that's how it gets a shortcut and is found by Alfred/Raycast). Permissions are denied, not prompted. If a feature seems to need more than that, ask first.

## Build, test, run

- `./build.sh release run` builds `build/Twinkle.app`, quits the running copy and opens the new one.
- `./test.sh` runs the TwinkleCore tests (it finds the swift-testing plugin when only the Command Line Tools are installed; plain `swift test` fails there). `./test.sh -c release --filter fastOnABigHistory` for timings.
- `./debug.sh` inspects and drives the running app without screen recording: it dumps state, window, page and dropdown images to `~/Library/Application Support/Twinkle/debug/`, and can open tabs, select tabs, type into the address field, press keys there, and run menu commands. See the top of `debug.sh`.

## Testing against real sites

- For HTTP testing (cookies, redirects, headers, JSON, status codes) use **httpbun.com**, e.g. `https://httpbun.com/cookies/set?name=value`, `https://httpbun.com/cookies`, `https://httpbun.com/get`, `https://httpbun.com/redirect-to?url=…`. **Never use httpbin.org.**
- Use example.com for a plain page.

## The user's data

`~/Library/Application Support/Twinkle/` holds the user's real session, history, bookmarks, containers and settings.

- **Test in a separate profile, not the user's running Twinkle**: `./build.sh release run --profile <folder>` starts a second Twinkle that keeps everything in `<folder>` (use the scratchpad), with its own cookies and compiled filter lists, and only quits/replaces that profile's instance. Drive it with `TWINKLE_PROFILE=<folder> ./debug.sh …`; its dumps land in `<folder>/debug/`. Plain `./build.sh release run` quits and restarts the user's own Twinkle, so only do that when they ask.
- If you must test in the user's own Twinkle, back up `session.json` and `history.sqlite` before testing in the running app, then restore them, or remove what the test added, afterwards. Quit Twinkle before restoring: it saves its session when it quits.
- Don't print history or cookies wholesale; they hold private addresses and tokens.

## Git

- Commit every change as soon as it's done and verified; never leave the working copy dirty. A follow-up fix to the same change can amend that commit.
