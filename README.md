# Claude Helper for DMS

A DankMaterialShell bar widget that screenshots your screen and hands it to a
background Claude Code session. Claude answers by calling back into the
plugin over `dms ipc`, and the answer opens in its own window, with LaTeX
rendered.

For math and science problems it acts as a tutor, not an answer key. It
points out the first mistake in your work, names what kind of mistake it is,
and gives hints that get more specific each time you come back. It does not
give the final answer.

## Use

- **Left-click** the icon to open the conversation. You can type an optional
  note ("I got x = 5, is that right?"), then press the camera button (or
  Enter) to capture and ask. The send button asks a follow-up without a
  screenshot.
- **Right-click** the icon to capture and ask straight away.
- **↻** in the popout starts a new session.

The icon spins while Claude works and shows a dot when a reply is unread.
When the reply lands, it opens in full in the **Claude Helper** window. This
is a real toplevel window (class `com.danklinux.dms`, title `Claude
Helper`), so the compositor can float, move and resize it. A notification
toast would fold a long answer. The window hides while a screenshot is
taken, so it isn't in the picture. Esc closes it; `dms ipc call claudeHelper
show` brings it back.

## IPC

```
dms ipc call claudeHelper ask  'optional note'   # screenshot focused output + ask (bind this to a key)
dms ipc call claudeHelper say  'follow-up'       # ask without a screenshot
dms ipc call claudeHelper reset                  # new session
dms ipc call claudeHelper show | hide            # the reply window
dms ipc call claudeHelper last                   # last reply as text
dms ipc call claudeHelper state
# used by Claude itself:
dms ipc call claudeHelper replyFile reply.md
dms ipc call claudeHelper reply  'text'
dms ipc call claudeHelper status 'a few words'
```

## How it works

- `ClaudeHelperDaemon.qml` runs once and owns everything stateful. It runs one
  long-lived process:

  ```
  claude -p --input-format stream-json --output-format stream-json
  ```

  in `~/.cache/dms-claude-helper`. Each ask is one JSON line on its stdin.
  The session id is kept in plugin state, so the conversation survives a DMS
  restart.
- The session's permissions are narrow. Its tools are Read, Write and Bash;
  the working directory is the cache dir; edits are auto-accepted only
  there; MCP servers are off. The only allowed shell command is
  `Bash(dms ipc call claudeHelper:*)`. `--permission-prompts none` denies
  everything else instead of hanging on a prompt nobody can answer.
- `prompt/system.md` is appended to Claude Code's system prompt. It covers
  the IPC usage, the display constraints and the tutoring policy.
- `tools/render-math.py` turns `$…$`, `$$…$$`, `\(…\)` and `\[…\]` into PNGs
  (`latex` → `dvisvgm --exact-bbox` → `magick`, at 1× and `@2x`), in the
  theme's text colour, cached by content hash. Qt's MarkdownText shows them
  as images. The alt text must not be empty, or Qt silently drops the image.
  Formulas that fail to compile, or that use file or macro commands, stay as
  source text.
- `ConversationView.qml` is the conversation plus the ask row, shared by the
  bar popout (`ClaudeHelperWidget.qml`) and the reply window
  (`ReplyWindow.qml`).

## Requirements

`claude` (logged in), `grim`, `python3`, `latex` with amsmath, mathtools and
bm, `dvisvgm`, and ImageMagick with the rsvg delegate. All of them must be
on the DMS service's PATH.

## Installation

Pin it as a flake input. It is plugin sources, not a flake, so use
`flake = false`:

```nix
inputs.claude-helper = {
  url = "github:R0K0R/dms_claude_helper";
  flake = false;
};
```

and point DMS at it:

```nix
programs.dank-material-shell.plugins.claudeHelper = {
  enable = true;
  src = inputs.claude-helper;
  settings.model = "sonnet";   # optional; see the settings page for the rest
};
```

Then add the widget in Settings → DankBar Layout. To make the reply window
float on Hyprland (Lua config), match its title:

```lua
hl.window_rule({ match = { title = "^(Claude Helper)$" }, float = true })
```

### Iterating on it

```
ln -sfn /path/to/checkout ~/.config/DankMaterialShell/plugins/claudeHelper
systemctl --user restart dms.service
```

A DMS restart is required after every QML edit. `dms ipc call plugins
reload` does not pick up changes, and it cannot see newly added QML files,
because QML caches compiled components and directory types by URL.
`tools/render-math.py` and `prompt/system.md` are re-read on use, and on the
next session respectively, so they need no restart.
