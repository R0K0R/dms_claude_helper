import QtQuick
import Quickshell
import qs.Common
import qs.Widgets

/*
  The bar popout's body: a session header, then either the current
  session's conversation or the session list, then the ask row. It holds
  nothing itself; `daemon` is ClaudeHelperDaemon.
*/
Item {
    id: view

    property var daemon: null
    property var widget: null // passed to the daemon as "who asked"
    property real logHeight: 380
    property bool listing: false // the session list replaces the log

    implicitHeight: sessionBar.height + Theme.spacingS + logHeight + Theme.spacingS + askRow.height

    function focusNote() {
        note.forceActiveFocus();
    }

    function ago(t) {
        const m = Math.round((Date.now() - t) / 60000);
        if (m < 1)
            return "just now";
        if (m < 60)
            return m + " min ago";
        if (m < 60 * 24)
            return Math.round(m / 60) + " h ago";
        return Qt.formatDate(new Date(t), "MMM d");
    }

    // ---- session header: current title (opens the list) + new session ----

    Rectangle {
        id: sessionBar
        width: parent.width
        height: 36
        radius: Theme.cornerRadius
        color: barArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

        MouseArea {
            id: barArea
            anchors.fill: parent
            anchors.rightMargin: newButton.width + Theme.spacingS
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: view.listing = !view.listing
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: newButton.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: view.listing ? "expand_less" : "forum"
                size: Theme.iconSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.iconSizeSmall - Theme.spacingS - (otherUnread.visible ? otherUnread.width + Theme.spacingS : 0)
                elide: Text.ElideRight
                font.weight: Font.Medium
                color: Theme.surfaceText
                text: view.listing ? "Sessions" : (view.daemon && view.daemon.current ? view.daemon.current.title : "No session")
            }

            // Another session has an unread reply.
            Rectangle {
                id: otherUnread
                anchors.verticalCenter: parent.verticalCenter
                visible: !view.listing && !!view.daemon && view.daemon.sessions.some(s => s.unread && s.key !== view.daemon.currentKey)
                width: 7
                height: 7
                radius: 3.5
                color: Theme.error
            }
        }

        DankActionButton {
            id: newButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 32
            iconName: "add"
            tooltipText: "New session"
            onClicked: {
                if (view.daemon)
                    view.daemon.newSession();
                view.listing = false;
                view.focusNote();
            }
        }
    }

    // ---- session list -----------------------------------------------------

    DankFlickable {
        id: sessionList
        visible: view.listing
        anchors.top: sessionBar.bottom
        anchors.topMargin: Theme.spacingS
        width: parent.width
        height: Math.max(0, view.logHeight)
        clip: true
        contentWidth: width
        contentHeight: sessionColumn.implicitHeight

        Column {
            id: sessionColumn
            width: sessionList.width - Theme.spacingS
            spacing: Theme.spacingXS

            Repeater {
                model: view.daemon ? view.daemon._byRecent() : []

                delegate: Rectangle {
                    id: row

                    required property var modelData
                    readonly property bool isCurrent: !!view.daemon && modelData.key === view.daemon.currentKey
                    readonly property bool isBusy: !!view.daemon && !!(view.daemon.runtime[modelData.key] && view.daemon.runtime[modelData.key].busy)

                    width: sessionColumn.width
                    height: 52
                    radius: Theme.cornerRadius
                    color: isCurrent ? Theme.withAlpha(Theme.primary, 0.14) : rowArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            view.daemon.selectSession(row.modelData.key);
                            view.listing = false;
                        }
                    }

                    DankIcon {
                        id: rowIcon
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: row.isBusy ? "progress_activity" : row.modelData.unread ? "mark_chat_unread" : "chat_bubble"
                        size: Theme.iconSizeSmall
                        color: row.isBusy || row.modelData.unread ? Theme.primary : Theme.surfaceVariantText
                    }

                    Column {
                        anchors.left: rowIcon.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: deleteButton.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            font.weight: row.isCurrent ? Font.Bold : Font.Medium
                            color: Theme.surfaceText
                            text: row.modelData.title
                        }

                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            text: view.ago(row.modelData.updated) + " · " + row.modelData.messages.length + " messages"
                        }
                    }

                    DankActionButton {
                        id: deleteButton
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter
                        buttonSize: 32
                        iconName: "delete"
                        tooltipText: "Delete session"
                        onClicked: view.daemon.deleteSession(row.modelData.key)
                    }
                }
            }

            StyledText {
                visible: !view.daemon || view.daemon.sessions.length === 0
                width: parent.width
                topPadding: Theme.spacingL
                horizontalAlignment: Text.AlignHCenter
                color: Theme.surfaceVariantText
                text: "No sessions yet."
            }
        }
    }

    // ---- conversation -------------------------------------------------

    DankFlickable {
        id: log
        visible: !view.listing
        anchors.top: sessionBar.bottom
        anchors.topMargin: Theme.spacingS
        width: parent.width
        height: Math.max(0, view.logHeight)
        clip: true
        contentWidth: width
        contentHeight: logColumn.implicitHeight

        function toEnd() {
            contentY = Math.max(0, contentHeight - height);
        }
        onContentHeightChanged: Qt.callLater(toEnd)
        onHeightChanged: Qt.callLater(toEnd)
        Component.onCompleted: Qt.callLater(toEnd)

        Column {
            id: logColumn
            width: log.width - Theme.spacingS
            spacing: Theme.spacingS

            StyledText {
                visible: !view.daemon || view.daemon.messages.length === 0
                width: parent.width
                topPadding: Theme.spacingL
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Theme.surfaceVariantText
                text: "Put a problem on screen, add a note if you like (\"is step 3 right?\"), and press the camera. You'll get hints, not answers."
            }

            Repeater {
                model: view.daemon ? view.daemon.messages : []

                delegate: Rectangle {
                    id: bubble

                    required property var modelData
                    readonly property bool mine: modelData.role === "user"
                    readonly property bool isError: modelData.role === "error"

                    width: mine ? Math.min(parent.width * 0.85, Math.max(body.implicitWidth, thumb.visible ? thumb.width : 0) + Theme.spacingM * 2) : parent.width
                    x: mine ? parent.width - width : 0
                    height: inner.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: isError ? Theme.withAlpha(Theme.error, 0.15) : mine ? Theme.withAlpha(Theme.primary, 0.14) : Theme.surfaceContainerHigh

                    Column {
                        id: inner
                        x: Theme.spacingM
                        y: Theme.spacingM
                        width: bubble.width - Theme.spacingM * 2
                        spacing: Theme.spacingXS

                        Image {
                            id: thumb
                            visible: !!bubble.modelData.shot && status === Image.Ready
                            source: bubble.modelData.shot ? "file://" + bubble.modelData.shot : ""
                            sourceSize.height: 160
                            height: 72
                            // From the log's width, not the bubble's: a note-less bubble
                            // takes its width from this image, so that would be circular.
                            width: implicitWidth > 0 ? Math.min(logColumn.width * 0.85 - Theme.spacingM * 2, height * implicitWidth / implicitHeight) : 0
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Quickshell.execDetached(["xdg-open", bubble.modelData.shot])
                            }
                        }

                        TextEdit {
                            id: body
                            visible: text.length > 0
                            width: bubble.mine ? Math.min(implicitWidth, inner.width) : inner.width
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            textFormat: bubble.mine ? TextEdit.PlainText : bubble.modelData.renderedFormat === "html" ? TextEdit.RichText : TextEdit.MarkdownText
                            text: bubble.modelData.rendered || bubble.modelData.text || ""
                            color: bubble.isError ? Theme.error : Theme.surfaceText
                            selectionColor: Theme.withAlpha(Theme.primary, 0.35)
                            font.pixelSize: Theme.fontSizeMedium
                            font.family: Theme.fontFamily
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }

                        StyledText {
                            visible: !!bubble.modelData.fallback
                            text: "(sent as plain output — Claude skipped the IPC reply)"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }
        }
    }

    Row {
        id: askRow
        anchors.bottom: parent.bottom
        width: parent.width
        spacing: Theme.spacingS

        DankTextField {
            id: note
            width: parent.width - (36 + Theme.spacingS) * 2
            placeholderText: "Note (optional): \"I got x = 4, is it right?\""
            onAccepted: {
                if (view.daemon)
                    view.daemon.capture(text, view.widget ? view.widget.screenName : "", view.widget);
                text = "";
                view.listing = false;
            }
        }

        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 36
            iconName: "photo_camera"
            iconColor: Theme.primary
            tooltipText: "Capture screen & ask (Enter)"
            enabled: view.daemon && !view.daemon.capturing
            onClicked: {
                view.daemon.capture(note.text, view.widget ? view.widget.screenName : "", view.widget);
                note.text = "";
                view.listing = false;
            }
        }

        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 36
            iconName: "send"
            tooltipText: "Send note only (no screenshot)"
            enabled: note.text.trim().length > 0
            onClicked: {
                if (view.daemon && view.daemon.askText(note.text, view.widget)) {
                    note.text = "";
                    view.listing = false;
                }
            }
        }
    }
}
