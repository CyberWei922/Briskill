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

#if DEBUG
        if let keyword = debugSkillKeyword {
            Task { @MainActor in
                await runDebugSkill(keyword: keyword)
            }
            return
        }
#endif

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

#if DEBUG
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
            if let parameter = skill.resolvedParameters.first,
               let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--run-skill-debug"),
               ProcessInfo.processInfo.arguments.indices.contains(flagIndex + 2) {
                debugValues[parameter.id] = ProcessInfo.processInfo.arguments[flagIndex + 2]
            }
            let result = try await WorkflowEngine.shared.execute(
                skill: skill,
                input: keyword,
                values: debugValues,
                files: [:]
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
