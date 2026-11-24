# Twinkle

A small, fast web browser for macOS, built on the system's WebKit.

- **Tabs down the left**, one address field, the page. No start page, no accounts.
- **Containers**, like Firefox's Multi-Account Containers: tabs in one window, each container with its own cookies, storage and cache.
- **The page's host in the window title** (`Title - example.com`), so KeePassXC auto-type matches sites without a browser extension.
- **Ad and tracker blocking** with EasyList and EasyPrivacy (or any EasyList/uBlock-syntax list, or hosts file), compiled into WebKit content blockers that run before requests are made.
- **No permission prompts.** Camera, microphone and screen capture are always denied. Location and web notifications don't exist here.
- **Settings in plain files**, re-read whenever the app comes to the front.

## Build and run

Needs macOS 14+ and Swift 6 (the Command Line Tools are enough; Xcode isn't needed).

```sh
./build.sh            # release build → build/Twinkle.app
./build.sh debug run  # debug build, then (re)launch it
./test.sh             # tests for TwinkleCore
```

## Files

Everything lives in `~/Library/Application Support/Twinkle/`:

| File | What |
|---|---|
| `settings.json` | Search engine, window title format, downloads folder, filter lists, sites with blocking off. Missing keys take defaults. |
| `containers.json` | Containers: `id` (keys the cookie jar; keep it), `name`, `color`. |
| `session.json` | Open tabs, restored at launch. |
| `filters/custom.txt` | Your own filter rules. |
| `filters/cache/` | Downloaded filter lists. |

The Twinkle menu opens each of these. WebKit keeps each container's site data under `~/Library/WebKit/dev.twinkle.Twinkle/`.

### settings.json

```json
{
  "searchURL": "https://duckduckgo.com/?q=%s",
  "windowTitleFormat": "{title} - {host}",
  "downloadsDirectory": "~/Downloads",
  "adBlocking": true,
  "adBlockingOffFor": ["example.com"],
  "filterLists": [
    "https://easylist.to/easylist/easylist.txt",
    "https://easylist.to/easylist/easyprivacy.txt"
  ],
  "filterListRefreshDays": 4
}
```

## Keys

| | |
|---|---|
| `⌘T` new tab (same container) · `⌃⌘0` new tab, no container · `⌃⌘1`–`9` new tab in container | `⌘W` close · `⇧⌘T` reopen closed tab |
| `⌘L` address · `⌘F` find · `⌘G` / `⇧⌘G` next / previous | `⌘[` / `⌘]` back / forward · `⌘R` reload · `⌥⌘R` reload from origin |
| `⌃Tab` / `⌃⇧Tab`, `⇧⌘]` / `⇧⌘[` next / previous tab · `⌘1`–`⌘9` jump | `⌘+` / `⌘-` / `⌘0` zoom · `⌃⌘S` sidebar · `⇧⌘N` new container |

⌘-click or middle-click a link to open it in a background tab in the same container; add ⇧ to switch to it. Right-click a tab to reopen it in another container. Right-click a page › Inspect Element opens Safari's Web Inspector.

## Code

```
Sources/TwinkleCore/   Foundation only: settings, containers, session, address
                       parsing, window titles, the filter-list converter.
                       Nothing Mac-specific, so another platform's shell
                       (e.g. WebKitGTK on Linux) could reuse it.
Sources/Twinkle/       The macOS app (AppKit + WKWebView).
  BrowserWindowController  window, sidebar, toolbar, find bar, session
  Tab                      one web view: navigation, pop-ups, downloads, dialogs, permissions
  Blocker                  filter lists → compiled WKContentRuleLists
  AppState                 settings/containers files, one data store per container
  Downloads                WKDownload to the downloads folder
  Debug                    inspection hook used by debug.sh
```

The content-blocker JSON that `FilterConverter` produces is WebKit's format, which WebKitGTK also reads, and the data files are plain JSON. Porting means writing a new shell, not translating data.

### Looking inside a running Twinkle

`./debug.sh` asks the running app to write `state.json` (tabs, titles, URLs, loading state), `text.json` (each loaded tab's text), `window.png` and `page.png` to `~/Library/Application Support/Twinkle/debug/`, then prints the state. `./debug.sh open <url> [container]` opens a tab. This works without Screen Recording permission. The page snapshot needs the window to be visible on screen.
