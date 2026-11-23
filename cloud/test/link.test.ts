import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/crypto";
import { LINK_BLOB_TTL_MS, linkBlobKey, MAX_LINK_BLOB_BYTES } from "../src/link";
import { CLOSE_REPLACED, MAX_RELAY_MESSAGE_BYTES } from "../src/link-relay";
import { BASE, resetDb, seedUserWithToken } from "./helpers";

// Every request goes through the real default export, i.e. the OAuthProvider wrapper around the Hono app.
const worker = exports.default;
const call = (path: string, init?: RequestInit) => worker.fetch(new Request(`${BASE}${path}`, { redirect: "manual", ...init }));
const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

/** The relay room from the spec's test vector secret. */
const ROOM = "14da9ca9ec019835c941f773b307b562";

async function mintPhone(macToken: string, deviceId = "slot-1", name = "Pixel 8"): Promise<Response> {
  return call("/api/v1/link/devices", {
    method: "POST",
    headers: { ...auth(macToken), "Content-Type": "application/json" },
    body: JSON.stringify({ deviceId, name }),
  });
}

async function phoneToken(macToken: string, deviceId = "slot-1"): Promise<string> {
  const res = await mintPhone(macToken, deviceId);
  expect(res.status).toBe(200);
  return ((await res.json()) as { token: string }).token;
}

// ---------------------------------------------------------------------------------------------
// WebSocket test client

type Message = string | ArrayBuffer | Blob;

class Client {
  private inbox: Message[] = [];
  private waiters: ((m: Message) => void)[] = [];
  readonly closed: Promise<{ code: number; reason: string }>;

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (e) => {
      const waiter = this.waiters.shift();
      if (waiter) waiter(e.data as Message);
      else this.inbox.push(e.data as Message);
    });
    this.closed = new Promise((resolve) => ws.addEventListener("close", (e) => resolve({ code: e.code, reason: e.reason })));
    ws.accept();
  }

  /** The next message, or a rejection after `ms`. */
  next(ms = 2000): Promise<Message> {
    const queued = this.inbox.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        reject(new Error("timed out waiting for a message"));
      }, ms);
      const waiter = (m: Message) => {
        clearTimeout(timer);
        resolve(m);
      };
      this.waiters.push(waiter);
    });
  }

  async nextJson(): Promise<unknown> {
    const m = await this.next();
    expect(typeof m).toBe("string");
    return JSON.parse(m as string);
  }

  async nextBytes(): Promise<Uint8Array> {
    const m = await this.next();
    expect(typeof m).not.toBe("string");
    // Client-side sockets deliver binary as Blob by default.
    return new Uint8Array(m instanceof Blob ? await m.arrayBuffer() : (m as ArrayBuffer));
  }

  /** Asserts nothing arrives within `ms`. */
  async expectSilence(ms = 200): Promise<void> {
    await expect(this.next(ms)).rejects.toThrow("timed out");
  }

  close(): void {
    try {
      this.ws.close(1000, "done");
    } catch {
      // already closed
    }
  }
}

const open: Client[] = [];

async function connect(token: string, room = ROOM, extraHeaders: Record<string, string> = {}): Promise<Client> {
  const res = await call(`/api/v1/link/relay/${room}`, { headers: { Upgrade: "websocket", ...auth(token), ...extraHeaders } });
  expect(res.status).toBe(101);
  expect(res.webSocket).toBeTruthy();
  const client = new Client(res.webSocket!);
  open.push(client);
  return client;
}

const PEER_ON = { t: "peer", present: true };
const PEER_OFF = { t: "peer", present: false };

// ---------------------------------------------------------------------------------------------

let mac: string;
const U = "link-user";

beforeEach(async () => {
  await resetDb(env.DB);
  // R2 persists across tests too.
  for (;;) {
    const page = await env.MEDIA.list({ prefix: "link/" });
    if (page.objects.length === 0) break;
    await env.MEDIA.delete(page.objects.map((o) => o.key));
  }
  mac = await seedUserWithToken(env.DB, U);
});

afterEach(async () => {
  for (const c of open.splice(0)) c.close();
});

