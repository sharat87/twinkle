# Twinkle

A minimal web browser for macOS, built on the system's WebKit. Vibed just for myself; I expect it to be "finished" after a few weeks of use, so it's not looking for features.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img alt="Twinkle showing Apple's WKWebView documentation in a Work container, with the tab list on the right" src="docs/screenshot-light.png">
</picture>

**The UI surface is kept small:**

- **Settings, containers and bookmarks are JSON files** you edit in your text editor. No preferences window. They're re-read whenever Twinkle comes to the front.
- **Everything is in the menu bar.** No command palette, no toolbar buttons. For a fuzzy finder, use one for menu items, like Alfred or Raycast.
- **Shortcuts are changed in macOS**, under System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts, as for any menu item.
- **No dev tools of its own.** Inspect Element opens Safari's Web Inspector.
- **No MCP.** Once AppleScript support is added, ask your agent to write AppleScript.
- **Permissions are always denied.** Camera, microphone and screen capture are refused without asking. Location and web notifications aren't implemented at all.

<img alt="Twinkle's Tools menu open over a GitHub page: every action is a menu item, and the address field is in Monaco so look-alike letters stand apart" src="docs/screenshot-menus.png" width="751">

## What's there

- **Tabs down the right**, one address field, the page. No start page, no accounts. A speaker marks tabs playing sound; ⌃Tab goes back through tabs in the order you used them, listed beside the tab list while ⌃ is held.
- **Containers**, like Firefox's Multi-Account Containers: tabs in one window, each container with its own cookies, storage and cache. Sites can be assigned to a container so they always open there.
- **Temporary containers**: a throwaway cookie jar, kept only in memory and gone when its last tab closes.
- **Idle tabs unload** after 30 minutes in the background, freeing their memory, and come back with their history when clicked. Tabs playing sound or holding a half-filled form are left alone.
- **The address in full, in Monaco**, a monospaced font, so look-alike letters (`l`, `I`, `1`; `O`, `0`) can't pass for each other in a lookalike domain.
- **The response status beside the address**, like `200 OK`, orange for 4xx and red for 5xx. A padlock (or a certificate or mixed-content warning) sits before it.
- **The page's host in the window title** (`Title (example.com)`), so KeePassXC auto-type matches sites without a browser extension.
- **Ad and tracker blocking** with EasyList and EasyPrivacy (or any EasyList/uBlock-syntax list, or hosts file), compiled into WebKit content blockers that run before requests are made.
- **JSON responses pretty-printed** and highlighted, with exact numbers and key order (Raw shows the original).
- **Address bar suggestions**: history and open tabs, fuzzy-matched like Sublime Text, with inline completion of addresses you've visited.

## Build and run

