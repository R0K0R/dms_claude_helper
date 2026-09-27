import QtQuick
import Quickshell
import qs.Common
import qs.Widgets

/*
  The conversation plus the ask row, shared by the bar popout and the reply
  window. It holds nothing itself; `daemon` is ClaudeHelperDaemon.

  Height: the popout gives it a fixed logHeight and lets it size itself; the
  window anchors it to fill and the log takes whatever the ask row leaves.
*/
Item {
    id: view

    property var daemon: null
    property var widget: null // passed to the daemon as "who asked"
    property real logHeight: height - askRow.height - Theme.spacingS

    implicitHeight: logHeight + Theme.spacingS + askRow.height

    function focusNote() {
        note.forceActiveFocus();
    }

    DankFlickable {
        id: log
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
            }
        }

        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 36
            iconName: "send"
            tooltipText: "Send note only (no screenshot)"
            enabled: note.text.trim().length > 0
            onClicked: {
                if (view.daemon && view.daemon.askText(note.text, view.widget))
                    note.text = "";
            }
        }
    }
}
