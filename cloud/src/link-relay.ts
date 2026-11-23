/**
 * Phone Link relay (docs/PHONE-LINK.md, "Relay"). One Durable Object per `${userId}:${room}`,
 * holding at most one socket per role ("mac", "phone"). Binary messages are opaque end-to-end
 * encrypted frames and are forwarded to the other role. Uses the WebSocket Hibernation API, so an
 * idle room costs nothing, and `ping` is answered with `pong` without waking the object.
 */
import { DurableObject } from "cloudflare:workers";
import type { LinkRole } from "./link";

/** Set by the Worker after authenticating. Durable Objects aren't reachable from the internet, so it can be trusted. */
export const LINK_ROLE_HEADER = "X-OpenScribe-Link-Role";

export const MAX_RELAY_MESSAGE_BYTES = 1024 * 1024;

/** Close codes sent to clients. */
export const CLOSE_REPLACED = 4000;
export const CLOSE_TOO_BIG = 1009;

interface SocketState {
  /** Replaced by a newer socket of the same role, or already reported to the peer as gone. */
  gone?: true;
}

const isRole = (v: unknown): v is LinkRole => v === "mac" || v === "phone";
const otherRole = (role: LinkRole): LinkRole => (role === "mac" ? "phone" : "mac");
const peerMessage = (present: boolean) => JSON.stringify({ t: "peer", present });

function trySend(ws: WebSocket, message: string | ArrayBuffer): void {
  try {
    ws.send(message);
  } catch {
    // The socket is closing; its close handler cleans up.
  }
}

/** Codes an endpoint may put in a close frame (RFC 6455 §7.4). */
const sendableCloseCode = (code: number) => (code >= 1000 && code <= 1014 && ![1004, 1005, 1006].includes(code)) || (code >= 3000 && code <= 4999);

function tryClose(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}

export class LinkRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** Open sockets of a role, excluding replaced or departed ones. */
  private live(role: LinkRole, except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(role).filter((ws) => {
      if (ws === except) return false;
      if (ws.readyState !== WebSocket.OPEN) return false;
      return !(ws.deserializeAttachment() as SocketState | null)?.gone;
    });
  }

  private roleOf(ws: WebSocket): LinkRole | null {
    return this.ctx.getTags(ws).find(isRole) ?? null;
  }

  override async fetch(request: Request): Promise<Response> {
    const role = request.headers.get(LINK_ROLE_HEADER);
    if (!isRole(role)) return new Response("Missing role", { status: 400 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket upgrade", { status: 426 });

    const peer = otherRole(role);
    const peers = this.live(peer);
    const replaced = this.live(role);
    for (const old of replaced) {
      old.serializeAttachment({ gone: true } satisfies SocketState);
      tryClose(old, CLOSE_REPLACED, "replaced");
    }

    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({} satisfies SocketState);
    server.send(peerMessage(peers.length > 0));
    for (const ws of peers) {
      // A replacement is a new session for the peer: it hears the old socket leave, then the new one join.
      if (replaced.length > 0) trySend(ws, peerMessage(false));
      trySend(ws, peerMessage(true));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // Text from clients (other than the auto-answered `ping`) is ignored.
    if (typeof message === "string") return;
    if (message.byteLength > MAX_RELAY_MESSAGE_BYTES) {
      tryClose(ws, CLOSE_TOO_BIG, "message too big");
      this.left(ws);
      return;
    }
    const role = this.roleOf(ws);
    if (!role || (ws.deserializeAttachment() as SocketState | null)?.gone) return;
    for (const peer of this.live(otherRole(role))) trySend(peer, message);
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    // Complete the closing handshake (a no-op if the runtime already replied).
    tryClose(ws, sendableCloseCode(code) ? code : 1000, reason);
    this.left(ws);
  }

  override async webSocketError(ws: WebSocket, error: unknown): Promise<void> {
    this.left(ws);
  }

  /** A socket left: tell the other role, unless it was replaced, was already reported, or another of its role remains. */
  private left(ws: WebSocket): void {
    const role = this.roleOf(ws);
    if (!role) return;
    const alreadyGone = (ws.deserializeAttachment() as SocketState | null)?.gone === true;
    // Mark it so a second notification (close after error, or close after our own 1009) is a no-op.
    if (!alreadyGone) {
      try {
        ws.serializeAttachment({ gone: true } satisfies SocketState);
      } catch {
        // Fully closed sockets can't take attachments; they're no longer in getWebSockets() either.
      }
    }
    if (alreadyGone || this.live(role, ws).length > 0) return;
    for (const peer of this.live(otherRole(role))) trySend(peer, peerMessage(false));
  }
}
