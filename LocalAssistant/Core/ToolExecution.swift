import AppKit
import ApplicationServices
import Foundation
import PDFKit
import Vision

struct WorkflowExecutionResult {
    let outputText: String
    let executedTools: [String]
    let didWriteClipboard: Bool
    let artifacts: [URL]
}

struct WorkflowExecutionProgress: Equatable {
    let toolIdentifier: String
    let completedSteps: Int
    let totalSteps: Int
    let toolFraction: Double?

    var fractionCompleted: Double? {
        guard totalSteps > 0 else { return nil }
        if let toolFraction {
            let clamped = min(max(toolFraction, 0), 1)
            return min(max((Double(completedSteps) + clamped) / Double(totalSteps), 0), 1)
        }
        guard totalSteps > 1 || completedSteps > 0 else { return nil }
        return min(max(Double(completedSteps) / Double(totalSteps), 0), 1)
    }
}

enum WorkflowReadiness {
    case ready
    case unavailable([String])
}

enum ToolExecutionError: LocalizedError {
    case emptyClipboard
    case clipboardWriteFailed
    case missingArgument(tool: String, argument: String)
    case missingWorkflow
    case unavailableTools([String])
    case localSkillRequestedCloudModel
    case unsupportedFileInput
    case emptyToolResult(String)
    case accessibilityPermissionRequired
    case screenRecordingPermissionRequired
    case noSelectedText
    case invalidPath(String)
    case unsupportedFileType(String)
    case fileTooLarge(Int)
    case fileOperationFailed(String)
    case operationCancelled
    case screenCaptureCancelled
    case ocrFailed

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            "剪贴板中没有可处理的文字。请先复制一段文本后再运行技能。"
        case .clipboardWriteFailed:
            "翻译已经生成，但写入剪贴板失败。请重试或手动复制结果。"
        case .missingArgument(let tool, let argument):
            "工具 \(tool) 缺少参数 \(argument)。"
        case .missingWorkflow:
            "这个技能还没有可执行的工作流。"
        case .unavailableTools(let tools):
            "尚未接入这些本地工具：\(tools.joined(separator: "、"))"
        case .localSkillRequestedCloudModel:
            "本地执行技能不能调用云端模型。请在技能设置中将执行模式改为“云端 AI”。"
        case .unsupportedFileInput:
            "当前文本模型工具不会发送文件路径或文件内容；请先使用文件读取或 OCR 工具转换为文本。"
        case .emptyToolResult(let tool):
            "工具 \(tool) 没有返回可用结果。"
        case .accessibilityPermissionRequired:
            "需要“辅助功能”权限才能读取或替换其他应用中的选中文字。请在系统设置 → 隐私与安全性 → 辅助功能中允许 Local Assistant。"
        case .screenRecordingPermissionRequired:
            "需要“屏幕录制”权限才能进行区域截图。请在设置 → 隐私与权限中授权 Local Assistant；系统可能要求重新启动应用。"
        case .noSelectedText:
            "当前应用中没有可读取的选中文字，或者该应用不支持系统选区接口。"
        case .invalidPath(let path):
            "无法访问路径：\(path)"
        case .unsupportedFileType(let type):
            "暂不支持读取这种文件：\(type)"
        case .fileTooLarge(let limitMB):
            "文件过大。当前单个文件读取上限为 \(limitMB) MB。"
        case .fileOperationFailed(let reason):
            "文件操作失败：\(reason)"
        case .operationCancelled:
            "用户取消了操作。"
        case .screenCaptureCancelled:
            "没有完成区域截图。"
        case .ocrFailed:
            "没有从图片中识别到文字。"
        }
    }
}

@MainActor
private protocol ClipboardAccess {
    func readText() -> String?
    func writeText(_ text: String) -> Bool
}

@MainActor
private struct SystemClipboardAccess: ClipboardAccess {
    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func writeText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        return pasteboard.string(forType: .string) == text
    }
}

private struct ToolExecutionOutput {
    let value: SkillJSONValue
    let displayText: String?
    let artifacts: [URL]

    init(value: SkillJSONValue, displayText: String?, artifacts: [URL] = []) {
        self.value = value
        self.displayText = displayText
        self.artifacts = artifacts
    }
}

private struct ToolExecutionContext {
    let skill: UserSkill
    let userInput: String
    let variables: [String: SkillJSONValue]
    let files: [String: [URL]]
    let modelPromptTemplate: String?
    let reportProgress: ((Double?) -> Void)?
}

@MainActor
private protocol AssistantTool: AnyObject {
    var identifier: String { get }

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput
}

@MainActor
private final class ClipboardReadTextTool: AssistantTool {
    let identifier = "clipboard.readText"
    private let clipboard: ClipboardAccess

