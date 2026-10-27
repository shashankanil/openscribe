import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "path";
import { existsSync } from "fs";

const input: Record<string, string> = {
  main: resolve(__dirname, "index.html"),
  flowbar: resolve(__dirname, "flowbar.html"),
  "meeting-notes": resolve(__dirname, "meeting-notes.html")
};

if (existsSync(resolve(__dirname, "region.html"))) {
  input.region = resolve(__dirname, "region.html");
}

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: {
    target: ["es2021", "chrome105", "safari13"],
    rollupOptions: {
      input
    }
  }
});
