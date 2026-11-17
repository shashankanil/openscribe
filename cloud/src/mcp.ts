/** Remote MCP server: the read-only tools from docs/CONTEXT-API.md, bound to one user. */
import { McpServer, type CallToolResult } from "@modelcontextprotocol/server";
import { z } from "zod";
import { mediaAccess } from "./media";
import { fetchDocument, getAttachment, getMeeting, listActionItems, listRecent, search, ToolError, type ToolResult } from "./tools";

export const SERVER_NAME = "openscribe";
export const SERVER_VERSION = "0.2.0";

const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false } as const;
const kind = z.enum(["note", "meeting"]);

async function run<T>(fn: () => Promise<ToolResult<T>>): Promise<CallToolResult> {
  try {
    const { text, structured, content } = await fn();
    return { content: content ?? [{ type: "text", text }], structuredContent: structured as Record<string, unknown> };
  } catch (error) {
    if (error instanceof ToolError) return { content: [{ type: "text", text: error.message }], isError: true };
    throw error;
  }
}

export function createOpenScribeServer(env: Env, userId: string): McpServer {
  const db = env.DB;
  const media = mediaAccess(env, userId);
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    {
      instructions:
        "OpenScribe gives read-only access to the user's synced notes and meeting notes. " +
        "Use `search` to find documents, then `fetch` or `get_meeting` for full content. " +
        "`list_recent` and `list_action_items` answer 'what happened lately' questions. " +
        "Documents can have attachments (screenshots and meeting recordings), listed by `fetch` and `get_meeting`; " +
        "call `get_attachment` to view a screenshot or get a short-lived link to a recording.",
    },
  );

  server.registerTool(
    "search",
    {
      title: "Search notes and meetings",
      description:
        "Full-text search across the user's OpenScribe notes and meetings. Returns results ranked by relevance with a snippet; use `fetch` with a result id for the full document.",
      inputSchema: z.object({
        query: z.string().min(1).describe("Search terms"),
        kind: kind.optional().describe("Restrict to notes or meetings"),
        limit: z.number().int().min(1).max(50).default(10).describe("Maximum results (1-50)"),
      }),
      annotations: { ...readOnly, title: "Search notes and meetings" },
    },
    (args) => run(() => search(db, userId, args)),
  );

  server.registerTool(
    "fetch",
    {
      title: "Fetch document",
      description:
        "Fetch one OpenScribe note or meeting by id as markdown, with the full normalized document as structured content, including its attachments (screenshots, recordings) with short-lived URLs.",
      inputSchema: z.object({ id: z.string().min(1).describe("Document id from search or list_recent") }),
      annotations: { ...readOnly, title: "Fetch document" },
    },
    (args) => run(() => fetchDocument(db, userId, args, media)),
  );

  server.registerTool(
    "list_recent",
    {
      title: "List recent documents",
      description: "List recently updated notes and meetings, newest first, without transcripts.",
      inputSchema: z.object({
        kind: kind.optional().describe("Restrict to notes or meetings"),
        days: z.number().int().min(1).max(3650).default(7).describe("Look back this many days"),
        limit: z.number().int().min(1).max(100).default(20).describe("Maximum documents"),
      }),
      annotations: { ...readOnly, title: "List recent documents" },
    },
    (args) => run(() => listRecent(db, userId, args)),
  );

  server.registerTool(
    "get_meeting",
    {
      title: "Get meeting",
      description:
        "Get a meeting's title, date, duration, summary, action items, notes and attachments (screenshots, recordings); optionally the transcript.",
      inputSchema: z.object({
        id: z.string().min(1).describe("Meeting id"),
        includeTranscript: z.boolean().default(false).describe("Include the transcript (truncated at ~60k characters)"),
      }),
      annotations: { ...readOnly, title: "Get meeting" },
    },
    (args) => run(() => getMeeting(db, userId, args, media)),
  );

  server.registerTool(
    "list_action_items",
    {
      title: "List action items",
      description: "Action items from meeting summaries in the last N days, with the meeting id, title and date.",
      inputSchema: z.object({
        days: z.number().int().min(1).max(3650).default(14).describe("Look back this many days"),
      }),
      annotations: { ...readOnly, title: "List action items" },
    },
    (args) => run(() => listActionItems(db, userId, args)),
  );

  server.registerTool(
    "get_attachment",
    {
      title: "Get attachment",
      description:
        "Get one screenshot or recording attached to a note or meeting. Screenshots up to 5 MB are returned as images; " +
        "larger images and recordings are returned as a signed link that expires in one hour.",
      inputSchema: z.object({
        documentId: z.string().min(1).describe("Id of the note or meeting the attachment belongs to"),
        id: z.string().min(1).describe("Attachment id from fetch or get_meeting"),
      }),
      annotations: { ...readOnly, title: "Get attachment" },
    },
    (args) => run(() => getAttachment(db, userId, args, media)),
  );

  return server;
}
