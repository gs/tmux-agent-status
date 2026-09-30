// pi extension: reports agent state to tmux-agent-status.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";

const BIN = process.env.AGENT_STATUS_BIN || "agent-status";

function report(...args: string[]) {
  if (!process.env.TMUX_PANE) return;
  try {
    const extra = args[0] === "set" ? ["--agent", "pi"] : [];
    spawn(BIN, [...args, ...extra], { stdio: "ignore", detached: true })
      .on("error", () => {})
      .unref();
  } catch {}
}

export default function (pi: ExtensionAPI) {
  pi.on("agent_start", () => report("set", "working"));
  pi.on("agent_settled", () => report("set", "done"));
  pi.on("session_shutdown", () => report("clear"));
}