Needs macOS 14+ and Swift 6 (the Command Line Tools are enough; Xcode isn't needed).

Twinkle runs in the App Sandbox, signed with a code signing identity of your own, so macOS keeps its cookies, site data and history from other apps (they'd otherwise be plain files any script could read). Make the identity once per Mac:

```sh
scripts/make-signing-identity.sh   # "Twinkle Local Signing", in your login keychain
```

The first build then asks for your login password so `codesign` can use it; choose Always Allow. The private key stays in your keychain; never copy or commit it. Without the identity `./build.sh` won't build, and an unsandboxed or ad-hoc signed Twinkle won't start.

```sh
./build.sh            # release build → build/Twinkle.app
./build.sh debug run  # debug build, then (re)launch it
./test.sh             # tests for TwinkleCore
```

Twinkle › Restart Twinkle quits and opens the app again, so a rebuild with `./build.sh` takes effect when you're ready.

`--profile <folder>` runs a separate Twinkle that keeps everything in that folder, with its own cookies and filter lists, for testing without touching your own: `./build.sh release run --profile <folder>`. The sandbox only allows profile folders under `/tmp`.

`--unsafe` (only with `--profile`) builds `build/Twinkle Unsafe.app` instead, ad-hoc signed so no password is asked for: handy for agents and scripts. It's still sandboxed, but as a different app (`dev.twinkle.Twinkle.unsafe`) with its own container, so it can't reach your Twinkle's cookies or data, and it won't start without a profile.

## Files

Everything lives in Twinkle's sandbox container, in `~/Library/Containers/dev.twinkle.Twinkle/Data/Library/Application Support/Twinkle/`. The first time another app (your text editor, say) opens one of these, macOS asks whether it may access Twinkle's data. An unsandboxed Twinkle's files, from `~/Library/Application Support/Twinkle/` and `~/Library/WebKit/dev.twinkle.Twinkle/`, are moved in at the first sandboxed launch.

| File | What |
|---|---|
| `settings.json` | Search engine, window title format, downloads folder, filter lists, sites with blocking off. Missing keys take defaults. |
| `containers.json` | Containers: `id` (keys the cookie jar; keep it), `name`, `color`, `sites` (always open in this container). |
| `session.json` | Open tabs, restored at launch. |
| `filters/custom.txt` | Your own filter rules. |
| `filters/cache/` | Downloaded filter lists. |
| `zoom.json` | Zoom level per site, like `{"example.com": 1.25}`. Covers subdomains. |
| `bookmarks.json` | Bookmarks (from Safari), searched by the address bar. |
| `history.sqlite` | Pages visited (address, title, visits, last visit), kept `historyDays`. Not written for temporary containers. History › Clear History empties it. |
| `favicons/` | Site icons for the tab list, one small PNG per host. Not written for temporary containers. |

The Twinkle menu opens each of these. WebKit keeps each container's site data in the container's `Library/WebKit/`. When a container is gone from `containers.json`, its cookies and site data are deleted at the next launch.

Downloads can only go to `~/Downloads` (or a folder in it): that's all the sandbox lets Twinkle write.

### settings.json

```json
{
  "searchURL": "https://duckduckgo.com/?q=%s",
  "windowTitleFormat": "{title} ({host})",
  "downloadsDirectory": "~/Downloads",
  "adBlocking": true,
  "adBlockingOffFor": ["example.com"],
  "filterLists": [
    "https://easylist.to/easylist/easylist.txt",
    "https://easylist.to/easylist/easyprivacy.txt"
  ],
  "filterListRefreshDays": 4,
  "unloadTabsAfterMinutes": 30,
  "historyDays": 180,
  "monospaceFont": "Monaco",
  "monospaceFontSize": 18
}
```

`unloadTabsAfterMinutes: 0` keeps every tab loaded. `historyDays: 0` keeps no history. `monospaceFont` and `monospaceFontSize` (CSS pixels) are what pages asking for `monospace` get, and what plain text and JSON are shown in; they apply to tabs opened after the change. The window title ends in ` (host)` so KeePassXC auto-type can match on it.

### Importing from Safari

File › Import from Safari… copies Safari's history, bookmarks and cookies in. macOS keeps those behind Full Disk Access, so first add Twinkle under System Settings › Privacy & Security › Full Disk Access (the import offers to open it), quit and reopen Twinkle, and import. Turn the access off again afterwards if you like. Twinkle is signed ad hoc, so a rebuild in between makes macOS treat it as a different app.

- History is merged into `history.sqlite`: visits add up, pages older than `historyDays` are left out.
- Bookmarks go into `bookmarks.json` (title, address, folder), which the address bar searches above history. There's no bookmarks bar; edit the file to change them.
- Cookies go into the container their site always opens in, or no container. Expired ones are skipped.

Running it again only adds what's new.

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
| `⌃Tab` recently used tabs (hold `⌃`, tap Tab to go further back, `⇧` reverses, Escape cancels) · `⇧⌘]` / `⇧⌘[` next / previous tab · `⌘1`–`⌘9` jump · `⇧⌘↑` / `⇧⌘↓` move tab up / down | `⌘+` (or `⌘=`) / `⌘-` / `⌘0` zoom, remembered per site · `⌃⌘S` tab list · `⇧⌘N` new container |
| `⌥⇧⌘⌫` clear cookies and data for this site (Tools menu): everything the tab's container holds for the site, then a reload. For sign-ins that get stuck, like AWS. | |

Drag the blank space in the tab list (above, around or below the tabs) to move the window.

⌘-click or middle-click a link to open it in a background tab in the same container; add ⇧ to switch to it. Middle-click a tab to close it. Right-click a tab to reopen it in another container (or a new temporary one), or to unload it now. Right-click a page › Inspect Element opens Safari's Web Inspector.

## Code

```
Sources/TwinkleCore/   Foundation only: settings, containers, session, address
                       parsing, window titles, the filter-list converter,
                       history and its fuzzy search.
                       Nothing Mac-specific, so another platform's shell
                       (e.g. WebKitGTK on Linux) could reuse it.
Sources/Twinkle/       The macOS app (AppKit + WKWebView).
  BrowserWindowController  window, address row, sidebar, find bar, session
  Tab                      one web view: navigation, pop-ups, downloads, dialogs, permissions
  Blocker                  filter lists → compiled WKContentRuleLists
  AppState                 settings/containers files, one data store per container
  Downloads                WKDownload to the downloads folder
  Favicons                 site icons, fetched without cookies
  JSONViewer               pretty-prints JSON responses
  AddressSuggestions       the address bar's dropdown
  Debug                    inspection hook used by debug.sh
scripts/make-icon.swift    draws the app icon (build.sh runs it)
```

The content-blocker JSON that `FilterConverter` produces is WebKit's format, which WebKitGTK also reads, and the data files are plain JSON. Porting means writing a new shell, not translating data.

### Looking inside a running Twinkle

`./debug.sh` asks the running app to write `state.json` (tabs, titles, URLs, loading state), `text.json` (each loaded tab's text), `window.png` and `page.png` to Twinkle's folder in its container (`…/Twinkle/debug/`), then prints the state (with `TWINKLE_PROFILE=<folder>`, the `--profile` Twinkle and `<folder>/debug/`). `./debug.sh open <url> [container]` opens a tab (`temporary` for a new temporary container) and `./debug.sh select <index>` brings one to the front. This works without Screen Recording permission. The page snapshot needs the window to be visible on screen.

## Licence

MIT. See [LICENSE](LICENSE).
