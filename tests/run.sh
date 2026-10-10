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
as "$P2" set "done" --agent pi
s=$(summary); case "$s" in *"⚠1"*"✓1"*) ok "waiting then done ordering";; *) bad "summary both" "$s";; esac

echo "list ordering"
first=$(as "$P1" list | head -1 | cut -f1); eq "waiting listed first" "$first" "$P1"
eq "two reported agents listed" "$(as "$P1" list | grep -vc '○')" "2"
eq "unreported agent pane discovered by name" "$(as "$P1" list | grep -c '○')" "1"
eq "discovered pane is the third one" "$(as "$P1" list | grep '○' | cut -f1)" "$P3"
eq "discovered agents never hit the bar" "$(summary | grep -c '○')" "0"

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
FOC=1 as "$P3" set "done"
eq "no record for focused done" "$(as "$P3" list | grep -vc '○')" "1"   # P1 still working

echo "gc: pane closed / agent back at shell"
as "$P3" set waiting --agent codex
tm kill-pane -t "$P3"; sleep 0.2
as "$P1" refresh
case "$(summary)" in *"⚠"*) bad "closed pane gc'd" "$(summary)";; *) ok "closed pane gc'd";; esac
tm respawn-pane -k -t "$PSH" "bash --norc -i"; sleep 0.3
as "$PSH" set waiting --agent claude
as "$PSH" refresh
eq "shell-pane record dropped" "$(as "$P1" list | cut -f1 | grep -c "^$PSH\$")" "0"

echo "wrapper shells (sh -c 'agent; ...') do not look dead"
tm respawn-pane -k -t "$P1" "sh -c 'sleep 300; true'"; sleep 0.4
# The trap: the pane's command is a shell, so "is the agent still alive?" cannot
# be answered from pane_current_command alone. Which name tmux reports is
# host-dependent -- macOS /bin/sh is bash underneath and is reported as "bash",
# not "sh" -- so accept any shell this plugin treats as one (see is_shell).
cmd=$(tm display-message -p -t "$P1" '#{pane_current_command}')
case " $cmd " in
  " bash "|" zsh "|" fish "|" sh "|" dash "|" ksh "|" tcsh "|" nu "|" login ")
    ok "foreground command is a shell (the trap)" ;;
  *) bad "foreground command is a shell (the trap)" "expected a shell, got [$cmd]" ;;
esac
as "$P1" set working --agent claude
eq "record survives: agent runs under the wrapper" "$(as "$P1" list | grep -c claude)" "1"
tm respawn-pane -k -t "$P1" "exec -a claude sleep 600"; sleep 0.3; as "$P1" clear

