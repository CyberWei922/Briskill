import AppKit

@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private var visibleWindowIDs: Set<String> = []

    private init() {}

    func retain(for windowID: String) {
        visibleWindowIDs.insert(windowID)
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func release(for windowID: String) {
        visibleWindowIDs.remove(windowID)
        guard visibleWindowIDs.isEmpty else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        globalHotKey = GlobalHotKey()
        AppConsole.shared.info("应用启动完成，全局快捷键已注册", category: "Lifecycle")

        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.async {
                PanelController.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppConsole.shared.info("应用即将退出", category: "Lifecycle")
        PanelController.shared.prepareForTermination()
    }
}
