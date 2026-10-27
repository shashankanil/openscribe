import React from "react";
import ReactDOM from "react-dom/client";
import { FlowbarApp } from "./FlowbarApp";
import { useWorkspaceTheme } from "../theme";

function Root() {
  useWorkspaceTheme();
  return <FlowbarApp />;
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>
);
