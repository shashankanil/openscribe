// Bindings for this Worker. Keep in sync with wrangler.jsonc and README.md.
declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("./index");
  }
  interface Env {
    DB: D1Database;
    OAUTH_KV: KVNamespace;
    /** Public origin, no trailing slash, e.g. https://openscribe-cloud.example.workers.dev */
    PUBLIC_URL: string;
    APP_DOWNLOAD_URL: string;
    /** Secrets (wrangler secret put …) */
    GOOGLE_CLIENT_ID: string;
    GOOGLE_CLIENT_SECRET: string;
    COOKIE_ENCRYPTION_KEY: string;
    /** Optional secret/var: restrict sign-in to one Google Workspace domain. */
    HOSTED_DOMAIN?: string;
  }
}
interface Env extends Cloudflare.Env {}
