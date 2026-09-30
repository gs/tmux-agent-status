// opencode plugin: reports session state to tmux-agent-status.
import { spawn } from "node:child_process"

const BIN = process.env.AGENT_STATUS_BIN || "agent-status"
const run = (...args) => {
  if (!process.env.TMUX_PANE) return
  try { spawn(BIN, [...args, ...(args[0] === "set" ? ["--agent", "opencode"] : [])], { stdio: "ignore", detached: true }).on("error", () => {}).unref() } catch {}
}

export const TmuxAgentStatus = async () => {
  const children = new Set() // sub-agent sessions must not flip the pane state
  return {
    event: async ({ event }) => {
      const p = event.properties ?? {}
      switch (event.type) {
        case "session.created":
          if (p.info?.parentID) children.add(p.info.id)
          break
        case "session.status":
          if (!children.has(p.sessionID) && p.status?.type === "busy") run("set", "working")
          break
        case "permission.updated":
          if (!children.has(p.sessionID)) run("set", "waiting", "--msg", `permission: ${p.title ?? p.type ?? ""}`)
          break
        case "permission.replied":
          if (!children.has(p.sessionID)) run("set", "working")
          break
        case "session.idle":
        case "session.error":
          if (!children.has(p.sessionID)) run("set", "done")
          break
      }
    },
  }
}