    init(clipboard: ClipboardAccess) {
        self.clipboard = clipboard
    }

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard let text = clipboard.readText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError.emptyClipboard
        }
        return ToolExecutionOutput(value: .string(text), displayText: nil)
    }
}

@MainActor
private final class ClipboardWriteTextTool: AssistantTool {
    let identifier = "clipboard.writeText"
    private let clipboard: ClipboardAccess

    init(clipboard: ClipboardAccess) {
        self.clipboard = clipboard
    }

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard let value = arguments["text"] ?? arguments["input"] else {
            throw ToolExecutionError.missingArgument(tool: identifier, argument: "text")
        }
        let text = value.stringValue
        guard !text.isEmpty else {
            throw ToolExecutionError.emptyToolResult(identifier)
        }
        guard clipboard.writeText(text) else {
            throw ToolExecutionError.clipboardWriteFailed
        }
        return ToolExecutionOutput(value: .string(text), displayText: text)
    }
}

private enum ToolPathResolver {
    static func url(
        from arguments: [String: SkillJSONValue],
        keys: [String],
        tool: String
    ) throws -> URL {
        guard let value = keys.compactMap({ arguments[$0]?.stringValue }).first,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError.missingArgument(tool: tool, argument: keys.first ?? "path")
        }
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func existingURL(
        from arguments: [String: SkillJSONValue],
        keys: [String],
        tool: String
    ) throws -> URL {
        let url = try url(from: arguments, keys: keys, tool: tool)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolExecutionError.invalidPath(url.path)
        }
        return url
    }

    static func validateMutableUserItem(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(home.path + "/"),
              resolved.path != home.path else {
            throw ToolExecutionError.fileOperationFailed("只能修改当前用户主目录内的具体文件或文件夹")
        }
        let protected = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library"]
            .map { home.appendingPathComponent($0).standardizedFileURL.path }
        guard !protected.contains(resolved.path) else {
            throw ToolExecutionError.fileOperationFailed("不能直接修改系统常用目录本身")
        }
        return resolved
    }
}

private enum AccessibilityBridge {
    static func selectedText(promptForPermission: Bool = true) throws -> String {
        try selectionContext(promptForPermission: promptForPermission).text
    }

    static func selectionContext(promptForPermission: Bool = true) throws -> (element: AXUIElement, text: String) {
        let element = try focusedElement(promptForPermission: promptForPermission)
        var selectedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard status == .success,
              let text = selectedValue as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError.noSelectedText
        }
        return (element, text)
    }

    static func replaceSelectedText(with text: String, in capturedElement: AXUIElement? = nil) throws {
        let element: AXUIElement
        if let capturedElement {
            element = capturedElement
        } else {
            element = try focusedElement(promptForPermission: true)
        }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard status == .success else {
            throw ToolExecutionError.fileOperationFailed("当前应用不允许替换选中文字（AX 错误 \(status.rawValue)）")
        }
    }

    private static func focusedElement(promptForPermission: Bool) throws -> AXUIElement {
        if !AXIsProcessTrusted() {
            if promptForPermission {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            throw ToolExecutionError.accessibilityPermissionRequired
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard status == .success, let focusedValue else {
            throw ToolExecutionError.noSelectedText
        }
        return focusedValue as! AXUIElement
    }
}

@MainActor
final class SelectionContextStore {
    static let shared = SelectionContextStore()

    private var capturedText: String?
    private var capturedElement: AXUIElement?
    private var capturedAt: Date?

    func captureBeforePanelActivation() {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        if let context = try? AccessibilityBridge.selectionContext(promptForPermission: false) {
            capturedText = context.text
            capturedElement = context.element
            capturedAt = Date()
            AppConsole.shared.info("已暂存调用前的选中文字；字符数=\(context.text.count)", category: "Selection")
        }
    }

    func recentText() -> String? {
        guard let capturedText, let capturedAt,
              Date().timeIntervalSince(capturedAt) < 60 else {
            return nil
        }
        return capturedText
    }

    func replaceRecentText(with text: String) throws -> Bool {
        guard let capturedElement, let capturedAt,
              Date().timeIntervalSince(capturedAt) < 60 else {
            return false
        }
        try AccessibilityBridge.replaceSelectedText(with: text, in: capturedElement)
        capturedText = text
        self.capturedAt = Date()
        return true
    }
}

@MainActor
private enum NativeConfirmation {
    static func approve(title: String, message: String, confirmTitle: String) -> Bool {
        PanelController.shared.setInteractionPinned(true)
        defer { PanelController.shared.setInteractionPinned(false) }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
private final class SelectionReadTextTool: AssistantTool {
    let identifier = "selection.readText"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let text: String
        if let captured = SelectionContextStore.shared.recentText() {
            text = captured
        } else {
            text = try AccessibilityBridge.selectedText()
        }
        return ToolExecutionOutput(value: .string(text), displayText: text)
    }
}

@MainActor
private final class SelectionReplaceTextTool: AssistantTool {
    let identifier = "selection.replaceText"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard let text = (arguments["text"] ?? arguments["input"])?.stringValue,
              !text.isEmpty else {
            throw ToolExecutionError.missingArgument(tool: identifier, argument: "text")
        }
        let preview = String(text.prefix(500))
        guard NativeConfirmation.approve(
            title: "替换当前选中文字？",
            message: preview + (text.count > 500 ? "\n\n…其余内容已省略" : ""),
            confirmTitle: "替换"
        ) else {
            throw ToolExecutionError.operationCancelled
        }
        if try !SelectionContextStore.shared.replaceRecentText(with: text) {
            try AccessibilityBridge.replaceSelectedText(with: text)
        }
        return ToolExecutionOutput(value: .string(text), displayText: text)
    }
}

@MainActor
private final class ImageOCRTool: AssistantTool {
    let identifier = "image.ocr"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let url = try ToolPathResolver.existingURL(
            from: arguments,
            keys: ["path", "image", "input"],
            tool: identifier
        )
        let text = try await recognizeText(at: url, reportProgress: context.reportProgress)
        guard !text.isEmpty else { throw ToolExecutionError.ocrFailed }
        return ToolExecutionOutput(value: .string(text), displayText: text)
    }

    private func recognizeText(
        at url: URL,
        reportProgress: ((Double?) -> Void)?
    ) async throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ToolExecutionError.unsupportedFileType(url.pathExtension.isEmpty ? url.lastPathComponent : url.pathExtension)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                request.progressHandler = { _, fractionCompleted, _ in
                    reportProgress?(fractionCompleted)
                }
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    let lines = (request.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
private final class ScreenCaptureRegionTool: AssistantTool {
    let identifier = "screen.captureRegion"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard CGPreflightScreenCaptureAccess() else {
            PrivacyPermissionCenter.shared.requestScreenRecording()
            throw ToolExecutionError.screenRecordingPermissionRequired
        }
        let capturesDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("LocalAssistant/Captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: capturesDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = capturesDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).png")

        PanelController.shared.hideForSystemInteraction()
        try? await Task.sleep(for: .milliseconds(180))
        defer { PanelController.shared.restoreAfterSystemInteraction() }

        let status = try await ProcessRunner.run(
            executable: "/usr/sbin/screencapture",
            arguments: ["-i", "-s", "-x", outputURL.path]
        ).status
        guard status == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ToolExecutionError.screenCaptureCancelled
        }
        return ToolExecutionOutput(value: .string(outputURL.path), displayText: nil)
    }
}

private enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(executable: String, arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                do {
                    try process.run()
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        stdout: String(data: outputData, encoding: .utf8) ?? "",
                        stderr: String(data: errorData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
private final class FileReadTextTool: AssistantTool {
    let identifier = "file.readText"
    private let sizeLimit = 20 * 1_024 * 1_024

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let url = try ToolPathResolver.existingURL(
            from: arguments,
            keys: ["path", "file", "input"],
            tool: identifier
        )
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ToolExecutionError.invalidPath(url.path)
        }
        guard (values.fileSize ?? 0) <= sizeLimit else {
            throw ToolExecutionError.fileTooLarge(20)
        }

        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url),
                  let content = document.string,
                  !content.isEmpty else {
                throw ToolExecutionError.unsupportedFileType("PDF（可能是扫描件，请改用 OCR）")
            }
            text = content
        case "rtf", "rtfd":
            text = try NSAttributedString(
                url: url,
                options: [:],
                documentAttributes: nil
            ).string
        case "txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml",
             "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "js", "ts", "tsx", "jsx",
             "html", "css", "sql", "sh", "zsh", "log", "ini", "toml", "plist", "":
            var encoding = String.Encoding.utf8
            text = try String(contentsOf: url, usedEncoding: &encoding)
        default:
            throw ToolExecutionError.unsupportedFileType(url.pathExtension)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError.emptyToolResult(identifier)
        }
        return ToolExecutionOutput(value: .string(text), displayText: text)
    }
}

@MainActor
private final class FileListTool: AssistantTool {
    let identifier = "file.list"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let directory: URL
        if arguments["directory"] != nil || arguments["path"] != nil {
            directory = try ToolPathResolver.existingURL(
                from: arguments,
                keys: ["directory", "path"],
                tool: identifier
            )
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
        }
        let limit = max(1, min(arguments["limit"]?.integerValue ?? 50, 200))
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
        let paths = urls.map(\.path)
        let markdown = paths.isEmpty
            ? "该目录为空。"
            : paths.map { "- `\($0.replacingOccurrences(of: "`", with: "\\`"))`" }.joined(separator: "\n")
        return ToolExecutionOutput(
            value: .array(paths.map(SkillJSONValue.string)),
            displayText: markdown
        )
    }
}

