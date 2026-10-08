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
        description: "Default model for sessions (claude --model: fable, opus, sonnet, haiku). Empty uses Claude Code's default. Each session can pick its own with the model chip in the popout."
        placeholder: "sonnet"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "permissionMode"
        label: "Permissions"
        description: "Restricted: Claude can read the screenshot, write its reply and call the plugin, nothing else. Bypass: every tool and command runs without asking. Its input includes screenshots of whatever is on screen, so text there could try to steer it."
        options: [
            {
                label: "Restricted",
                value: "restricted"
            },
            {
                label: "Bypass permissions",
                value: "bypass"
            }
        ]
        defaultValue: "restricted"
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
