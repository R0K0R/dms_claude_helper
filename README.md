# Claude Helper for DMS

A DankMaterialShell bar widget that screenshots your screen and hands it to a
background Claude Code session. Claude answers by calling back into the
plugin over `dms ipc`, and the answer opens in the bar popout, with LaTeX
rendered. You can keep several sessions and switch between them.

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
- The bar at the top of the popout shows the current session. Click it for
  the session list (switch, see which are busy or unread, delete); **+**
  starts a new one. Claude names each session after its topic on its first
  reply.
- The **model chip** in that bar shows the session's model. Click it to pick
  Fable, Opus, Sonnet or Haiku for this session, or Default (the `model`
  setting, else Claude Code's default). The conversation carries over; an
  idle session switches at once, and a busy one after its current turn.

The icon spins while Claude works and shows a dot when a reply is unread.
When a reply lands, the popout opens on it: on the bar you asked from, or
the one on the focused screen. The popout closes while a screenshot is
taken, so it isn't in the picture.

Each session is its own Claude Code conversation. Only the current
session keeps a Claude process running; the others are stopped once
they're idle, and pick up with `--resume` on their next ask, across DMS
restarts too.

## IPC

```
dms ipc call claudeHelper ask  'optional note'   # screenshot focused output + ask (bind this to a key)
dms ipc call claudeHelper say  'follow-up'       # ask without a screenshot
dms ipc call claudeHelper sessions               # key, * for current, title
dms ipc call claudeHelper newSession | select <key> | remove <key>
dms ipc call claudeHelper model opus             # current session: default|fable|opus|sonnet|haiku
dms ipc call claudeHelper show | hide            # the popout
dms ipc call claudeHelper last                   # current session's last reply
dms ipc call claudeHelper state
# used by Claude itself; <key> routes the call to its session:
dms ipc call claudeHelper replyFile <key> reply-<key>.md
dms ipc call claudeHelper reply  <key> 'text'
dms ipc call claudeHelper status <key> 'a few words'
dms ipc call claudeHelper title  <key> 'topic'
```

## How it works

- `ClaudeHelperDaemon.qml` runs once and owns everything stateful. Each
  session runs its own process:

  ```
  claude -p --input-format stream-json --output-format stream-json
  ```

  in `~/.cache/dms-claude-helper`. Each ask is one JSON line on its stdin.
  Sessions (key, Claude session id, title, messages) are kept in plugin
  state.
- Permissions depend on the `permissionMode` setting:
  - `restricted` (default): the tools are Read, Write and Bash; edits are
    auto-accepted only in the cache dir; the only allowed shell command is
    `Bash(dms ipc call claudeHelper:*)`. `--permission-prompts none` denies
    everything else instead of hanging on a prompt nobody can answer.
  - `bypass`: all default tools with `--permission-mode bypassPermissions`.
    Its input includes screenshots of arbitrary screen content, so text on
    screen could try to steer it. The prompt tells it to treat such text as
    content, and not to change files or the system unasked.

  MCP servers are off in both modes. Changing the mode, model or extra
  instructions restarts idle sessions on their next ask.
- `prompt/system.md` is appended to Claude Code's system prompt, with
  `{{KEY}}` replaced by the session's key and the tool rules filled in for
  the permission mode. It covers the IPC usage, the
  display constraints and the tutoring policy.
- `tools/render-math.py` turns `$…$`, `$$…$$`, `\(…\)` and `\[…\]` into PNGs
  (`latex` → `dvisvgm --exact-bbox` → `magick`), in the theme's text colour,
  cached by content hash.
  - Each PNG is rendered at 3× and placed as `<img width height>` at text
    size, so it stays sharp on scaled outputs. Qt's Markdown can't size
    images and would upscale them, so the reply goes through `cmark-gfm` to
    HTML and is shown as RichText.
  - Inline images are padded so their centre sits on TeX's math axis, then
    aligned to the middle of the text line.
  - Formulas that fail to compile, or that use file or macro commands, stay
    as source text.
  - Without `cmark-gfm` it falls back to Markdown images, which are blurry on
    a scaled output.
- `ConversationView.qml` is the popout's body: session bar, session list or
  conversation, and the ask row. `ClaudeHelperWidget.qml` is the bar icon
  that hosts it.

## Requirements

`claude` (logged in), `grim`, `python3`, `latex` with amsmath, mathtools and
bm, `dvisvgm`, ImageMagick with the rsvg delegate, and `cmark-gfm`. All of
them must be on the DMS service's PATH. `cmark-gfm` can instead be given as
an absolute path in the `cmarkCommand` setting.

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
  settings = {
    cmarkCommand = "${pkgs.cmark-gfm}/bin/cmark-gfm";
    model = "sonnet";   # optional; see the settings page for the rest
  };
};
```

Then add the widget in Settings → DankBar Layout.

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
