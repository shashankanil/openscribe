/**
 * OpenScribe Cloud Worker.
 *
 * - `/mcp`            Remote MCP (Streamable HTTP), OAuth 2.1 bearer tokens from this Worker.
 * - `/authorize`, `/token`, `/register`, `/.well-known/*`   OAuth 2.1 + DCR (workers-oauth-provider).
 * - `/callback`       Google redirect URI for both MCP and desktop-app sign-in.
 * - `/app/login`      Desktop app sign-in → openscribe://auth?token=…&state=…
 * - `/api/v1/*`       Sync API (app tokens).
 */
import OAuthProvider, { type OAuthProviderOptions } from "@cloudflare/workers-oauth-provider";
import { createMcpHandler } from "agents/mcp/server";
import { app, READ_SCOPE, SCOPES_SUPPORTED } from "./app";
import { createOpenScribeServer } from "./mcp";

export interface McpProps extends Record<string, unknown> {
  userId: string;
  email: string;
  name: string;
}

const DAY = 86_400;

/** Hosts whose browser `Origin` may call /mcp directly (server-to-server clients send none). */
const BROWSER_CLIENT_HOSTS = ["claude.ai", "chatgpt.com", "chat.openai.com"];

const mcpApiHandler = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const props = (ctx as ExecutionContext & { props?: McpProps }).props;
    if (!props?.userId) return new Response("Unauthorized", { status: 401 });
    const handler = createMcpHandler(() => createOpenScribeServer(env.DB, props.userId), {
      route: "/mcp",
      allowedOriginHostnames: [new URL(env.PUBLIC_URL).hostname, "localhost", "127.0.0.1", ...BROWSER_CLIENT_HOSTS],
    });
    return handler(request, env, ctx);
  },
};

export function oauthOptions(env: Env): OAuthProviderOptions<Env> {
  const origin = env.PUBLIC_URL.replace(/\/+$/, "");
  return {
    apiRoute: "/mcp",
    apiHandler: mcpApiHandler,
    defaultHandler: app as unknown as ExportedHandler<Env>,
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/token",
    clientRegistrationEndpoint: "/register",
    clientIdMetadataDocumentEnabled: true,
    scopesSupported: SCOPES_SUPPORTED,
    requiredScopes: [READ_SCOPE],
    resourceMetadata: { resource: `${origin}/mcp`, authorization_servers: [origin], resource_name: "OpenScribe" },
    accessTokenTTL: 3600,
    refreshTokenTTL: 365 * DAY,
    refreshTokenIdleTTL: 60 * DAY,
  };
}

// The provider depends on PUBLIC_URL, so build it lazily from env (and cache per origin).
let cached: { origin: string; provider: OAuthProvider<Env> } | undefined;

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (cached?.origin !== env.PUBLIC_URL) cached = { origin: env.PUBLIC_URL, provider: new OAuthProvider<Env>(oauthOptions(env)) };
    return cached.provider.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