echo "banner (tmux status line only)"
rm -f "$AGENT_STATUS_DIR"/*.n
msgs() { tm show-messages -t "$CLIENT" 2>/dev/null | grep -c 'needs you'; }
base=$(msgs)
FOC=0 as "$P1" set working --agent claude; FOC=0 as "$P1" set waiting --agent claude --msg "need ok"
eq "banner is off by default" "$(( $(msgs) - base ))" "0"
tm set -g @agent-status-banner on
FOC=0 as "$P1" set working; FOC=0 as "$P1" set waiting --msg "need ok"; sleep 0.3
eq "banner shows when an agent starts waiting" "$(( $(msgs) - base ))" "1"
tm show-messages -t "$CLIENT" | grep -q 'claude needs you · main:.*need ok' && ok "banner text: agent, place, message" || bad "banner text" "$(tm show-messages -t "$CLIENT" | tail -2)"
FOC=0 as "$P1" set working; FOC=0 as "$P1" set waiting; sleep 0.3
eq "debounced: no second banner within 10s" "$(( $(msgs) - base ))" "1"
tm set -g @agent-status-debounce 0
FOC=1 as "$P1" set working; FOC=1 as "$P1" set waiting; sleep 0.3
eq "no banner when you are looking at the pane" "$(( $(msgs) - base ))" "1"
FOC=0 as "$P1" set working; FOC=0 as "$P1" set "done"; sleep 0.3
eq "done never shows a banner" "$(( $(msgs) - base ))" "1"
tm set -gu @agent-status-banner; tm set -gu @agent-status-debounce
as "$P1" clear

echo "jump next"
as "$P1" clear; as "$P2" clear
as "$P1" set working --agent claude
as "$P2" set working --agent pi
FOC=0 as "$P2" set "done"; sleep 1
FOC=0 as "$P1" set waiting
tm select-window -t "$(win "$P2")"
"$BIN" jump next "$CLIENT" "$P2"
eq "jumps to oldest waiting" "$(tm display-message -p '#{pane_id}')" "$P1"
as "$P1" clear
"$BIN" jump next "$CLIENT" ""
eq "falls back to done" "$(tm display-message -p '#{pane_id}')" "$P2"

tm select-window -t "$(win "$P2")"
"$BIN" jump pane "$P1" '#{client_name}'
eq "unexpanded client format falls back to active client" "$(tm display-message -p -c "$CLIENT" '#{pane_id}')" "$P1"
tm select-window -t "$(win "$P2")"
"$BIN" jump pane "$P1" ""
eq "empty client falls back too" "$(tm display-message -p -c "$CLIENT" '#{pane_id}')" "$P1"

echo "fzf-less menu + key entry point"
as "$P1" clear; as "$P1" set working --agent claude; as "$P1" set waiting --agent claude --msg 'ok #(x)'
# A valid menu blocks until dismissed, so "still running at the timeout" (124)
# with no output means valid; a bad command line fails at once with a message.
# A control-mode client -- which is what this harness attaches -- returns 0
# immediately instead of blocking on some platforms, which is equally valid, so
# accept a clean 0 too and reject only output or an unexpected status.
menu_valid() { case "$1:$2" in 124:*|0:) return 0 ;; *) return 1 ;; esac; }
out=$(timeout 2 "$BIN" menu "$CLIENT" 2>&1); rc=$?
menu_valid "$rc" "$out" && ok "menu is valid and shown (no fzf needed)" || bad "menu is valid and shown (no fzf needed)" "rc=$rc out=$out"
tm send-keys -K -c "$CLIENT" Escape; sleep 0.3
out=$(AGENT_STATUS_NO_FZF=1 AGENT_STATUS_PANE=$P1 timeout 2 "$BIN" open "$CLIENT" 2>&1); rc=$?
menu_valid "$rc" "$out" && ok "open falls back to the menu when fzf is missing" || bad "open falls back to the menu when fzf is missing" "rc=$rc out=$out"
tm send-keys -K -c "$CLIENT" Escape; sleep 0.3
tm bind-key -T prefix z run-shell "true"; TMUX_PANE="" "$ROOT/agent-status.tmux"
case "$(tm list-keys -T prefix | grep ' a ')" in *"agent-status' open"*) ok "key a is bound to 'open'";; *) bad "key a is bound to open" "$(tm list-keys -T prefix | grep ' a ')";; esac
as "$P1" clear

echo "degrades without ps / jq"
tm respawn-pane -k -t "$PSH" "bash --norc -i"; sleep 0.3
as "$PSH" set waiting --agent claude; AGENT_STATUS_NO_PS=1 as "$PSH" refresh
eq "no ps: shell pane still dropped via foreground command" "$(as "$P1" list | cut -f1 | grep -c "^$PSH\$")" "0"
as "$P1" clear; as "$P1" set working --agent claude; AGENT_STATUS_NO_PS=1 as "$P1" refresh
eq "no ps: reported agent is kept, nothing mass-deleted" "$(as "$P1" list | grep -v '○' | grep -c claude)" "1"
as "$P1" clear
export AGENT_STATUS_PANE=$P1 AGENT_STATUS_FOCUSED=0
echo '{"notification_type":"idle_prompt","message":"m"}' | AGENT_STATUS_NO_JQ=1 "$ROOT/adapters/hook.sh" claude Notification
eq "no jq: idle_prompt is not treated as waiting" "$(as "$P1" list | grep -v '○' | grep -c claude)" "0"
echo '{"notification_type":"permission_prompt","message":"needs Bash"}' | AGENT_STATUS_NO_JQ=1 "$ROOT/adapters/hook.sh" claude Notification
eq "no jq: permission prompt is waiting, message parsed" "$(as "$P1" list | grep -c 'needs Bash')" "1"
as "$P1" clear; unset AGENT_STATUS_PANE AGENT_STATUS_FOCUSED

echo "hardening"
as "$P1" clear
as "$P1" set waiting --agent "cl\$(touch $T/pwn)aude" --msg $'esc\e[31m red\ttab #(touch '"$T"'/pwn2)'
rec=$(cat "$AGENT_STATUS_DIR"/*_"${P1#%}")
case "$rec" in *$'\e'*) bad "control chars stripped from message" "$rec";; *) ok "control chars stripped from message";; esac
name=$(cut -f2 <<<"$rec")
[[ $name =~ ^[A-Za-z0-9._-]{1,32}$ ]] && ok "agent name reduced to safe chars" || bad "agent name reduced to safe chars" "$name"
tm set -g @agent-status-banner on
as "$P1" clear; as "$P1" set working; as "$P1" set waiting --agent claude --msg 'x #(touch '"$T"'/pwn3) #{session_name}'; sleep 0.5
[ ! -e "$T/pwn3" ] && ok "tmux banner does not expand #(...) from agent text" || bad "tmux banner does not expand #(...) from agent text" "command ran"
[ ! -e "$T/pwn" ] && [ ! -e "$T/pwn2" ] && ok "no command substitution from agent name/message" || bad "no command substitution" "command ran"
tm set -gu @agent-status-banner

echo "plugin entry is idempotent"
tm set -g status-right "RIGHT"; tm set -gw window-status-format " #I:#W "
tm set -g @agent-status-key-pick "" ; tm set -g @agent-status-key-next ""
for _ in 1 2; do TMUX_PANE="" "$ROOT/agent-status.tmux"; done
# BSD wc pads its count to a fixed width, GNU does not: strip it.
eq "status-right prefixed once" "$(tm show-option -gv status-right | grep -o '@agent_summary' | wc -l | tr -d ' ')" "1"
eq "window format marked once" "$(tm show-option -gwv window-status-format | grep -o '?@agent_mark' | wc -l | tr -d ' ')" "1"
eq "hook installed once" "$(tm show-hooks -gw | grep -c '^pane-focus-in\[91\]')" "1"

echo; echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
