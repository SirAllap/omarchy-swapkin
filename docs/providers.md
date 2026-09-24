# Providers

Swapkin started as a Claude Code account switcher. It is now a small engine
plus one file per tool ("provider") that knows how that tool stores a login.
Claude keeps working exactly as before; everything below is what changed and
how to add your own tool.

## Picking a provider

```
swapkin -p codex usage
swapkin --provider copilot list --json
SWAPKIN_PROVIDER=codex swapkin status
```

No `-p`/`--provider`/`SWAPKIN_PROVIDER` means `claude`, and every command the
panel and status line already use (`list --json`, `usage`, `cost`,
`statusline`, `use`, `add`, `colour`, `remove`, `check`) still means Claude by
default, unchanged.

## What each provider looks like

Three modes:

- **hot** — one shared login file (Claude, or a custom hot provider). A switch
  saves the outgoing account's live login back into its own profile, then
  overwrites the live file with the incoming account's. Open sessions notice
  on their next request.
- **cold** — a separate home per account (Codex, or a custom cold provider).
  A switch only moves a pointer: `swapkin use <name>` decides which account
  *new* sessions get. Point a shell at one with `eval "$(swapkin env <id>)"`,
  or run one directly with `swapkin run <id> -- <args>`. Sessions already
  running keep whatever they started with.
- **never** — the tool only remembers one login; switching means signing in
  again. (No built-in provider ships as `never` in v1; the mode exists for a
  future one.)

Copilot is a special cold case: it is backed by `gh`'s own account switch
(`gh auth switch`), so `swapkin -p copilot use <name>` runs that instead of
moving files around.

## New commands

- `swapkin providers --json` — every provider that is installed or has a
  saved account, with its accounts and their usage. Read-only, no network:
  it reads each account's already-saved `usage.json`.
- `swapkin usage` — with no `-p`/`SWAPKIN_PROVIDER`, probes every provider in
  the background and waits. With `-p`, probes just that one (as `usage`
  always did for Claude).
- `swapkin check` — always Claude's watchdog pass, regardless of `-p`.
- `swapkin env [id]` — for cold providers, prints `export KEY=value` lines
  for the active account (paths and names only, never a token). With no id,
  prints one block per cold provider. Put it in a shell rc:
  `eval "$(swapkin env)"`.
- `swapkin run <id> [-- args]` — runs that provider's own CLI with its
  active account's environment already set.
- `swapkin demo on|off` — turns demo mode on or off.

## Storage layout

```
$SWAPKIN_DIR/<name>/                     Claude — unchanged
$SWAPKIN_DIR/active                      Claude's active pointer — unchanged
$SWAPKIN_DIR/providers/<id>/<name>/      every other provider
$SWAPKIN_DIR/providers/<id>/active
```

`$SWAPKIN_DIR` defaults to `${XDG_DATA_HOME:-~/.local/share}/swapkin`.

## `usage.json` (what `p_probe` writes per account)

```json
{
  "limits": [
    { "label": "Weekly", "title": "Weekly", "percent": 0.42, "resetsAt": "2026-10-01T00:00:00Z",
      "used": 84, "limit": 200, "unit": "requests" }
  ],
  "counts": [
    { "label": "Requests today", "value": 17, "unit": "requests" }
  ],
  "tierLabel": "Pro",
  "note": "",
  "updatedAt": "2026-09-24T12:00:00Z"
}
```

`percent` is a fraction (0..1); the panel multiplies by 100. `label` has to
let the panel tell windows apart — something matching `Session (5-hour)` /
`5h window` / `Weekly` / `... month ...` — `title` is an optional override for
display. For a tool with no hard ceiling, use `counts` instead of inventing a
percent.

## Safety

A login made by hand under the currently-active account name (for example
running the tool's own `/login` or `login` command directly, instead of
through `swapkin add`) is saved into that account on the next `save`, `use`,
or `usage` — because swapkin has no way to tell it apart from that account's
own login. Sign in through `swapkin add` instead when you mean to add a new
account, not replace the current one.

