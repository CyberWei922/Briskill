import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
    private var assistantHotKeyReference: EventHotKeyRef?
    private var clipboardHotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var assistantShortcutObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?

    init() {
        installHandler()
        registerShortcuts()
        assistantShortcutObserver = NotificationCenter.default.addObserver(
            forName: .assistantShortcutConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerAssistantShortcut()
            }
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .clipboardShortcutConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerClipboardShortcut()
            }
        }
    }

    deinit {
        if let assistantHotKeyReference { UnregisterEventHotKey(assistantHotKeyReference) }
        if let clipboardHotKeyReference { UnregisterEventHotKey(clipboardHotKeyReference) }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        if let assistantShortcutObserver {
            NotificationCenter.default.removeObserver(assistantShortcutObserver)
        }
        if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else { return status }

                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1:
                        PanelController.shared.toggle()
                    case 2:
                        ClipboardPanelController.shared.toggle()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerReference
        )
    }

    private func registerShortcuts() {
        registerAssistantShortcut()
        registerClipboardShortcut()
    }

    private func registerAssistantShortcut() {
        if let assistantHotKeyReference {
            UnregisterEventHotKey(assistantHotKeyReference)
            self.assistantHotKeyReference = nil
        }
        guard AssistantShortcut.isConfigured else {
            AppConsole.shared.info("主面板快捷键已清除", category: "HotKey")
            return
        }
        let shortcut = AssistantShortcut.load()
        let identifier = EventHotKeyID(signature: OSType(0x4C_41_53_53), id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &assistantHotKeyReference
        )
        if status == noErr {
            AppConsole.shared.info("主面板快捷键已注册：\(shortcut.displayName)", category: "HotKey")
        } else {
            AppConsole.shared.error("注册主面板快捷键失败：\(status)", category: "HotKey")
        }
    }

    private func registerClipboardShortcut() {
        if let clipboardHotKeyReference {
            UnregisterEventHotKey(clipboardHotKeyReference)
            self.clipboardHotKeyReference = nil
        }
        guard ClipboardHistoryStore.shared.isEnabled, ClipboardShortcut.isConfigured else { return }

        let shortcut = ClipboardShortcut.load()
        let identifier = EventHotKeyID(signature: OSType(0x42_53_4B_43), id: 2)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKeyReference
        )
        if status == noErr {
            AppConsole.shared.info("剪贴板快捷键已注册：\(shortcut.displayName)", category: "HotKey")
        } else {
            AppConsole.shared.error("注册剪贴板快捷键失败：\(status)", category: "HotKey")
        }
    }
}
