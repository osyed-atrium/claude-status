# Claude Status

A macOS menu bar indicator for [Claude Code](https://claude.com/claude-code) sessions,
plus an optional desktop panel. Shows what every session is doing, named by the chat
title you see in the Claude desktop app, with a live timer per session.

```
✳ ⠹ 2:14 +3          <- menu bar: longest-running session, plus 3 more

◌  2:14   Repository reorganization and CI/CD cleanup
!  0:31   Refactor the billing importer
○  8:52   Calendar notifications setup
```

## Install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).
No full Xcode, no Node, no dependencies.

```sh
git clone https://github.com/osyed-atrium/claude-status.git
cd claude-status
./install.sh
```

That builds `~/Applications/Claude Status.app`, registers a LaunchAgent so it starts
at login, and launches it. `./uninstall.sh` removes everything.

To build without installing the login item: `./build.sh [destination]`

## How it works

No hooks and no polling of Claude itself. Two files Claude Code already maintains:

| What | Where |
|---|---|
| Live session state | `~/.claude/sessions/*.json` — pid, status, `startedAt`, `statusUpdatedAt` |
| Chat titles | `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json` |

The two are joined on `cliSessionId`. Sessions whose pid is no longer alive are
dropped, so dead sessions never linger. Title files are ~400KB but the fields sit
near the top, so only the first 32KB is read, and only when the file's mtime changes.

If a chat has no title yet (the app names them after a turn or two), it falls back to
the first user message in the transcript, then to the working directory name.

## Clicking a session

A row opens that chat in the Claude desktop app. It registers the `claude://` scheme
and focuses a session for:

```
claude://code/continue?session=local_<uuid>
```

The id is the desktop app's own session id, not the CLI one — the handler requires
`/^local_[A-Za-z0-9-]{1,64}$/` and rejects anything else. It is the `sessionId` field
of the same `local_*.json` the titles come from, so the join is already in hand.

⌥-click opens the working folder in Finder instead. A session started with plain
`claude` in a terminal has no `local_*.json` and so no chat to open; those rows fall
back to the folder on an ordinary click.

## States

| Icon | Status | Meaning |
|---|---|---|
| `progress.indicator` | `busy` | working now |
| `exclamationmark.circle` (yellow) | `needs_input` / `waiting` | waiting on you |
| `exclamationmark.triangle` (orange) | `blocked` | blocked |
| `circle` (grey) | `idle` | idle |

Timers show time in the *current* state — how long this turn has been running, not
session uptime. Session uptime is in the row tooltip.

Caveat: `idle` and `busy` are confirmed against a live registry. The other three
states are read from strings in the Claude Code binary and are handled but unverified.

## Desktop panel

Menu bar icon -> **Show Desktop Panel** (⌘D). It sits at desktop level, so it is
visible on the desktop but never covers real windows. Drag to move; position is
remembered. Toggle state persists across restarts.

This is not a WidgetKit widget. Those need an app-extension target, an App Group
entitlement and code signing, i.e. full Xcode. This gets the same glanceable result
from a borderless panel that `swiftc` alone can build.

## Debugging

```sh
"$HOME/Applications/Claude Status.app/Contents/MacOS/ClaudeStatus" --dump
"$HOME/Applications/Claude Status.app/Contents/MacOS/ClaudeStatus" --render-panel /tmp/panel.png
```

`--dump` prints what the menu would show, each row followed by the URL that clicking
it opens. `--render-panel` writes the panel to a PNG without putting it on screen.

## Sharing / signing

The app is unsigned, so sharing a prebuilt `.app` means the recipient hits Gatekeeper.
Share the source and let `install.sh` compile locally — it takes a couple of seconds
and sidesteps signing entirely.

## Related

Prior art worth knowing about, since this is not the only one:
[claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) (hook-based, Homebrew),
[claude-status](https://github.com/burakCokyildirim/claude-status) (WidgetKit widgets).
