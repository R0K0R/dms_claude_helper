import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

/*
  The bar surface: one instance per bar per screen, holding no state of its
  own -- everything is read from the daemon (ClaudeHelperDaemon.qml).

  Left click opens the popout (sessions, conversation, an optional note,
  capture). Right click captures and asks straight away with no note. The
  pill spins while Claude works and shows a dot for an unread reply. A
  reply opens this same popout: the daemon picks the widget that asked, or
  the one on the focused output, among those on a bar that is shown.
*/
PluginComponent {
    id: root

    layerNamespacePlugin: "claude-helper"

    readonly property var daemon: PluginService.pluginDaemonInstances[pluginId] || null
    readonly property bool busy: daemon ? (daemon.busy || daemon.capturing) : false
    readonly property bool unread: daemon ? daemon.unread : false
    readonly property string screenName: parentScreen ? parentScreen.name : ""

    // Set by the popout content once it has been opened at least once.
    property var _popout: null
    readonly property bool popoutOpen: _popout ? _popout.shouldBeVisible : false

    onPopoutOpenChanged: {
        if (popoutOpen && daemon)
            daemon.markRead();
    }

    function captureAndAsk(note) {
        if (daemon)
            daemon.capture(note || "", screenName, root);
    }

    // Both bars (landscape and portrait) carry an instance; only one is shown.
    function isShown() {
        return visible && !!Window.window && Window.window.visible;
    }

    function openPopout() {
        if (!popoutOpen)
            triggerPopout();
    }

    // The daemon spawns a tick after the bar, so register when it appears.
    onDaemonChanged: {
        if (daemon)
            daemon.registerWidget(root);
    }
    Component.onCompleted: {
        if (daemon)
            daemon.registerWidget(root);
    }
    Component.onDestruction: {
        if (daemon)
            daemon.unregisterWidget(root);
    }

    Connections {
        target: root.daemon
        function onHidePopoutsRequested() {
            if (root.popoutOpen)
                root.closePopout();
        }
        function onReplyArrived(key) {
            if (root.popoutOpen && key === root.daemon.currentKey)
                root.daemon.markRead();
        }
    }

    pillRightClickAction: () => root.captureAndAsk("")

    component PillIcon: Item {
        implicitWidth: root.iconSize
        implicitHeight: root.iconSize

        DankIcon {
            id: glyph
            anchors.centerIn: parent
            name: root.busy ? "progress_activity" : "neurology"
            color: root.busy || root.unread ? Theme.primary : Theme.surfaceText
            size: root.iconSize

            RotationAnimation on rotation {
                running: root.busy
                from: 0
                to: 360
                duration: 1100
                loops: Animation.Infinite
                onStopped: glyph.rotation = 0
            }
        }

        Rectangle {
            visible: root.unread && !root.busy
            width: 7
            height: 7
            radius: 3.5
            color: Theme.error
            anchors.top: parent.top
            anchors.right: parent.right
        }
    }

    horizontalBarPill: Component {
        PillIcon {}
    }

    verticalBarPill: Component {
        PillIcon {}
    }

    popoutWidth: 460

    popoutContent: Component {
        PopoutComponent {
            id: pop

            headerText: "Claude Helper"
            detailsText: {
                const d = root.daemon;
                if (!d)
                    return "Daemon not running — enable the plugin.";
                if (d.capturing)
                    return "Capturing screen…";
                if (d.currentBusy)
                    return d.statusText || "thinking…";
                return "Right-click the bar icon to capture & ask instantly.";
            }
            showCloseButton: true

            onParentPopoutChanged: root._popout = parentPopout

            ConversationView {
                width: parent.width
                logHeight: 420
                daemon: root.daemon
                widget: root
            }
        }
    }
}