describe("phone tokens", () => {
  it("mints, re-mints (revoking the old token) and deletes", async () => {
    const res = await mintPhone(mac, "slot-1", "  Pixel\u0007 8  ");
    expect(res.status).toBe(200);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    const { token: first } = (await res.json()) as { token: string };
    expect(first).toMatch(/^oslp_[A-Za-z0-9_-]{43}$/);

    const row = await env.DB.prepare("SELECT user_id, device_id, name, revoked_at FROM link_devices WHERE token_hash = ?1")
      .bind(await sha256Hex(first))
      .first();
    expect(row).toEqual({ user_id: U, device_id: "slot-1", name: "Pixel 8", revoked_at: null });
    // Only the hash is stored.
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM link_devices WHERE token_hash = ?1").bind(first).first()).toEqual({ n: 0 });

    // The phone token works for blobs.
    const put = await call("/api/v1/link/blobs", {
      method: "PUT",
      headers: { ...auth(first), "Content-Type": "application/octet-stream", "Content-Length": "3" },
      body: new Uint8Array([1, 2, 3]),
    });
    expect(put.status).toBe(200);

    // A second token for another slot is independent.
    const other = await phoneToken(mac, "slot-2");

    // Re-minting slot-1 revokes the first token.
    const second = await phoneToken(mac, "slot-1");
    expect(second).not.toBe(first);
    expect((await call("/api/v1/link/blobs/00000000-0000-4000-8000-000000000000", { headers: auth(first) })).status).toBe(401);
    expect((await call("/api/v1/link/blobs/00000000-0000-4000-8000-000000000000", { headers: auth(second) })).status).toBe(404);
    expect(
      await env.DB.prepare("SELECT COUNT(*) AS n FROM link_devices WHERE device_id = 'slot-1' AND revoked_at IS NULL").first(),
    ).toEqual({ n: 1 });

    // DELETE revokes it; slot-2 is untouched.
    const del = await call("/api/v1/link/devices/slot-1", { method: "DELETE", headers: auth(mac) });
    expect(del.status).toBe(200);
    expect(await del.json()).toEqual({ revoked: true });
    expect((await call("/api/v1/link/blobs/00000000-0000-4000-8000-000000000000", { headers: auth(second) })).status).toBe(401);
    expect((await call("/api/v1/link/blobs/00000000-0000-4000-8000-000000000000", { headers: auth(other) })).status).toBe(404);
    // Deleting again is a no-op.
    expect((await call("/api/v1/link/devices/slot-1", { method: "DELETE", headers: auth(mac) })).status).toBe(200);
  });

  it("rejects bad input and the wrong credentials", async () => {
    for (const deviceId of ["", "a".repeat(101), "slot/1", "slot 1", "slot_1", 42, null]) {
      const res = await call("/api/v1/link/devices", {
        method: "POST",
        headers: { ...auth(mac), "Content-Type": "application/json" },
        body: JSON.stringify({ deviceId, name: "x" }),
      });
      expect(res.status, String(deviceId)).toBe(400);
    }
    expect((await mintPhone(mac, "a".repeat(100))).status).toBe(200);
    const badJson = await call("/api/v1/link/devices", { method: "POST", headers: auth(mac), body: "{" });
    expect(badJson.status).toBe(400);
    expect((await call("/api/v1/link/devices", { method: "POST", headers: auth(mac), body: JSON.stringify({ deviceId: "a", name: 5 }) })).status).toBe(400);
    expect((await call("/api/v1/link/devices/bad_id", { method: "DELETE", headers: auth(mac) })).status).toBe(400);

    // No token, unknown tokens, and a phone token where only the Mac may act.
    const none = await mintPhone("");
    expect(none.status).toBe(401);
    expect(none.headers.get("WWW-Authenticate")).toContain("Bearer");
    expect((await mintPhone("osk_unknown")).status).toBe(401);
    expect((await mintPhone("oslp_unknown")).status).toBe(401);
    const phone = await phoneToken(mac);
    const forbidden = await mintPhone(phone, "slot-9");
    expect(forbidden.status).toBe(403);
    expect((await call("/api/v1/link/devices/slot-1", { method: "DELETE", headers: auth(phone) })).status).toBe(403);

    // A revoked Mac token can't use Phone Link at all.
    await call("/api/v1/logout", { method: "POST", headers: auth(mac) });
    expect((await mintPhone(mac, "slot-3")).status).toBe(401);
    expect((await call(`/api/v1/link/relay/${ROOM}`, { headers: { Upgrade: "websocket", ...auth(mac) } })).status).toBe(401);
    // Phone tokens don't open the app-token API.
    expect((await call("/api/v1/me", { headers: auth(phone) })).status).toBe(401);
  });
});

