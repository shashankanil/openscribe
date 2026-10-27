import { invoke } from "@tauri-apps/api/core";
import { isDrag, selectionRect, type Point, type Rect } from "./selection";
import "./overlay.css";

const selection = document.querySelector<HTMLDivElement>("#selection");
const shade = document.querySelector<HTMLDivElement>("#shade");

let start: Point | null = null;
let sent = false;

function place(rect: Rect) {
  if (!selection) return;
  selection.hidden = false;
  selection.style.left = `${rect.x}px`;
  selection.style.top = `${rect.y}px`;
  selection.style.width = `${rect.width}px`;
  selection.style.height = `${rect.height}px`;
  if (shade) shade.hidden = true;
}

function finish(rect: Rect | null) {
  if (sent) return;
  sent = true;
  if (rect && isDrag(rect)) {
    void invoke("complete_region_select", {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio
    });
    return;
  }
  void invoke("cancel_region_select");
}

window.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    finish(null);
  }
});

window.addEventListener("pointerdown", (event) => {
  if (event.button !== 0 || sent) return;
  start = { x: event.clientX, y: event.clientY };
  document.documentElement.setPointerCapture(event.pointerId);
});

window.addEventListener("pointermove", (event) => {
  if (!start) return;
  place(selectionRect(start, { x: event.clientX, y: event.clientY }));
});

window.addEventListener("pointerup", (event) => {
  if (!start) return;
  const rect = selectionRect(start, { x: event.clientX, y: event.clientY });
  start = null;
  finish(rect);
});

window.addEventListener("contextmenu", (event) => event.preventDefault());
