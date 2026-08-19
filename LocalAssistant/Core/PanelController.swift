import AppKit
import Carbon.HIToolbox
import SwiftUI

final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: AssistantPanel?
    private let inputSourceSession = KeyboardInputSourceSession()

    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            inputSourceSession.restore()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        inputSourceSession.beginInEnglish()
        panel.makeKeyAndOrderFront(nil)
    }

    func prepareForTermination() {
        inputSourceSession.restore()
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
        panel.isMovableByWindowBackground = true
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
        inputSourceSession.restore()
        window.orderOut(nil)
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

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Local Assistant 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView())
        return window
    }
}
