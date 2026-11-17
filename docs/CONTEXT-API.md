# OpenScribe context API (MCP + sync contract)

OpenScribe exposes the user's notes and meetings to LLM clients through MCP, in two ways that share one tool surface:

- **Local MCP** – `openscribe-mcp`, a dependency-free Swift stdio server bundled at `OpenScribe.app/Contents/MacOS/openscribe-mcp`. It reads the local profile directly (read-only) and never touches the network. Works with Claude Desktop, Claude Code, Cursor, and any stdio MCP client.
- **Remote MCP** – a Cloudflare Worker (`cloud/`) with Google sign-in. The desktop app syncs documents to it (opt-in); claude.ai, ChatGPT and other remote-MCP clients connect at `https://<host>/mcp` and authenticate via OAuth 2.1 (dynamic client registration), with Google as the upstream identity provider.

## Local data (read-only for the MCP server)

Profile root: `~/Library/Application Support/WhisperFlow/` (override with env `OPENSCRIBE_DATA_DIR` for tests).

- `notes.json` – notes / dictation history (see `Sources/OpenScribe/Models.swift` and `AppStore.swift` for the exact Codable shapes).
- `Meetings/<uuid>/meeting.json` – `MeetingRecord` (see `Sources/OpenScribe/MeetingModels.swift`): `title`, `createdAt`, `duration`, `status`, `segments[] {id, track, start, duration, text}`, `summary {overview[], decisions[], actions[]}` of `{text, sources[]}`, `userNotes`.

Decoders must be lenient: unknown keys ignored, missing optional keys tolerated, Foundation `JSONEncoder` default date encoding (seconds since 2001-01-01, i.e. `timeIntervalSinceReferenceDate`) unless the file says otherwise.

## Normalized document

Both servers, and the sync API, use one shape:

```json
{
  "id": "uuid string (stable, from the app)",
  "kind": "note" | "meeting",
  "title": "string",
  "createdAt": "ISO-8601",
  "updatedAt": "ISO-8601",
  "deleted": false,
  "body": "markdown: note text, or meeting user notes",
  "summary": "markdown or null (meetings: overview, decisions, action items)",
  "transcript": "plain text or null (meetings: grouped transcript with [mm:ss] stamps)",
  "actionItems": ["string"],
  "durationSeconds": 0,
  "tags": ["string"]
}
```

## MCP tools (identical names and schemas locally and remotely)

| Tool | Input | Output |
|---|---|---|
| `search` | `query` (string, required), `kind` ("note"\|"meeting", optional), `limit` (1–50, default 10) | `results[]` of `{id, kind, title, createdAt, snippet}` ranked by relevance. Name and shape are compatible with ChatGPT connectors' `search`. |
| `fetch` | `id` (string) | Full normalized document as text (markdown) plus structured content. Compatible with ChatGPT connectors' `fetch`. |
| `list_recent` | `kind` (optional), `days` (default 7), `limit` (default 20) | Recent documents, newest first, without transcripts. |
| `get_meeting` | `id`, `includeTranscript` (default false) | Meeting title, date, duration, summary, action items, notes, optionally transcript. |
| `list_action_items` | `days` (default 14) | Action items from meeting summaries with meeting id/title/date. |

Every tool is read-only (`annotations.readOnlyHint: true`). Server name `openscribe`. Large transcripts are truncated at ~60k characters with a note telling the model to call `get_meeting` for a narrower result.

## Sync API (desktop app → Worker)

All endpoints under `/api/v1`, JSON, `Authorization: Bearer <app token>` except login.

- `GET /app/login?redirect_uri=openscribe://auth&state=<random>` – browser flow. Google sign-in, then redirects to `openscribe://auth?token=<app token>&state=<state>`. Only the `openscribe://auth` redirect is allowed. The token is opaque, stored hashed (SHA-256) server-side, revocable.
- `GET /api/v1/me` → `{ email, name, documentCount, lastSyncAt }`
- `POST /api/v1/documents/batch` body `{ documents: [Document] }` (≤ 200 per call, ≤ 5 MB) → `{ accepted, skipped }`. Upsert by `(user, id)`; a document is replaced only when its `updatedAt` is newer. `deleted: true` tombstones it (removed from search and MCP results).
- `DELETE /api/v1/documents/:id`
- `POST /api/v1/logout` – revokes the app token.
- `DELETE /api/v1/account` – deletes the user's documents, tokens and OAuth grants.

## Privacy

Sync is off by default and per-user opt-in from the app. The remote MCP only returns the signed-in user's documents. The local MCP is read-only and offline.

## Remote server implementation

See [`cloud/README.md`](../cloud/README.md) for the Worker (deploy steps, the Google redirect URI `https://<host>/callback`, secrets, and connector setup). `POST /api/v1/documents/batch` also returns `errors[]` (`{index, id?, error}`) for entries that failed validation. They are counted in `skipped`, and the rest of the batch is still applied.