@MainActor
private final class FileSearchTool: AssistantTool {
    let identifier = "file.search"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard let query = (arguments["query"] ?? arguments["name"] ?? arguments["input"])?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw ToolExecutionError.missingArgument(tool: identifier, argument: "query")
        }
        let limit = max(1, min(arguments["limit"]?.integerValue ?? 30, 100))
        var authorizedAccess: [ResolvedAuthorizedLocation] = []
        defer { authorizedAccess.forEach { $0.stopAccessing() } }
        let roots: [URL]
        if arguments["directory"] != nil || arguments["root"] != nil {
            roots = [try ToolPathResolver.existingURL(
                from: arguments,
                keys: ["directory", "root"],
                tool: identifier
            )]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let standardRoots = ["Desktop", "Documents", "Downloads"]
                .map { home.appendingPathComponent($0, isDirectory: true) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            authorizedAccess = AuthorizedLocationStore.shared.beginAccessingLocations()
            let allRoots = standardRoots + authorizedAccess.map(\.url)
            roots = allRoots.reduce(into: [URL]()) { result, url in
                if !result.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                    result.append(url)
                }
            }
        }

        let matches = try await search(query: query, roots: roots, limit: limit)
        let markdown: String
        if matches.isEmpty {
            markdown = "没有找到名称包含“\(query)”的文件。"
        } else {
            markdown = "找到 \(matches.count) 个名称包含“\(query)”的项目。"
        }
        return ToolExecutionOutput(
            value: .array(matches.map { .string($0.path) }),
            displayText: markdown,
            artifacts: matches
        )
    }

    private func search(query: String, roots: [URL], limit: Int) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let manager = FileManager.default
                var matches: [URL] = []
                var inspected = 0
                let normalizedQuery = query.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )

                rootLoop: for root in roots {
                    guard let enumerator = manager.enumerator(
                        at: root,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { _, _ in true }
                    ) else { continue }

                    for case let url as URL in enumerator {
                        inspected += 1
                        if inspected > 25_000 { break rootLoop }
                        let name = url.lastPathComponent.folding(
                            options: [.caseInsensitive, .diacriticInsensitive],
                            locale: .current
                        )
                        if name.localizedStandardContains(normalizedQuery) {
                            matches.append(url)
                            if matches.count >= limit { break rootLoop }
                        }
                    }
                }
                continuation.resume(returning: matches)
            }
        }
    }
}

@MainActor
private final class FileRenameTool: AssistantTool {
    let identifier = "file.rename"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let source = try ToolPathResolver.validateMutableUserItem(
            ToolPathResolver.existingURL(from: arguments, keys: ["path", "source"], tool: identifier)
        )
        guard let newName = arguments["newName"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !newName.isEmpty,
              !newName.contains("/") else {
            throw ToolExecutionError.missingArgument(tool: identifier, argument: "newName")
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolExecutionError.fileOperationFailed("目标名称已经存在")
        }
        guard NativeConfirmation.approve(
            title: "重命名文件？",
            message: "\(source.lastPathComponent)\n→\n\(newName)",
            confirmTitle: "重命名"
        ) else { throw ToolExecutionError.operationCancelled }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw ToolExecutionError.fileOperationFailed(error.localizedDescription)
        }
        return ToolExecutionOutput(value: .string(destination.path), displayText: "已重命名为 `\(newName)`")
    }
}

@MainActor
private final class FileCreateEmptyTool: AssistantTool {
    let identifier = "file.createEmpty"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard let filename = (arguments["name"] ?? arguments["filename"] ?? arguments["input"])?
            .stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty else {
            throw ToolExecutionError.missingArgument(tool: identifier, argument: "name")
        }
        guard filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\0"),
              URL(fileURLWithPath: filename).lastPathComponent == filename else {
            throw ToolExecutionError.fileOperationFailed("文件名不能包含路径或斜杠")
        }
        guard !URL(fileURLWithPath: filename).pathExtension.isEmpty else {
            throw ToolExecutionError.fileOperationFailed("文件名必须包含后缀，例如 1.txt")
        }

        let fileManager = FileManager.default
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let outputURL = downloads.appendingPathComponent(filename, isDirectory: false)
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw ToolExecutionError.fileOperationFailed("下载目录中已经存在“\(filename)”")
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: Data()) else {
            throw ToolExecutionError.fileOperationFailed("无法在下载目录创建文件")
        }

        return ToolExecutionOutput(
            value: .string(outputURL.path),
            displayText: "已在下载目录创建空文件。",
            artifacts: [outputURL]
        )
    }
}

