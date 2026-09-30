# tmux-agent-status

Quiet status for the coding agents (Claude Code, Codex, opencode, pi) running in
your tmux panes. Nothing shows until an agent needs you.

| state   | meaning                        | bar / window marker | desktop notification        |
|---------|--------------------------------|---------------------|-----------------------------|
| working | agent busy                     | nothing             | never                       |
| waiting | blocked on permission/question | `⚠N` / `⚠`          | once, if you aren't looking |
| done    | finished, not yet seen         | `✓N` / `✓`          | off (opt-in)                |

`done` clears itself when you focus the pane. Records of closed panes, or panes
whose agent quit back to a shell, are dropped automatically.

## Keys

- `prefix a` / `prefix A`  searchable fzf popup of every agent in every session: reported
  state first (`⚠` waiting, `✓` done, `●` working), then agents found only by process
  name (`○`, from `@agent-status-agents`, default `pi claude codex opencode`). Type to
  filter, live pane preview, enter jumps.
- Optional `@agent-status-key-next`: jump straight to the oldest agent that needs you.

## Install

TPM: `set -g @plugin 'you/tmux-agent-status'`, or without TPM add to `tmux.conf`:

    run-shell ~/code/tmux-agent-status/agent-status.tmux

Load it after your status bar options (it prepends `#{@agent_summary}` to
`status-right` and appends `#{?@agent_mark, ...}` to the window formats). Then wire
the agents (each step is optional, idempotent, and reversible with `--uninstall`):

    ./install.sh all          # or: claude | codex | opencode | pi

- **claude**: adds hooks to `~/.claude/settings.json` (existing hooks are left alone).
- **codex**: adds hooks to `~/.codex/hooks.json`; approve them once in codex (`/hooks`).
- **opencode**: symlinks a plugin into `~/.config/opencode/plugin/`.
- **pi**: symlinks an extension into `~/.pi/agent/extensions/`. pi has no built-in
  permission prompts, so it reports working and done only.

It also links `agent-status` into `~/.local/bin`.

## Options (`set -g @agent-status-… value`)

| option | default | |
|---|---|---|
| `key-pick` / `key-next` | `a A` / none | keys for the popup / one-key jump-to-waiting |
| `agents` | `pi claude codex opencode` | process names listed even before they report |
| `notify` | `on` | master switch for desktop notifications |
| `notify-done` | `off` | also notify when an agent finishes |
| `notify-done-min-secs` | `0` | only if the run took at least this long |
| `debounce` | `10` | min seconds between notifications per pane |
| `tmux-message` | `off` | also show a tmux message on notify |
| `icon-waiting` / `icon-done` | `⚠` / `✓` | |
| `color-waiting` / `color-done` | `yellow` / `green` | |
| `modify-status` / `modify-window-format` | `on` | set `off` to place `#{@agent_summary}` / `#{@agent_mark}` yourself |

Notifications prefer `omarchy-notification-send` (toast with glyph; **click jumps to
the pane and raises the terminal**), fall back to `notify-send`, and do nothing if
neither exists. Extra options: `urgency-waiting` (`critical`), `urgency-done`
(`normal`), `glyph-waiting`, `glyph-done`. `tmux-message on` also shows a banner on
every client's status line. Override everything with `AGENT_STATUS_NOTIFY_CMD`
(called as `cmd TITLE BODY`).

## How it works

Agents push state through hooks: `agent-status set working|waiting|done`. State is
one small file per pane in `$XDG_RUNTIME_DIR/agent-status/`. Every change recomputes
the `@agent_summary` / `@agent_mark` tmux options, so the bar updates instantly with
no polling. Everything is a silent no-op outside tmux and hooks never fail the agent.

## Tests

    tests/run.sh      # private tmux server, stubbed notifier
