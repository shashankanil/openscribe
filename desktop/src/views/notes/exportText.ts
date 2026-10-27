import { invoke } from "@tauri-apps/api/core";
import { save } from "@tauri-apps/plugin-dialog";

/** Cancellation is distinct from a successful atomic native write. Errors propagate to the caller. */
export async function exportText(text: string, title: string, extension: "txt" | "md"): Promise<boolean> {
  const name = title.slice(0, 80).replace(/[<>:"/\\|?*\x00-\x1f]/g, "-").replace(/[. ]+$/, "") || "Note";
  const path = await save({ defaultPath: `${name}.${extension}`, filters: [{ name: extension === "md" ? "Markdown" : "Plain text", extensions: [extension] }] });
  if (!path) return false;
  await invoke<void>("export_text_file", { path, text });
  return true;
}
