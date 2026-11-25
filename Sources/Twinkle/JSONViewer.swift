import WebKit

/// Pretty-prints and highlights JSON responses. WebKit shows JSON as plain
/// text in a `<pre>`; this script (in Twinkle's own script world, so the page
/// can't see or change it) re-lays that text out.
///
/// It re-indents the original tokens rather than parsing and re-printing, so
/// numbers keep their exact digits (64-bit ids survive) and keys keep their
/// order. "Raw" switches back to the text as sent.
@MainActor
enum JSONViewer {
    static let script = WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true, in: .defaultClient)

    static func install(_ controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0 === script }) else { return }
        controller.addUserScript(script)
    }

    private static let source = #"""
    (() => {
      const type = (document.contentType || '').toLowerCase();
      if (!(type === 'application/json' || type.endsWith('+json'))) return;
      const pre = document.body && document.body.querySelector('pre');
      if (!pre || document.body.children.length !== 1) return;
      const raw = pre.textContent;
      if (raw.length > 20e6) return;
      try { JSON.parse(raw); } catch (e) { return; }

      const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      const token = /\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\],:])/y;
      let out = [], depth = 0, i = 0, m;
      const nl = () => '\n' + '  '.repeat(depth);
      const peek = () => { token.lastIndex = i; const n = token.exec(raw); return n && n[1]; };
      while ((m = (token.lastIndex = i, token.exec(raw)))) {
        i = token.lastIndex;
        const t = m[1], c = t[0];
        if (c === '{' || c === '[') {
          const close = c === '{' ? '}' : ']';
          if (peek() === close) {               // {} and [] stay on one line
            token.lastIndex = i; token.exec(raw); i = token.lastIndex;
            out.push(`<span class=p>${c}${close}</span>`);
          } else { depth++; out.push(`<span class=p>${c}</span>` + nl()); }
        } else if (c === '}' || c === ']') { depth--; out.push(nl() + `<span class=p>${c}</span>`); }
        else if (c === ',') out.push('<span class=p>,</span>' + nl());
        else if (c === ':') out.push('<span class=p>:</span> ');
        else if (c === '"') out.push(`<span class=${peek() === ':' ? 'k' : 's'}>${esc(t)}</span>`);
        else if (t === 'true' || t === 'false') out.push(`<span class=b>${t}</span>`);
        else if (t === 'null') out.push(`<span class=z>null</span>`);
        else out.push(`<span class=n>${t}</span>`);
      }

      const style = document.createElement('style');
      style.textContent = `
        :root { color-scheme: light dark; }
        body { margin: 0; }
        .tw-bar { position: sticky; top: 0; display: flex; gap: 4px; justify-content: flex-end;
                  padding: 8px 12px; background: Canvas; font: 12px -apple-system, system-ui; }
        .tw-bar button { font: inherit; border: 0; border-radius: 6px; padding: 3px 10px;
                         background: transparent; color: GrayText; cursor: pointer; }
        .tw-bar button.on { background: color-mix(in srgb, CanvasText 10%, transparent); color: CanvasText; }
        pre { margin: 0; padding: 4px 16px 24px; white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.5; }
        .k { color: #8250df } .s { color: #0a7f3f } .n { color: #0550ae }
        .b { color: #b35900 } .z { color: #8c959f } .p { color: #8c959f }
        @media (prefers-color-scheme: dark) {
          .k { color: #c297ff } .s { color: #7ee787 } .n { color: #79c0ff }
          .b { color: #ffa657 } .z, .p { color: #8b949e }
        }`;
      document.head.appendChild(style);

      const pretty = document.createElement('pre');
      pretty.innerHTML = out.join('');
      const plain = document.createElement('pre');
      plain.textContent = raw;
      const bar = document.createElement('div');
      bar.className = 'tw-bar';
      const show = which => {
        document.body.replaceChildren(bar, which === 'pretty' ? pretty : plain);
        for (const b of bar.children) b.classList.toggle('on', b.dataset.view === which);
      };
      for (const [view, label] of [['pretty', 'Pretty'], ['raw', 'Raw']]) {
        const b = document.createElement('button');
        b.textContent = label; b.dataset.view = view;
        b.onclick = () => show(view);
        bar.appendChild(b);
      }
      show('pretty');
    })();
    """#
}
