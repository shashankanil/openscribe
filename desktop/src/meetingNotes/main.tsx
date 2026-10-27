import React from "react";
import ReactDOM from "react-dom/client";
import { MeetingNotesApp } from "./MeetingNotesApp";
import { useWorkspaceTheme } from "../theme";

function Root() {
  useWorkspaceTheme();
  return <MeetingNotesApp />;
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>
);
