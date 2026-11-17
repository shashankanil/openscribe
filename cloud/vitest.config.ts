import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            PUBLIC_URL: "https://cloud.test",
            GOOGLE_CLIENT_ID: "test-client-id.apps.googleusercontent.com",
            GOOGLE_CLIENT_SECRET: "test-client-secret",
            COOKIE_ENCRYPTION_KEY: "test-cookie-key-0123456789abcdef0123456789abcdef",
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/apply-migrations.ts"] },
  };
});
