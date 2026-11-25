# Notes for agents working on Twinkle

## Build, test, run

- `./build.sh release run` builds `build/Twinkle.app`, quits the running copy and opens the new one.
- `./test.sh` runs the TwinkleCore tests (it finds the swift-testing plugin when only the Command Line Tools are installed; plain `swift test` fails there). `./test.sh -c release --filter fastOnABigHistory` for timings.
- `./debug.sh` inspects and drives the running app without screen recording: it dumps state, window, page and dropdown images to `~/Library/Application Support/Twinkle/debug/`, and can open tabs, select tabs, type into the address field, press keys there, and run menu commands. See the top of `debug.sh`.

## Testing against real sites

- For HTTP testing (cookies, redirects, headers, JSON, status codes) use **httpbun.com**, e.g. `https://httpbun.com/cookies/set?name=value`, `https://httpbun.com/cookies`, `https://httpbun.com/get`, `https://httpbun.com/redirect-to?url=…`. **Never use httpbin.org.**
- Use example.com for a plain page.

## The user's data

`~/Library/Application Support/Twinkle/` holds the user's real session, history, bookmarks, containers and settings.

- Back up `session.json` and `history.sqlite` before testing in the running app, then restore them, or remove what the test added, afterwards. Quit Twinkle before restoring: it saves its session when it quits.
- Don't print history or cookies wholesale; they hold private addresses and tokens.

## Git

- Commit every change as soon as it's done and verified; never leave the working copy dirty. A follow-up fix to the same change can amend that commit.
