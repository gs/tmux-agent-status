#!/usr/bin/env bash
# Shared hook adapter for Claude Code and Codex.  Usage: hook.sh <agent> <Event>
# Reads the hook JSON on stdin, prints nothing (hook stdout can feed the model),
# never fails the agent.
agent=${1:-agent}; event=${2:-}
BIN="${AGENT_STATUS_BIN:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin/agent-status}"
payload=$(cat 2>/dev/null)
field() { command -v jq >/dev/null 2>&1 && jq -r ".$1 // empty" <<<"$payload" 2>/dev/null; }

case $event in
  UserPromptSubmit|PostToolUse|PostToolUseFailure)
    "$BIN" set working --agent "$agent" ;;
  Notification)
    # idle_prompt/auth_success are not "blocked on you".
    case $(field notification_type) in idle_prompt|auth_success) ;; *)
      "$BIN" set waiting --agent "$agent" --msg "$(field message)" ;; esac ;;
  PermissionRequest)
    "$BIN" set waiting --agent "$agent" --msg "permission: $(field tool_name)" ;;
  Stop)
    "$BIN" set "done" --agent "$agent" ;;
  SessionEnd)
    "$BIN" clear ;;
esac >/dev/null 2>&1
exit 0
