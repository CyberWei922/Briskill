import AppKit
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var isRegistered = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    private init() {
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            isRegistered = true
            requiresApproval = false
        case .requiresApproval:
            isRegistered = true
            requiresApproval = true
        case .notRegistered, .notFound:
            isRegistered = false
            requiresApproval = false
        @unknown default:
            isRegistered = false
            requiresApproval = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            refresh()
            AppConsole.shared.info(
                enabled ? "已注册登录时自动启动" : "已取消登录时自动启动",
                category: "Lifecycle"
            )
        } catch {
            refresh()
            if requiresApproval {
                errorMessage = "已提交登录项，但需要在系统设置中允许。"
            } else {
                errorMessage = error.localizedDescription
            }
            AppConsole.shared.error(
                "修改登录项失败：\(error.localizedDescription)",
                category: "Lifecycle"
            )
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

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

enum AppOpenAction: String, CaseIterable, Identifiable {
    case assistant
    case skillCreator
    case settings

    static let statusItemDefaultsKey = "statusItem.primaryAction"
    static let dockIconDefaultsKey = "dockIcon.primaryAction"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assistant: String(localized: "打开主面板")
        case .skillCreator: String(localized: "新建技能")
        case .settings: String(localized: "打开设置")
        }
    }

    @MainActor
    func perform() {
        switch self {
        case .assistant:
            PanelController.shared.show()
        case .skillCreator:
            SkillCreatorWindowController.shared.show()
        case .settings:
            SettingsWindowController.shared.show()
        }
    }

    static func stored(forKey key: String) -> AppOpenAction {
        guard let rawValue = UserDefaults.standard.string(forKey: key),
              let action = AppOpenAction(rawValue: rawValue) else {
            return .assistant
        }
        return action
    }
}

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyVisibility() }
        }
        applyVisibility()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func applyVisibility() {
        let shouldShow = UserDefaults.standard.object(forKey: "showMenuBarIcon") == nil
            || UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        if shouldShow, statusItem == nil {
            makeStatusItem()
        } else if !shouldShow, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Briskill")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem?.popUpMenu(makeMenu())
            return
        }
        AppOpenAction.stored(forKey: AppOpenAction.statusItemDefaultsKey).perform()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("打开助手", action: #selector(openAssistant)))
        menu.addItem(.separator())
        menu.addItem(menuItem("创建自定义指令…", action: #selector(openSkillCreator)))
        menu.addItem(.separator())
        let settingsItem = menuItem("设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = nil
        settingsItem.onStateImage = nil
        settingsItem.offStateImage = nil
        settingsItem.mixedStateImage = nil
        if #available(macOS 27.0, *) {
            settingsItem.preferredImageVisibility = .hidden
        }
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(menuItem("开发者 Console…", action: #selector(openConsole)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 Briskill", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.keyEquivalentModifierMask = [.command]
        return menu
    }

    private func menuItem(
        _ title: String.LocalizationValue,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: title),
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        return item
    }

    @objc private func openAssistant() { PanelController.shared.show() }
    @objc private func openSkillCreator() { SkillCreatorWindowController.shared.show() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openConsole() { ConsoleWindowController.shared.show() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalHotKey: GlobalHotKey?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply(
            UserDefaults.standard.string(forKey: "preferredAppearance") ?? "system"
        )
        ClipboardHistoryStore.shared.startMonitoringIfEnabled()
        globalHotKey = GlobalHotKey()
        statusBarController = StatusBarController()
        AppConsole.shared.info("应用启动完成，全局快捷键已注册", category: "Lifecycle")

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--validate-skills-debug") {
            Task { @MainActor in
                validateStoredSkills()
            }
            return
        }
        if let keyword = debugSkillKeyword {
            Task { @MainActor in
                await runDebugSkill(keyword: keyword)
            }
            return
        }
#endif

        // The assistant panel contains the skill index and several SwiftUI
        // renderers. Prepare it on the first idle turn instead of charging all
        // of that work to the user's first shortcut press.
        DispatchQueue.main.async {
            PanelController.shared.prepare()
        }

        Task { @MainActor in
            await BriskillUpdateChecker.shared.checkAutomaticallyIfNeeded()
        }

        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.async {
                SettingsWindowController.shared.show()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.async {
                PanelController.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        DispatchQueue.main.async {
            AppOpenAction.stored(forKey: AppOpenAction.dockIconDefaultsKey).perform()
        }
        AppConsole.shared.info("用户点击 Dock 图标，正在执行已设置的打开操作", category: "Lifecycle")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppConsole.shared.info("应用即将退出", category: "Lifecycle")
        PanelController.shared.prepareForTermination()
    }

#if DEBUG
    @MainActor
    private func validateStoredSkills() {
        let skills = SkillStore.shared.skills
        var errorCount = 0
        var warningCount = 0
        for skill in skills {
            let issues = SkillWorkflowValidator.validate(
                skill.resolvedWorkflowV3,
                parameters: skill.resolvedParameters,
                executionMode: skill.resolvedExecutionMode,
                modelTask: skill.modelTask,
                appleScript: skill.appleScript
            )
            errorCount += issues.filter { $0.severity == .error }.count
            warningCount += issues.filter { $0.severity == .warning }.count
            for issue in issues where issue.severity == .error {
                writeDebugOutput("SKILL_V3_INVALID skill=\(skill.name) issue=\(issue.message)\n")
            }
        }
        writeDebugOutput(
            "SKILL_V3_VALIDATION skills=\(skills.count) errors=\(errorCount) warnings=\(warningCount)\n"
        )
        NSApplication.shared.terminate(nil)
    }

    private var debugSkillKeyword: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--run-skill-debug"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    @MainActor
    private func runDebugSkill(keyword: String) async {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let skill = SkillStore.shared.skills.first(where: { skill in
            ([skill.name, skill.registeredKeyword ?? ""] + skill.aliases)
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedKeyword }
        }) else {
            writeDebugOutput("WORKFLOW_DEBUG_FAILED skill_not_found=\(keyword)\n")
            NSApplication.shared.terminate(nil)
            return
        }

        do {
            var debugValues: [String: String] = [:]
            var debugFiles: [String: [URL]] = [:]
            if let parameter = skill.resolvedParameters.first,
               let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--run-skill-debug"),
               ProcessInfo.processInfo.arguments.indices.contains(flagIndex + 2) {
                let debugArgument = ProcessInfo.processInfo.arguments[flagIndex + 2]
                if parameter.type.acceptsFiles {
                    debugFiles[parameter.id] = [URL(fileURLWithPath: debugArgument)]
                } else {
                    debugValues[parameter.id] = debugArgument
                }
            }
            let result = try await WorkflowEngine.shared.execute(
                skill: skill,
                input: keyword,
                values: debugValues,
                files: debugFiles
            )
            let trimmedOutput = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputFormat = trimmedOutput.hasPrefix("{") || trimmedOutput.hasPrefix("[") || trimmedOutput.hasPrefix("```json")
                ? "json"
                : "markdown"
            writeDebugOutput(
                "WORKFLOW_DEBUG_OK skill=\(skill.name) tools=\(result.executedTools.joined(separator: ",")) clipboard_written=\(result.didWriteClipboard) output_format=\(outputFormat) output_length=\(result.outputText.count)\n"
            )
        } catch {
            writeDebugOutput("WORKFLOW_DEBUG_FAILED error=\(error.localizedDescription)\n")
        }
        NSApplication.shared.terminate(nil)
    }

    private func writeDebugOutput(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }
#endif
}
