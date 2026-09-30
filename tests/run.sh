#!/usr/bin/env bash
# Tests run against a private tmux server (-L) and a temp state dir.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/agent-status"
T=$(mktemp -d); export AGENT_STATUS_DIR="$T/state"; export XDG_RUNTIME_DIR="$T"
SOCKNAME="tas-test-$$"
tm() { tmux -L "$SOCKNAME" "$@"; }
cleanup() { pkill -P $$ sleep 2>/dev/null; tm kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

LOG="$T/notify.log"; : >"$LOG"
printf '#!/bin/sh\necho "$1|$2" >>"%s"\n' "$LOG" >"$T/nstub"; chmod +x "$T/nstub"
export AGENT_STATUS_NOTIFY_CMD="$T/nstub"   # never touch the real desktop
pass=0 fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }

# Server with one session, three windows running a long "agent" (sleep), one plain shell.
tm -f /dev/null new-session -d -s main -x 120 -y 30 "exec -a claude sleep 600"
tm new-window -d -t main "exec -a pi sleep 600"
tm new-window -d -t main "exec -a codex sleep 600"
tm new-window -d -t main            # plain shell (default-command)
tm set -g default-command "exec sleep 600"
# tmux gives pane_current_command from the process name; rename via exec -a isn't visible,
# so use real sleep processes and fake "shell" detection through a bash pane below.
sleep 0.3
sleep 300 | tm -C attach -t main >/dev/null 2>&1 &      # a client, so switch-client works
sleep 0.5
CLIENT=$(tm list-clients -F '#{client_name}' | head -1)
export TMUX; TMUX="$(tm display-message -p '#{socket_path},#{pid},0')"
P1=$(tm list-panes -a -F '#{pane_id}' | sed -n 1p)
P2=$(tm list-panes -a -F '#{pane_id}' | sed -n 2p)
P3=$(tm list-panes -a -F '#{pane_id}' | sed -n 3p)
PSH=$(tm list-panes -a -F '#{pane_id}' | sed -n 4p)
as() { local pane=$1; shift; AGENT_STATUS_PANE=$pane AGENT_STATUS_FOCUSED=${FOC:-0} "$BIN" "$@"; }
summary() { tm show-option -gqv @agent_summary; }
mark()    { tm show-option -wqv -t "$1" @agent_mark; }
win()     { tm display-message -p -t "$1" '#{window_id}'; }

echo "no-op outside tmux"
out=$(env -u TMUX "$BIN" set waiting 2>&1); eq "silent no-op" "$out" ""

echo "state + bar summary"
as "$P1" set working --agent claude
eq "working shows nothing in bar" "$(summary)" ""
as "$P1" set waiting --agent claude --msg "run rm?"
case "$(summary)" in *"⚠1"*) ok "waiting shows ⚠1";; *) bad "waiting shows ⚠1" "$(summary)";; esac
case "$(mark "$(win "$P1")")" in *"⚠"*) ok "window marked ⚠";; *) bad "window marked" "$(mark "$(win "$P1")")";; esac
as "$P2" set working --agent pi
as "$P2" set done --agent pi
s=$(summary); case "$s" in *"⚠1"*"✓1"*) ok "waiting then done ordering";; *) bad "summary both" "$s";; esac

echo "list ordering"
first=$(as "$P1" list | head -1 | cut -f1); eq "waiting listed first" "$first" "$P1"
eq "three... two records listed" "$(as "$P1" list | wc -l)" "2"

echo "transition back to working clears"
as "$P1" set working
eq "waiting cleared when working resumes" "$(mark "$(win "$P1")")" ""
case "$(summary)" in *"⚠"*) bad "no ⚠ left" "$(summary)";; *) ok "no ⚠ left";; esac

