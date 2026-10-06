import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "claudeHelper"

    StyledText {
        width: parent.width
        text: "Claude Helper"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Click the bar icon for the conversation, right-click to capture & ask at once. A background Claude Code session reads the screenshot and answers over `dms ipc call claudeHelper …`; for math and science it points out mistakes and gives hints rather than answers. Model and instruction changes apply when a session's Claude process next starts (switching away and back, or a new session)."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StringSetting {
        settingKey: "model"
        label: "Model"
        description: "Passed to claude --model (e.g. sonnet, opus, haiku). Empty uses Claude Code's default."
        placeholder: "sonnet"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "captureScope"
        label: "Capture"
        description: "Which part of the desktop the screenshot covers."
        options: [
            {
                label: "The screen the bar is on (focused screen for IPC)",
                value: "screen"
            },
            {
                label: "All screens",
                value: "all"
            }
        ]
        defaultValue: "screen"
    }

    ToggleSetting {
        settingKey: "autoOpen"
        label: "Open popout on reply"
        description: "Open the bar popout on the answer as soon as it arrives. Off: just a dot on the bar icon."
        defaultValue: true
    }

    SliderSetting {
        settingKey: "captureDelay"
        label: "Capture delay"
        description: "Time for the popout to close before the screenshot is taken."
        defaultValue: 350
        minimum: 0
        maximum: 1500
        unit: "ms"
    }

    StringSetting {
        settingKey: "extraInstructions"
        label: "Extra instructions"
        description: "Appended to the built-in instructions, e.g. \"Always answer in Korean\" or \"I'm studying for the physics olympiad\"."
        placeholder: ""
        defaultValue: ""
    }

    StringSetting {
        settingKey: "claudeCommand"
        label: "Claude command"
        description: "Executable to run; must be on DMS's PATH or absolute."
        placeholder: "claude"
        defaultValue: ""
    }
}
