// OpenCode V2 plugin: reports session state to tmux-agent-status.
import { spawn } from "node:child_process"

const BIN = process.env.AGENT_STATUS_BIN || "agent-status"

const run = (...args) => {
  if (!process.env.TMUX_PANE) return
  try {
    spawn(BIN, [...args, ...(args[0] === "set" ? ["--agent", "opencode"] : [])], {
      stdio: "ignore",
      detached: true,
    }).on("error", () => {}).unref()
  } catch {}
}

export default {
  id: "tmux-agent-status",
  setup(ctx) {
    // Child sessions must not change the tmux pane's state.
    const children = new Set()
    const controller = new AbortController()

    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        // V2 public events carry payloads in `data`; retain `properties` as a
        // fallback for servers that still emit the V1 event envelope.
        const p = event.data ?? event.properties ?? {}
        switch (event.type) {
          case "session.created":
            if ((p.info ?? p).parentID) children.add((p.info ?? p).id)
            break
          case "session.status":
            if (!children.has(p.sessionID) && p.status?.type === "busy") run("set", "working")
            break
          case "session.execution.started":
          case "session.step.started":
            if (!children.has(p.sessionID)) run("set", "working")
            break
          case "session.step.ended":
            if (!children.has(p.sessionID) && p.finish !== "tool-calls") run("set", "done")
            break
          case "session.execution.succeeded":
          case "session.execution.failed":
          case "session.execution.interrupted":
          case "session.step.failed":
            if (!children.has(p.sessionID)) run("set", "done")
            break
          case "permission.asked":
          case "permission.updated":
            if (!children.has(p.sessionID)) {
              run("set", "waiting", "--msg", `permission: ${p.message ?? p.action ?? p.title ?? p.type ?? ""}`)
            }
            break
          case "permission.replied":
            if (!children.has(p.sessionID)) run("set", "working")
            break
          case "session.idle":
          case "session.error":
            if (!children.has(p.sessionID)) run("set", "done")
            break
        }
      }
    })().catch((error) => console.error("[tmux-agent-status] event stream failed", error))

    return () => controller.abort()
  },
}