@MainActor
private final class FileTrashTool: AssistantTool {
    let identifier = "file.trash"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let source = try ToolPathResolver.validateMutableUserItem(
            ToolPathResolver.existingURL(from: arguments, keys: ["path", "source"], tool: identifier)
        )
        guard NativeConfirmation.approve(
            title: "移到废纸篓？",
            message: source.path,
            confirmTitle: "移到废纸篓"
        ) else { throw ToolExecutionError.operationCancelled }
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
        } catch {
            throw ToolExecutionError.fileOperationFailed(error.localizedDescription)
        }
        let result = (resultingURL as URL?)?.path ?? source.path
        return ToolExecutionOutput(value: .string(result), displayText: "已将 `\(source.lastPathComponent)` 移到废纸篓。")
    }
}

@MainActor
private final class SystemSnapshotTool: AssistantTool {
    let identifier = "system.snapshot"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let processInfo = ProcessInfo.processInfo
        let home = FileManager.default.homeDirectoryForCurrentUser
        let disk = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let physicalMemory = formatter.string(fromByteCount: Int64(processInfo.physicalMemory))
        let totalDisk = formatter.string(fromByteCount: Int64(disk?.volumeTotalCapacity ?? 0))
        let availableDisk = formatter.string(fromByteCount: disk?.volumeAvailableCapacityForImportantUsage ?? 0)
        let topProcesses = await topProcessSummary()
        let thermal: String
        switch processInfo.thermalState {
        case .nominal: thermal = "正常"
        case .fair: thermal = "轻度升温"
        case .serious: thermal = "较高"
        case .critical: thermal = "严重"
        @unknown default: thermal = "未知"
        }
        let uptimeHours = Int(processInfo.systemUptime / 3_600)
        let markdown = """
        ## 系统快照

        - **处理器核心**：\(processInfo.processorCount)
        - **物理内存**：\(physicalMemory)
        - **磁盘空间**：可用 \(availableDisk) / 总计 \(totalDisk)
        - **温度状态**：\(thermal)
        - **连续运行**：约 \(uptimeHours) 小时

        ## 当前资源占用靠前的进程

        \(topProcesses)
        """
        return ToolExecutionOutput(value: .string(markdown), displayText: markdown)
    }

    private func topProcessSummary() async -> String {
        guard let result = try? await ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-Ao", "pid=,pcpu=,pmem=,comm=", "-r"]
        ), result.status == 0 else {
            return "暂时无法读取进程列表。"
        }
        let lines = result.stdout
            .split(separator: "\n")
            .prefix(8)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty
            ? "没有进程数据。"
            : lines.map { "- `\($0)`" }.joined(separator: "\n")
    }
}

@MainActor
private final class ModelGenerateTextTool: AssistantTool {
    let identifier = "model.generateText"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        let explicitInput = (arguments["input"] ?? arguments["prompt"])?.stringValue ?? ""
        var prompt = context.modelPromptTemplate
            ?? arguments["prompt"]?.stringValue
            ?? context.skill.originalRequest

        prompt = Self.interpolate(prompt, variables: context.variables)
        if !explicitInput.isEmpty,
           !prompt.contains(explicitInput),
           !context.modelPromptTemplateContainsRuntimeValue {
            prompt += "\n\n待处理内容：\n\(explicitInput)"
        }

        let explicitlyRequestsJSON = Self.explicitlyRequestsJSON(
            prompt: prompt,
            outputRequirement: context.skill.output
        )
        let system = """
        你正在执行用户保存的个人技能“\(context.skill.name)”。
        严格完成提示词中的任务，只返回可以直接交付给用户或下一工具的最终内容。
        不要声称访问了没有由前序工具真实提供的数据，不要添加“以下是结果”等无关前言。
        输出要求：\(context.skill.output)
        \(explicitlyRequestsJSON
            ? "用户明确要求 JSON，请只输出合法 JSON。"
            : "结果会直接展示给普通用户。请使用清晰、自然的 Markdown；不要输出 JSON、XML，也不要用代码块包装普通文字、词典、列表或文章。")
        """
        let result = try await AIService.shared.generateText(
            prompt: prompt,
            system: system
        )
        guard !result.isEmpty else {
            throw ToolExecutionError.emptyToolResult(identifier)
        }
        let readableResult = explicitlyRequestsJSON
            ? result
            : ModelOutputFormatter.readableMarkdown(from: result)
        return ToolExecutionOutput(value: .string(readableResult), displayText: readableResult)
    }

    private static func interpolate(
        _ template: String,
        variables: [String: SkillJSONValue]
    ) -> String {
        variables.reduce(template) { partial, item in
            partial.replacingOccurrences(of: "{{\(item.key)}}", with: item.value.stringValue)
        }
    }

    private static func explicitlyRequestsJSON(
        prompt: String,
        outputRequirement: String
    ) -> Bool {
        (prompt + "\n" + outputRequirement)
            .localizedCaseInsensitiveContains("json")
    }
}

