import AppKit
import SwiftUI

@MainActor
final class SkillCreatorWindowController: NSObject, NSWindowDelegate {
    static let shared = SkillCreatorWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        DockIconController.shared.retain(for: "skillCreator")
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        AppConsole.shared.info("技能创建窗口已打开", category: "SkillCreator")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "创建自定义指令"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 560)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SkillCreatorView())
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DockIconController.shared.release(for: "skillCreator")
        AppConsole.shared.info("技能创建窗口已关闭", category: "SkillCreator")
    }
}