describe("relay", () => {
  it("rejects missing auth, non-upgrades and bad rooms", async () => {
    expect((await call(`/api/v1/link/relay/${ROOM}`, { headers: { Upgrade: "websocket" } })).status).toBe(401);
    expect((await call(`/api/v1/link/relay/${ROOM}`, { headers: { Upgrade: "websocket", ...auth("oslp_nope") } })).status).toBe(401);
    expect((await call(`/api/v1/link/relay/${ROOM}`, { headers: auth(mac) })).status).toBe(426);
    for (const room of [ROOM.toUpperCase(), ROOM.slice(1), `${ROOM}0`, "zz".repeat(16)]) {
      expect((await call(`/api/v1/link/relay/${room}`, { headers: { Upgrade: "websocket", ...auth(mac) } })).status, room).toBe(400);
    }
  });

  it("pairs a mac and a phone: presence, binary frames both ways, ping/pong, leave", async () => {
    const phone = await phoneToken(mac);
    const m = await connect(mac);
    expect(await m.nextJson()).toEqual(PEER_OFF);

    const p = await connect(phone);
    expect(await p.nextJson()).toEqual(PEER_ON);
    expect(await m.nextJson()).toEqual(PEER_ON);

    const frame = Uint8Array.from({ length: 300 }, (_, i) => (i * 7) % 256);
    p.ws.send(frame);
    expect(await m.nextBytes()).toEqual(frame);
    m.ws.send(new Uint8Array([9, 8, 7]));
    expect(await p.nextBytes()).toEqual(new Uint8Array([9, 8, 7]));

    // Text other than `ping` is ignored; `ping` gets `pong` (hibernation auto-response).
    p.ws.send('{"t":"hello"}');
    p.ws.send("ping");
    expect(await p.next()).toBe("pong");
    await m.expectSilence();

    p.close();
    expect((await p.closed).code).toBe(1000);
    expect(await m.nextJson()).toEqual(PEER_OFF);

    // Frames with no peer are dropped; the next phone session starts cleanly.
    m.ws.send(new Uint8Array([1]));
    const p2 = await connect(phone);
    expect(await p2.nextJson()).toEqual(PEER_ON);
    expect(await m.nextJson()).toEqual(PEER_ON);
    await p2.expectSilence();
  });

  it("replaces an older socket of the same role with close code 4000", async () => {
    const phone = await phoneToken(mac);
    const m = await connect(mac);
    expect(await m.nextJson()).toEqual(PEER_OFF);
    const p1 = await connect(phone);
    expect(await p1.nextJson()).toEqual(PEER_ON);
    expect(await m.nextJson()).toEqual(PEER_ON);

    const p2 = await connect(phone);
    expect(await p1.closed).toEqual({ code: CLOSE_REPLACED, reason: "replaced" });
    expect(await p2.nextJson()).toEqual(PEER_ON);
    // The Mac hears the old phone leave and the new one join, and nothing when the old socket finishes closing.
    expect(await m.nextJson()).toEqual(PEER_OFF);
    expect(await m.nextJson()).toEqual(PEER_ON);
    await m.expectSilence();

    m.ws.send(new Uint8Array([42]));
    expect(await p2.nextBytes()).toEqual(new Uint8Array([42]));

    // Replacing the Mac works the same way.
    const m2 = await connect(mac);
    expect(await m.closed).toEqual({ code: CLOSE_REPLACED, reason: "replaced" });
    expect(await m2.nextJson()).toEqual(PEER_ON);
    expect(await p2.nextJson()).toEqual(PEER_OFF);
    expect(await p2.nextJson()).toEqual(PEER_ON);
    p2.ws.send(new Uint8Array([43]));
    expect(await m2.nextBytes()).toEqual(new Uint8Array([43]));
  });

  it("takes the role from the token, not from a client-supplied header", async () => {
    const phone = await phoneToken(mac);
    const m = await connect(mac);
    expect(await m.nextJson()).toEqual(PEER_OFF);
    const p = await connect(phone, ROOM, { "X-OpenScribe-Link-Role": "mac" });
    expect(await p.nextJson()).toEqual(PEER_ON);
    expect(await m.nextJson()).toEqual(PEER_ON);
    await m.expectSilence();
  });

  it("keeps rooms per account: the same room id in another account never reaches this one", async () => {
    const phoneA = await phoneToken(mac);
    const macB = await seedUserWithToken(env.DB, "intruder");
    const phoneB = await phoneToken(macB);

    const a = await connect(mac);
    expect(await a.nextJson()).toEqual(PEER_OFF);
    const b = await connect(phoneB);
    expect(await b.nextJson()).toEqual(PEER_OFF);
    b.ws.send(new Uint8Array([1, 2, 3]));
    await a.expectSilence();

    const bMac = await connect(macB);
    expect(await bMac.nextJson()).toEqual(PEER_ON);
    expect(await b.nextJson()).toEqual(PEER_ON);
    await a.expectSilence();

    // Account A's own phone still pairs with A's Mac.
    const pA = await connect(phoneA);
    expect(await pA.nextJson()).toEqual(PEER_ON);
    expect(await a.nextJson()).toEqual(PEER_ON);
    await b.expectSilence();
  });

  it("closes a socket that sends a frame over 1 MiB, and forwards one of exactly 1 MiB", async () => {
    const phone = await phoneToken(mac);
    const m = await connect(mac);
    expect(await m.nextJson()).toEqual(PEER_OFF);
    const p = await connect(phone);
    expect(await p.nextJson()).toEqual(PEER_ON);
    expect(await m.nextJson()).toEqual(PEER_ON);

    p.ws.send(new Uint8Array(MAX_RELAY_MESSAGE_BYTES));
    expect((await m.nextBytes()).byteLength).toBe(MAX_RELAY_MESSAGE_BYTES);

    p.ws.send(new Uint8Array(MAX_RELAY_MESSAGE_BYTES + 1));
    expect((await p.closed).code).toBe(1009);
    expect(await m.nextJson()).toEqual(PEER_OFF);
    await m.expectSilence();
  });
});

