import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: AssistantPanel?
    private let inputSourceSession = KeyboardInputSourceSession()
    private var isInteractionPinned = false
    private var isPerformingSystemInteraction = false

    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            inputSourceSession.restore()
            AppConsole.shared.info("快捷面板已通过快捷键隐藏", category: "Panel")
        } else {
            show()
        }
    }

    func show() {
        SelectionContextStore.shared.captureBeforePanelActivation()
        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        inputSourceSession.beginInEnglish()
        panel.makeKeyAndOrderFront(nil)
        AppConsole.shared.info("快捷面板已显示并聚焦输入框", category: "Panel")
    }

    func prepareForTermination() {
        inputSourceSession.restore()
    }

    func setInteractionPinned(_ pinned: Bool) {
        isInteractionPinned = pinned
        panel?.hidesOnDeactivate = !pinned
        AppConsole.shared.info(
            pinned ? "快捷面板已临时固定，可从 Finder 拖入文件" : "快捷面板已恢复失焦自动隐藏",
            category: "Panel"
        )
    }

    func hideForSystemInteraction() {
        isPerformingSystemInteraction = true
        panel?.orderOut(nil)
        AppConsole.shared.info("快捷面板为系统交互临时隐藏", category: "Panel")
    }

    func restoreAfterSystemInteraction() {
        guard isPerformingSystemInteraction else { return }
        isPerformingSystemInteraction = false
        show()
    }

    private func makePanel() -> AssistantPanel {
        let panel = AssistantPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 510),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.tabbingMode = .disallowed
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: AssistantPanelView())
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === panel else {
            return
        }
        guard !isInteractionPinned else { return }
        guard !isPerformingSystemInteraction else { return }
        inputSourceSession.restore()
        window.orderOut(nil)
        AppConsole.shared.info("快捷面板失去焦点并隐藏", category: "Panel")
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 72
        )
        panel.setFrameOrigin(origin)
    }
}

private final class KeyboardInputSourceSession {
    private var previousInputSource: TISInputSource?

    func beginInEnglish() {
        guard previousInputSource == nil,
              let currentInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return
        }

        previousInputSource = currentInputSource

        guard let englishInputSource = TISCopyInputSourceForLanguage("en" as CFString)?.takeRetainedValue() else {
            return
        }

        TISSelectInputSource(englishInputSource)
    }

    func restore() {
        guard let previousInputSource else { return }
        TISSelectInputSource(previousInputSource)
        self.previousInputSource = nil
    }
}

final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        DockIconController.shared.retain(for: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        AppConsole.shared.info("设置窗口已打开", category: "Settings")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Local Assistant 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 520)
        window.setFrameAutosaveName("LocalAssistant.SettingsWindow")
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView())
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DockIconController.shared.release(for: "settings")
        AppConsole.shared.info("设置窗口已关闭", category: "Settings")
    }
}
