import AppKit
import Foundation

struct WorkflowExecutionResult {
    let outputText: String
    let executedTools: [String]
    let didWriteClipboard: Bool
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
}

private struct ToolExecutionContext {
    let skill: UserSkill
    let userInput: String
    let variables: [String: SkillJSONValue]
    let files: [String: [URL]]
    let modelPromptTemplate: String?
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

@MainActor
private final class ModelGenerateTextTool: AssistantTool {
    let identifier = "model.generateText"

    func execute(
        arguments: [String: SkillJSONValue],
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutput {
        guard context.files.values.allSatisfy(\.isEmpty) else {
            throw ToolExecutionError.unsupportedFileInput
        }

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

        let maxTokens = arguments["maxTokens"]?.integerValue ?? 900
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
            system: system,
            maxTokens: max(64, min(maxTokens, 4_096))
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
        files: [String: [URL]]
    ) async throws -> WorkflowExecutionResult {
        guard files.values.allSatisfy(\.isEmpty) else {
            throw ToolExecutionError.unsupportedFileInput
        }
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

        for (index, step) in workflow.steps.enumerated() {
            try Task.checkCancellation()
            let canonicalID = registry.canonicalIdentifier(for: step.tool)
            guard let tool = registry.tool(for: canonicalID) else {
                throw ToolExecutionError.unavailableTools([step.tool])
            }
            if skill.resolvedExecutionMode == .localOnly, canonicalID == "model.generateText" {
                throw ToolExecutionError.localSkillRequestedCloudModel
            }

            let arguments = step.arguments.mapValues { resolve($0, variables: variables) }
            let context = ToolExecutionContext(
                skill: skill,
                userInput: input,
                variables: variables,
                files: files,
                modelPromptTemplate: workflow.modelPromptTemplate
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
            didWriteClipboard: didWriteClipboard
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
