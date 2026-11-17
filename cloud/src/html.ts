import type { ConsentDescription } from "@cloudflare/workers-oauth-provider";

export const escapeHtml = (value: string) =>
  value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const STYLE = `
  :root { color-scheme: light dark; --bg:#fbfaf8; --fg:#1d1c1a; --muted:#6b6862; --card:#fff; --line:#e6e2db; --accent:#2f5bea; }
  @media (prefers-color-scheme: dark) { :root { --bg:#161513; --fg:#ecebe8; --muted:#a19d96; --card:#1f1e1b; --line:#34322e; --accent:#8aa6ff; } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 680px; margin: 0 auto; padding: 48px 16px 64px; }
  h1 { font-size: 28px; margin: 0 0 8px; letter-spacing: -0.01em; }
  h2 { font-size: 18px; margin: 32px 0 8px; }
  p, li { color: var(--fg); }
  .muted { color: var(--muted); }
  code, .url { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 14px; }
  .url { display:block; padding:12px 14px; background:var(--card); border:1px solid var(--line); border-radius:8px; overflow-wrap:anywhere; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:20px; }
  a { color: var(--accent); }
  button { font: inherit; padding: 10px 18px; border-radius: 8px; border: 1px solid var(--line); background: var(--card); color: var(--fg); cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
  .warn { border-left: 3px solid #d98b00; padding-left: 12px; }
`;

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title><style>${STYLE}</style></head>
<body><main>${body}</main></body></html>`;
}

export const HTML_HEADERS = {
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

export function landingPage(publicUrl: string, downloadUrl: string): string {
  const mcp = `${publicUrl}/mcp`;
  return page(
    "OpenScribe Cloud",
    `<h1>OpenScribe Cloud</h1>
<p class="muted">Ask Claude, ChatGPT and other AI assistants about your OpenScribe notes and meetings.</p>

<h2>1. Turn on sync in the app</h2>
<p>Install <a href="${escapeHtml(downloadUrl)}">OpenScribe for macOS</a>, open Settings, and sign in with Google under Cloud sync. Sync is off until you turn it on, and you can delete everything from the server at any time.</p>

<h2>2. Connect your assistant</h2>
<p>Use this MCP server URL. You'll be asked to sign in with the same Google account.</p>
<code class="url">${escapeHtml(mcp)}</code>
<ul>
  <li><strong>Claude (claude.ai or Claude Desktop)</strong>: Settings → Connectors → Add custom connector → paste the URL.</li>
  <li><strong>ChatGPT</strong>: Settings → Apps &amp; Connectors → Advanced → Developer mode, then Create → paste the URL, authentication OAuth.</li>
  <li><strong>Claude Code</strong>: <code>claude mcp add --transport http openscribe ${escapeHtml(mcp)}</code>, then run <code>/mcp</code> to sign in.</li>
</ul>

<h2>What assistants can do</h2>
<p>Read only: search, fetch a note or meeting, list recent documents, get a meeting's summary and transcript, and list action items. Assistants can't change or delete anything, and they only ever see your own documents.</p>

<p class="muted">Prefer to keep everything on your Mac? The app also ships a local MCP server that works offline.</p>
<p class="muted"><a href="/privacy">Privacy</a> · <a href="/terms">Terms</a></p>`,
  );
}

export function privacyPage(): string {
  return page(
    "Privacy · OpenScribe Cloud",
    `<h1>Privacy</h1>
<p class="muted">OpenScribe Cloud is an optional companion to the OpenScribe app for macOS.</p>
<h2>What we store</h2>
<ul>
  <li><strong>Your Google account basics</strong>: your Google account ID, email address and name, used only to sign you in and keep your data separate from everyone else's. We request only the <code>openid</code>, <code>email</code> and <code>profile</code> scopes.</li>
  <li><strong>Documents you choose to sync</strong>: the notes and meeting summaries, transcripts and action items that the app uploads after you turn on Cloud sync. Nothing is uploaded until you sign in and turn sync on.</li>
  <li><strong>Sessions</strong>: tokens for the app and for AI assistants you connect. App tokens are stored only as one-way hashes.</li>
</ul>
<h2>How it is used</h2>
<p>Your documents are returned only to you: to the app, and to AI assistants you connect yourself through the MCP connector, after you sign in with the same Google account. Connected assistants get read-only access. We don't sell your data, use it for advertising, or use it to train models.</p>
<h2>Where it lives</h2>
<p>Data is stored on Cloudflare (Workers, D1 and KV). Audio recordings never leave your Mac through OpenScribe Cloud.</p>
<h2>Deleting your data</h2>
<p>In the app, open Settings → AI &amp; MCP → Delete cloud data. This removes your documents, sessions and connector grants from the server immediately. Signing out stops further syncing.</p>
<h2>Contact</h2>
<p>Questions: open an issue at <a href="https://github.com/shashankanil/openscribe/issues">github.com/shashankanil/openscribe</a>.</p>`,
  );
}

export function termsPage(): string {
  return page(
    "Terms · OpenScribe Cloud",
    `<h1>Terms of service</h1>
<p>OpenScribe Cloud is provided free of charge, as is, without warranties of any kind. It may change or be discontinued, so keep your own copy of anything important: your library always remains on your Mac.</p>
<p>You are responsible for the content you sync and for having permission to record and store it, including meeting recordings and transcripts that involve other people.</p>
<p>Don't use the service to break the law, to attack or overload it, or to access anyone else's data. Accounts that do may be removed.</p>
<p>You can stop using the service and delete your data at any time from the app (Settings → AI &amp; MCP → Delete cloud data). See also the <a href="/privacy">privacy notice</a>.</p>`,
  );
}

export function consentPage(details: ConsentDescription, handle: string): string {
  const name = escapeHtml(details.clientName);
  const origin = details.clientDomain
    ? `Published by <strong>${escapeHtml(details.clientDomain)}</strong>.`
    : "This app registered itself, so its name isn't verified.";
  return page(
    `Connect ${details.clientName} to OpenScribe`,
    `<div class="card">
<h1>Allow ${name} to read your OpenScribe notes?</h1>
<p>${origin} Access will be sent to <strong>${escapeHtml(details.redirectHost)}</strong>.</p>
${details.redirectIsLoopback ? '<p class="warn"><strong>This sends access to an app on your computer.</strong> Continue only if you just started connecting from it.</p>' : ""}
<p>${name} will be able to search and read your synced notes and meetings. It can't change or delete anything. Next you'll sign in with Google.</p>
<form method="post" action="/authorize">
  <input type="hidden" name="handle" value="${escapeHtml(handle)}">
  <p><button class="primary" name="decision" value="approve">Continue with Google</button> <button name="decision" value="deny">Cancel</button></p>
</form>
</div>`,
  );
}

export function errorPage(message: string): string {
  return page("OpenScribe Cloud", `<div class="card"><h1>Something went wrong</h1><p>${escapeHtml(message)}</p></div>`);
}