@MainActor
private enum ModelOutputFormatter {
    static func readableMarkdown(from text: String) -> String {
        guard let jsonText = fencedJSONBody(from: text),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return text
        }

        let markdown = render(object, level: 1, isRoot: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return text }
        AppConsole.shared.info(
            "模型返回了纯 JSON 代码块，已自动转换为面向用户的 Markdown；原始字符数=\(text.count)",
            category: "Workflow"
        )
        return markdown
    }

    private static func fencedJSONBody(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return trimmed
        }
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return nil }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return nil }
        let opening = lines.removeFirst().lowercased()
        guard opening == "```json" || opening == "```" else { return nil }
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ value: Any, level: Int, isRoot: Bool = false) -> String {
        if let dictionary = value as? [String: Any] {
            if isRoot, dictionary.count == 1, let entry = dictionary.first {
                return "# \(entry.key)\n\n" + render(entry.value, level: 2)
            }
            return dictionary.map { key, child in
                if isScalar(child) {
                    return "- **\(key)**：\(scalarText(child))"
                }
                let heading = String(repeating: "#", count: min(level, 6))
                return "\(heading) \(key)\n\n\(render(child, level: level + 1))"
            }
            .joined(separator: "\n\n")
        }

        if let array = value as? [Any] {
            return array.map { child in
                if isScalar(child) {
                    return "- \(scalarText(child))"
                }
                return "- \(render(child, level: level + 1).replacingOccurrences(of: "\n", with: "\n  "))"
            }
            .joined(separator: "\n")
        }

        return scalarText(value)
    }

    private static func isScalar(_ value: Any) -> Bool {
        !(value is [String: Any]) && !(value is [Any])
    }

    private static func scalarText(_ value: Any) -> String {
        if value is NSNull { return "无" }
        if let boolean = value as? Bool { return boolean ? "是" : "否" }
        return String(describing: value)
    }
}

private extension ToolExecutionContext {
    var modelPromptTemplateContainsRuntimeValue: Bool {
        guard let modelPromptTemplate else { return false }
        return variables.keys.contains { modelPromptTemplate.contains("{{\($0)}}") }
    }
}

@MainActor
final class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: any AssistantTool] = [:]

    private init() {
        let clipboard = SystemClipboardAccess()
        register(ClipboardReadTextTool(clipboard: clipboard))
        register(ClipboardWriteTextTool(clipboard: clipboard))
        register(SelectionReadTextTool())
        register(SelectionReplaceTextTool())
        register(ScreenCaptureRegionTool())
        register(ImageOCRTool())
        register(FileReadTextTool())
        register(FileListTool())
        register(FileSearchTool())
        register(FileRenameTool())
        register(FileCreateEmptyTool())
        register(FileTrashTool())
        register(SystemSnapshotTool())
        register(ModelGenerateTextTool())
    }

    func canonicalIdentifier(for rawIdentifier: String) -> String {
        let normalized = rawIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")

        switch normalized {
        case "clipboard", "clipboard.read", "clipboard.readtext":
            return "clipboard.readText"
        case "clipboard.write", "clipboard.writetext":
            return "clipboard.writeText"
        case "selection", "selection.read", "selection.readtext", "selectedtext.read":
            return "selection.readText"
        case "selection.replace", "selection.replacetext", "selectedtext.replace":
            return "selection.replaceText"
        case "screen.capture", "screen.captureregion", "screenshot.capture":
            return "screen.captureRegion"
        case "ocr", "ocr.recognize", "image.ocr", "vision.ocr":
            return "image.ocr"
        case "file.read", "file.readtext", "files.read", "files.readtext":
            return "file.readText"
        case "file.list", "files.list":
            return "file.list"
        case "file.search", "files.search":
            return "file.search"
        case "file.rename", "files.rename":
            return "file.rename"
        case "file.create", "file.createempty", "files.create", "files.createempty":
            return "file.createEmpty"
        case "file.trash", "files.trash", "file.delete", "files.delete":
            return "file.trash"
        case "system.snapshot", "system.metricssnapshot", "system.metrics", "process.topconsumers":
            return "system.snapshot"
        case "model", "model.generatetext", "text.generation", "translate", "summarize", "rewrite":
            return "model.generateText"
        default:
            return rawIdentifier
        }
    }

    fileprivate func tool(for rawIdentifier: String) -> (any AssistantTool)? {
        tools[canonicalIdentifier(for: rawIdentifier)]
    }

    func contains(_ rawIdentifier: String) -> Bool {
        tool(for: rawIdentifier) != nil
    }

    private func register(_ tool: any AssistantTool) {
        tools[tool.identifier] = tool
    }
}

private struct ExecutableWorkflow {
    let steps: [SkillWorkflowStep]
    let modelPromptTemplate: String?
}

