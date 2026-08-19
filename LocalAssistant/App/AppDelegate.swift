import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        globalHotKey = GlobalHotKey()

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
        PanelController.shared.prepareForTermination()
    }
}
