import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Safe to run repeatedly: only unapplied migrations are applied.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