@MainActor
final class WorkflowEngine {
    static let shared = WorkflowEngine(registry: ToolRegistry.shared)

    private let registry: ToolRegistry

    private init(registry: ToolRegistry) {
        self.registry = registry
    }

    func readiness(for skill: UserSkill) -> WorkflowReadiness {
        guard let workflow = executableWorkflow(for: skill), !workflow.steps.isEmpty else {
            return .unavailable(["workflow"])
        }

        var unavailable = Set<String>()
        for step in workflow.steps where !registry.contains(step.tool) {
            unavailable.insert(step.tool)
        }
        for requiredTool in skill.requiredTools where !registry.contains(requiredTool) {
            unavailable.insert(requiredTool)
        }

        return unavailable.isEmpty
            ? .ready
            : .unavailable(unavailable.sorted())
    }

    func execute(
        skill: UserSkill,
        input: String,
        values: [String: String],
        files: [String: [URL]],
        progress: ((WorkflowExecutionProgress) -> Void)? = nil
    ) async throws -> WorkflowExecutionResult {
        guard let workflow = executableWorkflow(for: skill), !workflow.steps.isEmpty else {
            throw ToolExecutionError.missingWorkflow
        }

        var variables = makeInitialVariables(
            skill: skill,
            input: input,
            values: values,
            files: files
        )
        var executedTools: [String] = []
        var finalDisplayText: String?
        var didWriteClipboard = false
        var artifacts: [URL] = []

        for (index, step) in workflow.steps.enumerated() {
            try Task.checkCancellation()
            let canonicalID = registry.canonicalIdentifier(for: step.tool)
            guard let tool = registry.tool(for: canonicalID) else {
                throw ToolExecutionError.unavailableTools([step.tool])
            }
            if skill.resolvedExecutionMode == .localOnly, canonicalID == "model.generateText" {
                throw ToolExecutionError.localSkillRequestedCloudModel
            }

            progress?(
                WorkflowExecutionProgress(
                    toolIdentifier: canonicalID,
                    completedSteps: index,
                    totalSteps: workflow.steps.count,
                    toolFraction: nil
                )
            )

            let arguments = step.arguments.mapValues { resolve($0, variables: variables) }
            let context = ToolExecutionContext(
                skill: skill,
                userInput: input,
                variables: variables,
                files: files,
                modelPromptTemplate: workflow.modelPromptTemplate,
                reportProgress: { toolFraction in
                    Task { @MainActor in
                        progress?(
                            WorkflowExecutionProgress(
                                toolIdentifier: canonicalID,
                                completedSteps: index,
                                totalSteps: workflow.steps.count,
                                toolFraction: toolFraction
                            )
                        )
                    }
                }
            )
            let startedAt = Date()
            AppConsole.shared.info(
                "步骤 \(index + 1)/\(workflow.steps.count) 开始：\(canonicalID)；参数字段=\(arguments.keys.sorted().joined(separator: ","))",
                category: "Workflow"
            )

            do {
                let output = try await tool.execute(arguments: arguments, context: context)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                AppConsole.shared.success(
                    "步骤 \(index + 1)/\(workflow.steps.count) 完成：\(canonicalID)；输出=\(output.value.safeLogSummary)，耗时=\(elapsed)ms",
                    category: "Workflow"
                )
                executedTools.append(canonicalID)
                variables[step.id] = output.value
                variables["step_\(index + 1)"] = output.value
                variables["lastResult"] = output.value
                if let saveAs = step.saveAs, !saveAs.isEmpty {
                    variables[saveAs] = output.value
                }
                if let displayText = output.displayText, !displayText.isEmpty {
                    finalDisplayText = displayText
                }
                if canonicalID == "clipboard.writeText" {
                    didWriteClipboard = true
                }
                for artifact in output.artifacts where !artifacts.contains(artifact) {
                    artifacts.append(artifact)
                }
                progress?(
                    WorkflowExecutionProgress(
                        toolIdentifier: canonicalID,
                        completedSteps: index,
                        totalSteps: workflow.steps.count,
                        toolFraction: 1
                    )
                )
            } catch {
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                AppConsole.shared.error(
                    "步骤 \(index + 1)/\(workflow.steps.count) 失败：\(canonicalID)；耗时=\(elapsed)ms；错误=\(error.localizedDescription)",
                    category: "Workflow"
                )
                throw error
            }
        }

        let outputText = finalDisplayText
            ?? variables["lastResult"]?.stringValue
            ?? "技能已执行完成。"
        return WorkflowExecutionResult(
            outputText: outputText,
            executedTools: executedTools,
            didWriteClipboard: didWriteClipboard,
            artifacts: artifacts
        )
    }

