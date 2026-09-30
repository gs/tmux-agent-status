#!/usr/bin/env bash
# tmux-agent-status: TPM entry point. Also works with a plain
#   run-shell ~/code/tmux-agent-status/agent-status.tmux
# Idempotent: safe to source again on config reload.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$CURRENT_DIR/bin/agent-status"

get() { local v; v=$(tmux show-option -gqv "$1"); printf '%s' "${v:-$2}"; }
off() { case "$(get "$1" on)" in off|0|no|false) return 0 ;; esac; return 1; }

# Keys. key-pick may hold several keys (default "a A"); "" skips a binding.
# key-next (default none) is a one-key "jump to oldest agent that needs me".
key_pick=$(get @agent-status-key-pick "a A")
key_next=$(get @agent-status-key-next "")
for k in $key_pick; do
  tmux bind-key -N "Agent list (search + jump)" "$k" \
    run-shell "tmux display-popup -c '#{client_name}' -E -w 80% -h 70% -T ' agents ' \"'$BIN' pick '#{client_name}'\""
done
[ -n "$key_next" ] && tmux bind-key -N "Jump to next agent that needs you" "$key_next" \
  run-shell "'$BIN' jump next '#{client_name}' '#{pane_id}'"

# Hooks live in slot [91] so re-sourcing replaces instead of stacking.
seen="run-shell -b \"'$BIN' seen '#{pane_id}'\""
gc="run-shell -b \"'$BIN' refresh\""
# pane-focus-in and pane-exited are window-level hooks in tmux (-gw); the rest
# are session-level (-g).
tmux set-hook -gw "pane-focus-in[91]" "$seen"
tmux set-hook -gw "pane-exited[91]" "$gc"
for h in client-session-changed after-select-window; do tmux set-hook -g "$h[91]" "$seen"; done
for h in after-kill-pane window-unlinked session-closed; do tmux set-hook -g "$h[91]" "$gc"; done

# Bar segment + window marker, added only if not already present.
tmux set-option -gq @agent_summary ""
if ! off @agent-status-modify-status; then
  cur=$(tmux show-option -gv status-right)
  case $cur in *@agent_summary*) ;; *) tmux set-option -g status-right "#{@agent_summary}$cur" ;; esac
fi
if ! off @agent-status-modify-window-format; then
  add='#{?@agent_mark,#{@agent_mark} ,}'   # sits right after the name it belongs to
  for o in window-status-format window-status-current-format; do
    cur=$(tmux show-option -gwv "$o")
    case $cur in *@agent_mark*) ;; *) tmux set-option -gw "$o" "$cur$add" ;; esac
  done
fi

tmux run-shell -b "'$BIN' refresh"
