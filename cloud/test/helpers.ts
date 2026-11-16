import type { OpenScribeDocument } from "../src/documents";
import { upsertUser } from "../src/google";
import { issueAppToken } from "../src/app-auth";

export const BASE = "https://cloud.test";

export async function seedUser(db: D1Database, sub: string, email = `${sub}@example.com`): Promise<void> {
  await upsertUser(db, { sub, email, name: `User ${sub}` });
}

export async function seedUserWithToken(db: D1Database, sub: string): Promise<string> {
  await seedUser(db, sub);
  return issueAppToken(db, sub);
}

export function makeDoc(overrides: Partial<OpenScribeDocument> = {}): OpenScribeDocument {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    kind: "note",
    title: "Untitled",
    createdAt: now,
    updatedAt: now,
    deleted: false,
    body: "",
    summary: null,
    transcript: null,
    actionItems: [],
    durationSeconds: 0,
    tags: [],
    ...overrides,
  };
}

export const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString();

/** Storage persists across tests in a file; start each test from an empty database. */
export async function resetDb(db: D1Database): Promise<void> {
  await db.batch([db.prepare("DELETE FROM documents"), db.prepare("DELETE FROM app_tokens"), db.prepare("DELETE FROM users")]);
}