echo "seen clears done only when focused"
FOC=0 as "$P2" seen "$P2"
case "$(summary)" in *"✓1"*) ok "unfocused seen keeps ✓";; *) bad "unfocused seen keeps ✓" "$(summary)";; esac
FOC=1 as "$P2" seen "$P2"
eq "focused seen clears ✓" "$(summary)" ""

echo "done while watching leaves no record"
FOC=1 as "$P3" set working --agent codex
FOC=1 as "$P3" set done
eq "no record for focused done" "$(as "$P3" list | wc -l)" "1"   # P1 still working

echo "gc: pane closed / agent back at shell"
as "$P3" set waiting --agent codex
tm kill-pane -t "$P3"; sleep 0.2
as "$P1" refresh
case "$(summary)" in *"⚠"*) bad "closed pane gc'd" "$(summary)";; *) ok "closed pane gc'd";; esac
tm respawn-pane -k -t "$PSH" "bash --norc -i"; sleep 0.3
as "$PSH" set waiting --agent claude
as "$PSH" refresh
eq "shell-pane record dropped" "$(as "$P1" list | cut -f1 | grep -c "^$PSH\$")" "0"

echo "notifications"
: >"$LOG"; rm -f "$AGENT_STATUS_DIR"/*.n
FOC=0 as "$P1" set waiting --agent claude --msg "need ok"; sleep 0.3
eq "notify on waiting (unfocused)" "$(grep -c 'claude needs you' "$LOG")" "1"
FOC=0 as "$P1" set working; FOC=0 as "$P1" set waiting; sleep 0.3
eq "debounced re-notify" "$(wc -l <"$LOG")" "1"
: >"$LOG"; tm set -g @agent-status-debounce 0
FOC=1 as "$P1" set working; FOC=1 as "$P1" set waiting; sleep 0.3
eq "suppressed when focused" "$(wc -l <"$LOG")" "0"
FOC=0 as "$P1" set working; FOC=0 as "$P1" set done; sleep 0.3
eq "done silent by default" "$(wc -l <"$LOG")" "0"
tm set -g @agent-status-notify-done on
FOC=0 as "$P1" set working; FOC=0 as "$P1" set done; sleep 0.3
eq "done notifies when enabled" "$(grep -c 'finished' "$LOG")" "1"
tm set -g @agent-status-notify-done-min-secs 999
: >"$LOG"; FOC=0 as "$P1" set working; FOC=0 as "$P1" set done; sleep 0.3
eq "done respects min duration" "$(wc -l <"$LOG")" "0"
tm set -g @agent-status-notify off
FOC=0 as "$P1" set working; FOC=0 as "$P1" set waiting; sleep 0.3
eq "notify=off silences" "$(wc -l <"$LOG")" "0"

echo "jump next"
as "$P1" clear; as "$P2" clear
as "$P1" set working --agent claude
as "$P2" set working --agent pi
FOC=0 as "$P2" set done; sleep 1
FOC=0 as "$P1" set waiting
tm select-window -t "$(win "$P2")"
"$BIN" jump next "$CLIENT" "$P2"
eq "jumps to oldest waiting" "$(tm display-message -p '#{pane_id}')" "$P1"
as "$P1" clear
"$BIN" jump next "$CLIENT" ""
eq "falls back to done" "$(tm display-message -p '#{pane_id}')" "$P2"

echo "plugin entry is idempotent"
tm set -g status-right "RIGHT"; tm set -gw window-status-format " #I:#W "
tm set -g @agent-status-key-pick "" ; tm set -g @agent-status-key-next ""
for _ in 1 2; do TMUX_PANE= "$ROOT/agent-status.tmux"; done
eq "status-right prefixed once" "$(tm show-option -gv status-right | grep -o '@agent_summary' | wc -l)" "1"
eq "window format marked once" "$(tm show-option -gwv window-status-format | grep -o '?@agent_mark' | wc -l)" "1"
eq "hook installed once" "$(tm show-hooks -gw | grep -c '^pane-focus-in\[91\]')" "1"

echo; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
