import SwiftUI

@main
struct LocalAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Local Assistant", systemImage: "sparkles") {
            Button("打开助手") {
                PanelController.shared.show()
            }
            .keyboardShortcut(" ", modifiers: .option)

            Divider()

            Button {
                SkillCreatorWindowController.shared.show()
            } label: {
                Label("创建自定义指令…", systemImage: "plus.square.dashed")
            }

            Divider()

            Button {
                SettingsWindowController.shared.show()
            } label: {
                Label("设置…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("退出 Local Assistant") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
