import AppKit
import SwiftUI

@MainActor
final class ConsoleWindowController: NSObject, NSWindowDelegate {
    static let shared = ConsoleWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        AppConsole.shared.info("开发者 Console 已打开", category: "Console")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Assistant Console"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 420)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ConsoleView())
        return window
    }
}