    private func executableWorkflow(for skill: UserSkill) -> ExecutableWorkflow? {
        if let workflow = skill.workflow, !workflow.isEmpty {
            return ExecutableWorkflow(
                steps: workflow,
                modelPromptTemplate: skill.modelTask?.promptTemplate
            )
        }

        if isLegacyClipboardTranslation(skill) {
            return ExecutableWorkflow(
                steps: [
                    SkillWorkflowStep(
                        id: "read_clipboard",
                        tool: "clipboard.readText",
                        arguments: [:],
                        saveAs: "clipboardText"
                    ),
                    SkillWorkflowStep(
                        id: "translate_text",
                        tool: "model.generateText",
                        arguments: ["input": .string("{{clipboardText}}")],
                        saveAs: "translatedText"
                    ),
                    SkillWorkflowStep(
                        id: "write_clipboard",
                        tool: "clipboard.writeText",
                        arguments: ["text": .string("$translatedText")],
                        saveAs: "clipboardResult"
                    )
                ],
                modelPromptTemplate: legacyClipboardTranslationPrompt(for: skill)
            )
        }

        if let modelTask = skill.modelTask {
            return ExecutableWorkflow(
                steps: [
                    SkillWorkflowStep(
                        id: "generate_text",
                        tool: modelTask.tool,
                        arguments: ["input": .string("{{userInput}}")],
                        saveAs: "modelResult"
                    )
                ],
                modelPromptTemplate: modelTask.promptTemplate
            )
        }

        return nil
    }

    private func isLegacyClipboardTranslation(_ skill: UserSkill) -> Bool {
        let tools = Set(skill.requiredTools.map {
            $0.lowercased().replacingOccurrences(of: "_", with: ".")
        })
        let description = ([skill.name, skill.summary, skill.originalRequest] + skill.actions)
            .joined(separator: " ")
            .lowercased()
        let usesClipboard = tools.contains("clipboard")
            || tools.contains("clipboard.readtext")
            || description.contains("剪贴板")
            || description.contains("剪切板")
        let translates = tools.contains("translate")
            || description.contains("翻译")
            || description.contains("translate")
        return usesClipboard && translates
    }

    private func legacyClipboardTranslationPrompt(for skill: UserSkill) -> String {
        let description = ([skill.summary, skill.originalRequest] + skill.actions)
            .joined(separator: " ")
            .lowercased()
        let instruction: String
        if description.contains("英语") || description.contains("英文") || description.contains("english") {
            instruction = "将下面的文本翻译成自然、准确的英语。"
        } else if description.contains("中文") || description.contains("汉语") || description.contains("chinese") {
            instruction = "将下面的文本翻译成自然、准确的中文。"
        } else {
            instruction = "按照用户原始要求完成翻译：\(skill.originalRequest)"
        }
        return """
        \(instruction)
        保留原意、段落、标点和必要格式。不要解释，不要添加引号或前言，只输出译文。

        {{clipboardText}}
        """
    }

    private func makeInitialVariables(
        skill: UserSkill,
        input: String,
        values: [String: String],
        files: [String: [URL]]
    ) -> [String: SkillJSONValue] {
        var variables: [String: SkillJSONValue] = ["userInput": .string(input)]
        for parameter in skill.resolvedParameters {
            if parameter.type.acceptsFiles,
               let path = files[parameter.id]?.first?.path {
                variables[parameter.id] = .string(path)
                variables[parameter.name] = .string(path)
            } else if let value = values[parameter.id] {
                variables[parameter.id] = .string(value)
                variables[parameter.name] = .string(value)
            }
        }
        return variables
    }

    private func resolve(
        _ value: SkillJSONValue,
        variables: [String: SkillJSONValue]
    ) -> SkillJSONValue {
        switch value {
        case .string(let string):
            if string.hasPrefix("$"),
               let variable = variables[String(string.dropFirst())] {
                return variable
            }
            if string.hasPrefix("{{"), string.hasSuffix("}}"),
               let variable = variables[String(string.dropFirst(2).dropLast(2))] {
                return variable
            }
            let resolved = variables.reduce(string) { partial, item in
                partial.replacingOccurrences(of: "{{\(item.key)}}", with: item.value.stringValue)
            }
            return .string(resolved)
        case .array(let values):
            return .array(values.map { resolve($0, variables: variables) })
        case .object(let values):
            return .object(values.mapValues { resolve($0, variables: variables) })
        default:
            return value
        }
    }
}

private extension SkillJSONValue {
    var stringValue: String {
        switch self {
        case .string(let value): value
        default: displayText
        }
    }

    var integerValue: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    var safeLogSummary: String {
        switch self {
        case .string(let value): "文本（\(value.count) 字符）"
        case .integer, .number: "数字"
        case .boolean: "布尔值"
        case .array(let values): "数组（\(values.count) 项）"
        case .object(let values): "对象（\(values.count) 个字段）"
        case .null: "null"
        }
    }
}
