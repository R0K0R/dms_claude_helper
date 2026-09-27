import QtQuick
import Quickshell
import qs.Common
import qs.Widgets

/*
  A real toplevel window for replies (class/title "Claude Helper"), so the
  compositor can float, move and resize it and a long answer is shown in
  full -- unlike a notification toast, which folds it. The daemon opens it
  when a reply lands and hides it while a screenshot is taken.
*/
FloatingWindow {
    id: win

    property var daemon: null

    title: "Claude Helper"
    implicitWidth: 520
    implicitHeight: 640
    minimumSize: Qt.size(360, 320)
    color: Theme.surfaceContainer
    visible: false

    function show() {
        visible = true;
        if (daemon)
            daemon.markRead();
    }

    onClosed: visible = false

    Item {
        anchors.fill: parent
        anchors.margins: Theme.spacingM
        focus: true

        Keys.onEscapePressed: win.visible = false

        Item {
            id: header
            width: parent.width
            height: 40

            Column {
                anchors.left: parent.left
                anchors.right: actions.left
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: "Claude Helper"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: !win.daemon ? "" : win.daemon.capturing ? "Capturing screen…" : win.daemon.busy ? (win.daemon.statusText || "thinking…") : "Esc to close"
                }
            }

            Row {
                id: actions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankActionButton {
                    iconName: "restart_alt"
                    tooltipText: "New session (forget the conversation)"
                    onClicked: win.daemon && win.daemon.reset()
                }

                DankActionButton {
                    iconName: "close"
                    tooltipText: "Close"
                    onClicked: win.visible = false
                }
            }
        }

        ConversationView {
            anchors.top: header.bottom
            anchors.topMargin: Theme.spacingS
            anchors.bottom: parent.bottom
            width: parent.width
            daemon: win.daemon
            widget: win.daemon ? win.daemon.lastWidget : null
        }
    }
}