describe("blobs", () => {
  const putBlob = (token: string, bytes: Uint8Array, headers: Record<string, string> = {}) =>
    call("/api/v1/link/blobs", {
      method: "PUT",
      headers: { ...auth(token), "Content-Type": "application/octet-stream", "Content-Length": String(bytes.byteLength), ...headers },
      body: bytes,
    });

  it("stores a blob from one role and serves it to the other", async () => {
    const phone = await phoneToken(mac);
    const bytes = Uint8Array.from({ length: 5000 }, (_, i) => i % 253);
    const before = Date.now();
    const res = await putBlob(phone, bytes);
    expect(res.status).toBe(200);
    const { id, expiresAt } = (await res.json()) as { id: string; expiresAt: number };
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(expiresAt).toBeGreaterThanOrEqual(before + LINK_BLOB_TTL_MS);
    expect(expiresAt).toBeLessThanOrEqual(Date.now() + LINK_BLOB_TTL_MS);

    const head = await env.MEDIA.head(linkBlobKey(U, id));
    expect(head?.size).toBe(bytes.byteLength);
    expect(Number(head?.customMetadata?.uploadedAt)).toBe(expiresAt - LINK_BLOB_TTL_MS);

    const get = await call(`/api/v1/link/blobs/${id}`, { headers: auth(mac) });
    expect(get.status).toBe(200);
    expect(get.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(get.headers.get("Cache-Control")).toBe("no-store");
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(bytes);

    // Link blobs don't touch the attachments quota.
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM attachments").first()).toEqual({ n: 0 });
    const me = (await (await call("/api/v1/me", { headers: auth(mac) })).json()) as { attachmentBytes: number };
    expect(me.attachmentBytes).toBe(0);
  });

  it("accepts exactly 10 MiB + 28 bytes and rejects bad uploads", async () => {
    const max = new Uint8Array(MAX_LINK_BLOB_BYTES);
    max[max.length - 1] = 7;
    const ok = await putBlob(mac, max);
    expect(ok.status).toBe(200);
    const { id } = (await ok.json()) as { id: string };
    expect((await env.MEDIA.head(linkBlobKey(U, id)))?.size).toBe(MAX_LINK_BLOB_BYTES);

    const tooLarge = await putBlob(mac, new Uint8Array(10), { "Content-Length": String(MAX_LINK_BLOB_BYTES + 1) });
    expect(tooLarge.status).toBe(413);
    expect(await tooLarge.json()).toMatchObject({ error: "too_large" });

    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
        controller.close();
      },
    });
    const noLength = await call("/api/v1/link/blobs", {
      method: "PUT",
      headers: { ...auth(mac), "Content-Type": "application/octet-stream" },
      body: stream,
    });
    expect(noLength.status).toBe(411);

    expect((await putBlob(mac, new Uint8Array(4), { "Content-Type": "image/png" })).status).toBe(415);
    expect((await putBlob(mac, new Uint8Array(0))).status).toBe(400);
    expect((await putBlob("", new Uint8Array(4))).status).toBe(401);
    expect((await putBlob("oslp_unknown", new Uint8Array(4))).status).toBe(401);
    // Only the one good upload was stored.
    expect((await env.MEDIA.list({ prefix: `link/${U}/` })).objects.length).toBe(1);
  });

  it("returns 404 for another account's blob, an unknown or malformed id, and an expired blob", async () => {
    const res = await putBlob(mac, new Uint8Array([1, 2, 3]));
    const { id } = (await res.json()) as { id: string };
    const macB = await seedUserWithToken(env.DB, "someone-else");
    const phoneB = await phoneToken(macB);
    expect((await call(`/api/v1/link/blobs/${id}`, { headers: auth(macB) })).status).toBe(404);
    expect((await call(`/api/v1/link/blobs/${id}`, { headers: auth(phoneB) })).status).toBe(404);
    expect((await call(`/api/v1/link/blobs/${crypto.randomUUID()}`, { headers: auth(mac) })).status).toBe(404);
    expect((await call("/api/v1/link/blobs/not-a-uuid", { headers: auth(mac) })).status).toBe(404);
    expect((await call(`/api/v1/link/blobs/${id}`)).status).toBe(401);

    // Just under two days old is still served; just over is not.
    const key = linkBlobKey(U, id);
    await env.MEDIA.put(key, new Uint8Array([1, 2, 3]), { customMetadata: { uploadedAt: String(Date.now() - LINK_BLOB_TTL_MS + 60_000) } });
    expect((await call(`/api/v1/link/blobs/${id}`, { headers: auth(mac) })).status).toBe(200);
    await env.MEDIA.put(key, new Uint8Array([1, 2, 3]), { customMetadata: { uploadedAt: String(Date.now() - LINK_BLOB_TTL_MS - 1) } });
    expect((await call(`/api/v1/link/blobs/${id}`, { headers: auth(mac) })).status).toBe(404);
    await env.MEDIA.delete(key);
  });
});

describe("account deletion", () => {
  it("purges link blobs and phone tokens, and leaves other accounts alone", async () => {
    const phone = await phoneToken(mac);
    const { id } = (await (await call("/api/v1/link/blobs", {
      method: "PUT",
      headers: { ...auth(phone), "Content-Type": "application/octet-stream", "Content-Length": "2" },
      body: new Uint8Array([1, 2]),
    })).json()) as { id: string };
    await env.MEDIA.put(`link/${U}/stray`, "x");
    await env.MEDIA.put("link/someone-else/keep", "keep");

    expect((await call("/api/v1/account", { method: "DELETE", headers: auth(mac) })).status).toBe(200);
    expect((await env.MEDIA.list({ prefix: `link/${U}/` })).objects).toEqual([]);
    expect(await env.MEDIA.head(linkBlobKey(U, id))).toBeNull();
    expect(await env.MEDIA.head("link/someone-else/keep")).not.toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM link_devices WHERE user_id = ?1").bind(U).first()).toEqual({ n: 0 });
    expect((await call(`/api/v1/link/relay/${ROOM}`, { headers: { Upgrade: "websocket", ...auth(phone) } })).status).toBe(401);
    await env.MEDIA.delete("link/someone-else/keep");
  });
});
