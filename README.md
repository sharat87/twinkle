# Twinkle

A small, fast web browser for macOS, built on the system's WebKit.

- **Tabs down the right**, one address field, the page. No start page, no accounts.
- **Containers**, like Firefox's Multi-Account Containers: tabs in one window, each container with its own cookies, storage and cache. Sites can be assigned to a container so they always open there.
- **Temporary containers**: a throwaway cookie jar, kept only in memory and gone when its last tab closes.
- **Idle tabs unload** after 30 minutes in the background, freeing their memory, and come back with their history when clicked. Tabs playing sound or holding a half-filled form are left alone.
- **The page's host in the window title** (`Title - example.com`), so KeePassXC auto-type matches sites without a browser extension.
- **Ad and tracker blocking** with EasyList and EasyPrivacy (or any EasyList/uBlock-syntax list, or hosts file), compiled into WebKit content blockers that run before requests are made.
- **No permission prompts.** Camera, microphone and screen capture are always denied. Location and web notifications don't exist here.
- **JSON responses pretty-printed** and highlighted, with exact numbers and key order (Raw shows the original).
- **Address bar suggestions**: history and open tabs, fuzzy-matched like Sublime Text, with inline completion of addresses you've visited.
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
| `containers.json` | Containers: `id` (keys the cookie jar; keep it), `name`, `color`, `sites` (always open in this container). |
| `session.json` | Open tabs, restored at launch. |
| `filters/custom.txt` | Your own filter rules. |
| `filters/cache/` | Downloaded filter lists. |
| `zoom.json` | Zoom level per site, like `{"example.com": 1.25}`. Covers subdomains. |
| `history.sqlite` | Pages visited (address, title, visits, last visit), kept `historyDays`. Not written for temporary containers. History › Clear History empties it. |
| `favicons/` | Site icons for the tab list, one small PNG per host. Not written for temporary containers. |

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
  "filterListRefreshDays": 4,
  "unloadTabsAfterMinutes": 30,
  "historyDays": 180
}
```

`unloadTabsAfterMinutes: 0` keeps every tab loaded. `historyDays: 0` keeps no history.

### The address bar

Type and suggestions appear under the field: open tabs and history, matched fuzzily like Sublime Text, so the letters need only appear in order (`ghpul` finds github.com/…/pulls, `devswui` the SwiftUI docs). Matches that start words or run together rank higher, then pages visited often and lately, and site roots before deep links. Addresses are matched without their `?query`, so tracking parameters don't match everything; search result pages still match by title.

When what you type is the start of an address you've visited, it's completed inline (`git` → `git|hub.com`); keep typing to replace the completion, ⌫ to drop it.

↑/↓ choose, ↩ opens (or switches to an open tab), ⌘↩ opens in a new tab, ⇥ puts the chosen address in the field to edit, ⎋ closes. The first row is always what the field says: the completed address, or a search.

History is searched in memory (read from `history.sqlite` once), so typing never waits on the disk: about 2 ms a keystroke with the list redrawn, and under 10 ms to search 50,000 pages.

### containers.json

```json
{
  "containers": [
    { "id": "E00727EE-…", "name": "Personal", "color": "#3B82F6", "sites": ["example.com"] },
    { "id": "8BB4415B-…", "name": "Work", "color": "#F97316", "sites": ["mail.example.com", "corp.io"] }
  ]
}
```

A site covers its subdomains, and the most specific entry wins: here `mail.example.com` opens in Work and the rest of `example.com` in Personal. Tools › Always Open This Site In sets it from the menu. A link or redirect to an assigned site moves to its container: a fresh tab is replaced, a tab with history keeps its page and the site opens beside it. Form posts, reloads, back/forward and pop-ups (sign-in windows talk to their opener) never move. Nor does a tab you put somewhere yourself with Reopen in Container, Duplicate, Reopen Closed Tab or a restored session.

## Keys

| | |
|---|---|
| `⌘T` new tab (same container) · `⌃⌘0` new tab, no container · `⌃⌘1`–`9` new tab in container · `⌥⌘T` new temporary container | `⌘W` close · `⇧⌘T` reopen closed tab |
| `⌘L` address · `⌘F` find · `⌘G` / `⇧⌘G` next / previous | `⌘[` / `⌘]` back / forward · `⌘R` reload · `⌥⌘R` reload from origin |
| `⌃Tab` / `⌃⇧Tab`, `⇧⌘]` / `⇧⌘[` next / previous tab · `⌘1`–`⌘9` jump | `⌘+` (or `⌘=`) / `⌘-` / `⌘0` zoom, remembered per site · `⌃⌘S` tab list · `⇧⌘N` new container |

⌘-click or middle-click a link to open it in a background tab in the same container; add ⇧ to switch to it. Middle-click a tab to close it. Right-click a tab to reopen it in another container (or a new temporary one), or to unload it now. Right-click a page › Inspect Element opens Safari's Web Inspector.

## Code

```
Sources/TwinkleCore/   Foundation only: settings, containers, session, address
                       parsing, window titles, the filter-list converter,
                       history and its fuzzy search.
                       Nothing Mac-specific, so another platform's shell
                       (e.g. WebKitGTK on Linux) could reuse it.
Sources/Twinkle/       The macOS app (AppKit + WKWebView).
  BrowserWindowController  window, sidebar, toolbar, find bar, session
  Tab                      one web view: navigation, pop-ups, downloads, dialogs, permissions
  Blocker                  filter lists → compiled WKContentRuleLists
  AppState                 settings/containers files, one data store per container
  Downloads                WKDownload to the downloads folder
  Favicons                 site icons, fetched without cookies
  JSONViewer               pretty-prints JSON responses
  AddressSuggestions       the address bar's dropdown
scripts/make-icon.swift    draws the app icon (build.sh runs it)
  Debug                    inspection hook used by debug.sh
```

The content-blocker JSON that `FilterConverter` produces is WebKit's format, which WebKitGTK also reads, and the data files are plain JSON. Porting means writing a new shell, not translating data.

### Looking inside a running Twinkle

`./debug.sh` asks the running app to write `state.json` (tabs, titles, URLs, loading state), `text.json` (each loaded tab's text), `window.png` and `page.png` to `~/Library/Application Support/Twinkle/debug/`, then prints the state. `./debug.sh open <url> [container]` opens a tab (`temporary` for a new temporary container) and `./debug.sh select <index>` brings one to the front. This works without Screen Recording permission. The page snapshot needs the window to be visible on screen.
