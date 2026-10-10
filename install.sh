#!/usr/bin/env bash
# Wire the agent adapters into each agent's config.
#   ./install.sh [claude|codex|opencode|pi|all] [--uninstall]
# Idempotent; backs up any JSON file it edits to <file>.bak.tmux-agent-status.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$ROOT/adapters/hook.sh"
MARK="tmux-agent-status"
BINDIR="${AGENT_STATUS_BINDIR:-$HOME/.local/bin}"
target=${1:-all}; action=install; [ "${2:-}" = --uninstall ] && action=uninstall
[ "$target" = --uninstall ] && { target=all; action=uninstall; }

link() { # src dst
  if [ "$action" = uninstall ]; then
    unlink "$2"
    return 0
  fi
  mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; echo "linked $2 -> $1"
}

unlink() { # dst
  if [ -L "$1" ]; then rm -f "$1"; echo "removed $1"; fi
}

# jq-merge hook entries "Event:command" into a Claude/Codex style hooks JSON file.
json_hooks() { # file agent events...
  local file=$1 agent=$2; shift 2
  command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
  if [ ! -f "$file" ]; then
    [ "$action" = install ] || return 0
    mkdir -p "$(dirname "$file")"; echo '{}' >"$file"
  fi
  cp -n "$file" "$file.bak.$MARK" 2>/dev/null || true
  local tmp; tmp=$(mktemp)
  local ev cmd
  # first strip our previous entries (so install is idempotent, uninstall is clean)
  jq --arg m "$MARK" '
    if .hooks then .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | contains($m) | not))) | map(select(.hooks | length > 0)))) | with_entries(select(.value | length > 0))) else . end
    | if (.hooks // {}) == {} then del(.hooks) else . end' "$file" >"$tmp"
  if [ "$action" = install ]; then
    for ev in "$@"; do
      cmd="bash '$HOOK' $agent $ev  # $MARK"
      jq --arg ev "$ev" --arg cmd "$cmd" \
        '.hooks[$ev] = ((.hooks[$ev] // []) + [{hooks: [{type: "command", command: $cmd, timeout: 5}]}])' \
        "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
    done
  fi
  mv "$tmp" "$file"; echo "$action: $file"
}

do_claude()   { json_hooks "$HOME/.claude/settings.json" claude UserPromptSubmit PostToolUse Notification Stop SessionEnd; }
do_codex()    { json_hooks "$HOME/.codex/hooks.json" codex UserPromptSubmit PostToolUse PermissionRequest Stop
                if [ "$action" = install ]; then echo "codex: review the new hooks in codex (/hooks) so they are trusted"; fi; }
do_opencode() {
  local version v1="$HOME/.config/opencode/plugin/tmux-agent-status.js" v2="$HOME/.config/opencode/plugins/tmux-agent-status.js"
  if [ "$action" = uninstall ]; then
    unlink "$v1"
    unlink "$v2"
    return 0
  fi

  if command -v opencode >/dev/null 2>&1; then
    version=$(opencode --version 2>/dev/null || true)
  else
    echo "OpenCode not found; defaulting to the V1 plugin"
    version=v1.0
  fi

  case "$version" in
    *v2.*|*" 2."*|2.*)
      unlink "$v1"
      link "$ROOT/adapters/opencode/tmux-agent-status-v2.js" "$v2" ;;
    *)
      unlink "$v2"
      link "$ROOT/adapters/opencode/tmux-agent-status.js" "$v1"
      ;;
  esac
}
do_pi()       { link "$ROOT/adapters/pi" "$HOME/.pi/agent/extensions/tmux-agent-status"; }

link "$ROOT/bin/agent-status" "$BINDIR/agent-status"
case $target in
  claude) do_claude ;; codex) do_codex ;; opencode) do_opencode ;; pi) do_pi ;;
  all) do_claude; do_codex; do_opencode; do_pi ;;
  *) echo "usage: $0 [claude|codex|opencode|pi|all] [--uninstall]" >&2; exit 2 ;;
esac
