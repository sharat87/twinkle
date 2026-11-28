// Alfred script filter: asks Twinkle to search its bookmarks and history
// (AppleScript `search`, ranked as in the address bar) and lists them.
// Usage: osascript -l JavaScript search.js <bundle id> <query>
function run(argv) {
  const [bundleID, query = ""] = argv;
  const item = (title, subtitle) => ({ title, subtitle, valid: false });
  let app;
  try {
    app = Application(bundleID);
  } catch (e) {
    return JSON.stringify({ items: [item("Twinkle isn't installed", bundleID)] });
  }
  // Don't launch it just to search.
  if (!app.running()) return JSON.stringify({ items: [item("Twinkle isn't running", "Open it to search its bookmarks and history")] });
  let pages;
  try {
    pages = app.search(query.trim(), { limit: 40 });
  } catch (e) {
    return JSON.stringify({ items: [item("Couldn't search Twinkle", String(e))] });
  }
  const display = (url) => url.replace(/^[a-z]+:\/\//i, "").replace(/^www\./, "");
  const items = pages.map((p) => ({
    title: p.title || display(p.url),
    subtitle: display(p.url),
    arg: p.url,
    icon: { path: p.bookmarked ? "bookmark.png" : "history.png" },
    quicklookurl: p.url,
    text: { copy: p.url, largetype: p.url },
  }));
  if (!items.length) items.push(item("No bookmarks or history match", query));
  return JSON.stringify({ items });
}
