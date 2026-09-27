import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Common
import qs.Services
import qs.Modules.Plugins

/*
  The half of the plugin that exists exactly once. Bar widgets are
  instantiated per bar per screen, so everything stateful -- the IPC target,
  the Claude process, the conversation -- lives here, and every widget reads
  it through PluginService.pluginDaemonInstances.

  SESSION. One long-lived `claude -p --input-format stream-json` process.
  Each ask is one JSON line on its stdin; it answers on stdout as
  stream-json events. The process (and so the conversation, which is what
  makes the hint ladder work) stays up between asks, and its session id is
  kept in plugin state so a DMS restart resumes rather than forgets.

  REPLY PATH. Claude's own text output is not what the user sees. The
  system prompt (prompt/system.md) tells it to answer by running
  `dms ipc call claudeHelper replyFile reply.md`, which lands in reply()
  below. That is the only Bash command it is allowed: --permission-prompts
  none denies everything else instead of waiting on a prompt nobody can
  answer. If a turn ends without a reply call, the result text is shown
  instead, flagged as a fallback, so a forgetful turn is never silent.

  SANDBOX. cwd is the cache dir; acceptEdits confines Write to it, Read of
  the screenshot is inside it, and MCP servers are skipped.
*/
PluginComponent {
    id: root

    property var popoutService: null

    readonly property string claudeCommand: pluginData.claudeCommand || "claude"
    readonly property string model: pluginData.model || ""
    readonly property string captureScope: pluginData.captureScope || "screen"
    readonly property int captureDelay: pluginData.captureDelay ?? 350
    readonly property bool autoOpen: pluginData.autoOpen ?? true
    readonly property string extraInstructions: pluginData.extraInstructions || ""
    // Markdown -> HTML for replies with math (tools/render-math.py). Nix sets
    // an absolute path; without one the math falls back to blurry Markdown.
    readonly property string cmarkCommand: pluginData.cmarkCommand || "cmark-gfm"

    readonly property string workDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/dms-claude-helper"

    // {role: "user"|"claude"|"error", text, shot?, fallback?, time}
    property var messages: []
    property bool busy: false
    property bool capturing: false
    property bool unread: false
    property string statusText: ""
    property string sessionId: ""

    // Widgets connect to these; the one that started the ask opens itself.
    signal hidePopoutsRequested
    signal replyArrived
    property var lastWidget: null

    property bool _repliedThisTurn: false
    property bool _statusFromClaude: false // its own words beat our tool guesses
    property bool _sawInit: false
    property bool _resumeRetried: false
    property var _pendingLines: []    // written once the process has started
    property var _inFlightLines: []   // sent but not yet answered by a result
    property string _lastStderr: ""
    property string _pendingNote: ""
    property string _pendingShot: ""
    property string _pendingOutput: ""

    Component.onCompleted: {
        sessionId = pluginService ? pluginService.loadPluginState(pluginId, "sessionId", "") : "";
        messages = pluginService ? pluginService.loadPluginState(pluginId, "messages", []) : [];
    }

    Component.onDestruction: session.running = false

    // ---- conversation ---------------------------------------------------

    function _push(msg) {
        msg.time = Date.now();
        const next = messages.concat([msg]);
        messages = next.length > 50 ? next.slice(next.length - 50) : next;
        if (pluginService)
            pluginService.savePluginState(pluginId, "messages", messages);
    }

    function clearMessages() {
        messages = [];
        unread = false;
        if (pluginService)
            pluginService.savePluginState(pluginId, "messages", []);
    }

    function markRead() {
        unread = false;
    }

    function _showReply(text, fallback) {
        _repliedThisTurn = true;
        statusText = "";
        const msg = {
            role: "claude",
            text: text,
            fallback: !!fallback
        };
        _push(msg);
        if (/\$|\\\(|\\\[/.test(text))
            _renderMath(msg);
        _announce();
    }

    // A full window rather than a toast: toasts fold long answers.
    function _announce() {
        unread = true;
        replyArrived();
        if (autoOpen)
            replyWindow.show();
    }

    ReplyWindow {
        id: replyWindow
        daemon: root
    }

    function showWindow() {
        replyWindow.show();
    }

    // ---- LaTeX ------------------------------------------------------------
    // Shown raw at once, swapped for the rendered version (msg.rendered) when
    // tools/render-math.py finishes, typically well under a second.

    // `output` is render-math.py's: a format line ("html" | "md"), then the text.
    function _setRendered(time, output) {
        const nl = output.indexOf("\n");
        const format = output.slice(0, nl);
        messages = messages.map(m => m.time === time ? Object.assign({}, m, {
            rendered: output.slice(nl + 1),
            renderedFormat: format
        }) : m);
        if (pluginService)
            pluginService.savePluginState(pluginId, "messages", messages);
    }

    function _renderMath(msg) {
        const proc = mathProcComponent.createObject(root, {
            msgTime: msg.time
        });
        proc.command = ["python3", _pluginFile("tools/render-math.py"), "--out", workDir + "/math", "--color", Theme.surfaceText.toString(), "--px", String(Theme.fontSizeMedium), "--max-width", "420", "--cmark", cmarkCommand, msg.text];
        proc.running = true;
    }

    Component {
        id: mathProcComponent
        Process {
            property real msgTime: 0
            stdout: StdioCollector {
                id: mathOut
            }
            stderr: StdioCollector {
                id: mathErr
            }
            onExited: code => {
                if (code === 0 && mathOut.text.trim())
                    root._setRendered(msgTime, mathOut.text);
                else
                    console.warn("claudeHelper: math render failed:", mathErr.text);
                destroy();
            }
        }
    }

    function _showError(text) {
        statusText = "";
        _push({
            role: "error",
            text: text
        });
        _announce();
    }

    // ---- asking ---------------------------------------------------------

    // Screenshot `output` (a wl_output name; "" = all outputs), then ask.
    function capture(note, output, widget) {
        if (capturing)
            return false;
        lastWidget = widget || null;
        _pendingNote = note || "";
        _pendingOutput = captureScope === "all" ? "" : (output || Hyprland.focusedMonitor?.name || "");
        _pendingShot = workDir + "/shots/" + Date.now() + ".png";
        capturing = true;
        hidePopoutsRequested(); // keep our own popout and window out of the shot
        replyWindow.visible = false;
        captureTimer.interval = Math.max(0, captureDelay);
        captureTimer.restart();
        return true;
    }

    function askText(text, widget) {
        if (!text || !text.trim())
            return false;
        lastWidget = widget || lastWidget;
        _push({
            role: "user",
            text: text.trim()
        });
        _send("[note] " + text.trim());
        return true;
    }

    Timer {
        id: captureTimer
        repeat: false
        onTriggered: {
            // Keep the 20 newest shots; each is a few MB.
            grim.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && if [ -n "$2" ]; then grim -o "$2" "$1"; else grim "$1"; fi && '
                + 'ls -1t "$(dirname "$1")"/*.png | tail -n +21 | xargs -r rm -f --', "sh", root._pendingShot, root._pendingOutput];
            grim.running = true;
        }
    }

    Process {
        id: grim
        stderr: StdioCollector {
            id: grimErr
        }
        onExited: code => {
            root.capturing = false;
            if (code !== 0) {
                ToastService.showError("Claude Helper", "Screenshot failed: " + grimErr.text.trim());
                return;
            }
            const note = root._pendingNote.trim();
            root._push({
                role: "user",
                text: note,
                shot: root._pendingShot
            });
            root._send("[screenshot] " + root._pendingShot + (root._pendingOutput ? " (output " + root._pendingOutput + ")" : " (all outputs)") + "\n[note] " + (note || "(none)"));
        }
    }

    // ---- the Claude process ---------------------------------------------

    // Plugin reloads load this file as file://…?t=<now>; drop both parts.
    function _pluginFile(rel) {
        return decodeURIComponent(Qt.resolvedUrl(rel).toString().replace(/^file:\/\//, "").replace(/\?.*$/, ""));
    }

    FileView {
        id: promptFile
        path: root._pluginFile("prompt/system.md")
        blockLoading: true
    }

    function _command() {
        let prompt = promptFile.text();
        if (extraInstructions.trim())
            prompt += "\n\n## Additional instructions from the user's settings\n\n" + extraInstructions.trim() + "\n";
        const cmd = ["sh", "-c", 'mkdir -p "$0" && cd "$0" && exec "$@"', workDir, claudeCommand, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", "Read,Write,Bash", "--permission-mode", "acceptEdits", "--permission-prompts", "none", "--allowedTools", "Bash(dms ipc call claudeHelper:*)", "--strict-mcp-config", "--append-system-prompt", prompt];
        if (model)
            cmd.push("--model", model);
        if (sessionId)
            cmd.push("--resume", sessionId);
        return cmd;
    }

    function _send(text) {
        const line = JSON.stringify({
            type: "user",
            message: {
                role: "user",
                content: [
                    {
                        type: "text",
                        text: text
                    }
                ]
            }
        }) + "\n";
        busy = true;
        _repliedThisTurn = false;
        _statusFromClaude = false;
        statusText = "thinking…";
        _inFlightLines = _inFlightLines.concat([line]);
        if (session.running && session._started) {
            session.write(line);
        } else {
            _pendingLines = _pendingLines.concat([line]);
            _start();
        }
    }

    function _start() {
        if (session.running)
            return;
        _sawInit = false;
        _lastStderr = "";
        session.command = _command();
        session.running = true;
    }

    // New conversation: drop the process and forget the session id.
    function reset() {
        _pendingLines = [];
        _inFlightLines = [];
        session.running = false;
        busy = false;
        statusText = "";
        sessionId = "";
        _resumeRetried = false;
        if (pluginService)
            pluginService.savePluginState(pluginId, "sessionId", "");
        clearMessages();
    }

    function _describeTool(use) {
        const input = use.input || {};
        if (use.name === "Read")
            return (input.file_path || "").indexOf("/shots/") >= 0 ? "looking at the screen…" : "reading…";
        if (use.name === "Write")
            return "writing a reply…";
        return "";
    }

    function _handleEvent(line) {
        let ev;
        try {
            ev = JSON.parse(line);
        } catch (e) {
            return;
        }
        if (ev.type === "system" && ev.subtype === "init") {
            _sawInit = true;
            if (ev.session_id && ev.session_id !== sessionId) {
                sessionId = ev.session_id;
                if (pluginService)
                    pluginService.savePluginState(pluginId, "sessionId", sessionId);
            }
        } else if (ev.type === "assistant") {
            busy = true; // a queued message may have started a new turn
            const content = (ev.message && ev.message.content) || [];
            for (const c of content) {
                if (c.type === "tool_use") {
                    const d = _describeTool(c);
                    if (d && !_statusFromClaude)
                        statusText = d;
                }
            }
        } else if (ev.type === "result") {
            busy = false;
            _inFlightLines = _inFlightLines.slice(1);
            if (ev.is_error)
                _showError("Claude: " + (ev.result || ev.subtype || "error"));
            else if (!_repliedThisTurn && ev.result && ev.result.trim())
                _showReply(ev.result.trim(), true);
            _repliedThisTurn = false;
            _statusFromClaude = false;
            statusText = "";
        }
    }

    Process {
        id: session

        property bool _started: false

        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root._handleEvent(line)
        }
        stderr: SplitParser {
            onRead: line => {
                console.warn("claudeHelper[claude]:", line);
                root._lastStderr = line;
            }
        }
        onStarted: {
            _started = true;
            for (const l of root._pendingLines)
                write(l);
            root._pendingLines = [];
        }
        onExited: code => {
            _started = false;
            const unanswered = root._inFlightLines;
            // A stale --resume id makes claude exit before init: start fresh once.
            if (!root._sawInit && root.sessionId && !root._resumeRetried && unanswered.length) {
                root._resumeRetried = true;
                root.sessionId = "";
                if (root.pluginService)
                    root.pluginService.savePluginState(root.pluginId, "sessionId", "");
                root._pendingLines = unanswered;
                root._start();
                return;
            }
            root._inFlightLines = [];
            root._pendingLines = [];
            if (root.busy) {
                root.busy = false;
                root._showError("Claude session exited (" + code + ")" + (root._lastStderr ? ": " + root._lastStderr : ""));
            }
        }
    }

    // ---- IPC ------------------------------------------------------------

    function _resolve(path) {
        if (path.startsWith("~/"))
            return Quickshell.env("HOME") + path.slice(1);
        return path.startsWith("/") ? path : workDir + "/" + path;
    }

    // A fresh FileView per read: a reused one keeps serving its cached text
    // when the path is unchanged, and Claude overwrites the same reply.md.
    Component {
        id: fileReader
        FileView {
            blockLoading: true
            printErrors: false
        }
    }

    function _readFile(path) {
        const fv = fileReader.createObject(root, {
            path: path
        });
        const text = fv.text();
        fv.destroy();
        return text;
    }

    IpcHandler {
        target: "claudeHelper"

        // Called by Claude: show `text` (Markdown) as the answer.
        function reply(text: string): string {
            if (!text || !text.trim())
                return "error: empty reply";
            root._showReply(text.trim(), false);
            return "ok";
        }

        // Called by Claude: show a Markdown file as the answer; relative
        // paths resolve against the session's working directory.
        function replyFile(path: string): string {
            const p = root._resolve(path);
            const text = root._readFile(p);
            if (!text || !text.trim())
                return "error: " + p + " is missing or empty";
            root._showReply(text.trim(), false);
            return "ok";
        }

        // Called by Claude: a few words of progress in place of "thinking…".
        function status(text: string): string {
            root.statusText = text;
            root._statusFromClaude = true;
            return "ok";
        }

        function clear(): string {
            root.clearMessages();
            return "ok";
        }

        // For keybinds: screenshot the focused output and ask.
        function ask(note: string): string {
            return root.capture(note, "", null) ? "ok" : "busy capturing";
        }

        // Follow-up without a screenshot.
        function say(text: string): string {
            return root.askText(text, null) ? "ok" : "error: empty";
        }

        // New conversation.
        function reset(): string {
            root.reset();
            return "ok";
        }

        function show(): string {
            root.showWindow();
            return "ok";
        }

        function hide(): string {
            replyWindow.visible = false;
            return "ok";
        }

        function last(): string {
            for (let i = root.messages.length - 1; i >= 0; i--) {
                if (root.messages[i].role === "claude")
                    return root.messages[i].text;
            }
            return "";
        }

        function state(): string {
            return JSON.stringify({
                busy: root.busy,
                capturing: root.capturing,
                status: root.statusText,
                session: root.sessionId,
                running: session.running,
                messages: root.messages.length
            });
        }
    }
}
