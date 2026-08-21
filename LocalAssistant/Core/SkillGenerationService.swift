import Foundation
import OSLog

@MainActor
final class SkillGenerationService {
    static let shared = SkillGenerationService()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalAssistant",
        category: "SkillGeneration"
    )

    private init() {}

    func generate(from request: SkillCreationRequest) async throws -> (draft: SkillDraft, source: String) {
        let settings = AISettingsStore.shared
        guard settings.isConfigured() else {
            return (.localDraft(from: request), "本地模板")
        }

        let provider = settings.selectedProvider
        let text = try await requestDraftText(request: request, provider: provider)

        do {
            return (
                try decodeDraft(from: text, expectedExecutionMode: request.executionMode),
                provider.displayName
            )
        } catch {
            logger.warning("第一次技能 JSON 解析失败，正在请求模型修复：\(error.localizedDescription, privacy: .public)")
            let repairedText = try await AIService.shared.generateText(
                prompt: """
                把下面内容修复成符合要求的完整 JSON。保留原意，只输出 JSON：

                \(String(text.prefix(4_000)))
                """,
                system: Self.systemPrompt(for: request.executionMode),
                provider: provider,
                maxTokens: 1_400,
                expectsJSON: true
            )

            do {
                return (
                    try decodeDraft(from: repairedText, expectedExecutionMode: request.executionMode),
                    provider.displayName
                )
            } catch {
                logger.error("第二次技能 JSON 解析仍然失败：\(error.localizedDescription, privacy: .public)")
                throw SkillGenerationError.invalidJSON(
                    details: error.localizedDescription,
                    responsePreview: String(repairedText.prefix(800))
                )
            }
        }
    }

    private func requestDraftText(request: SkillCreationRequest, provider: AIProvider) async throws -> String {
        do {
            return try await AIService.shared.generateText(
                prompt: request.generationPrompt,
                system: Self.systemPrompt(for: request.executionMode),
                provider: provider,
                maxTokens: 1_400,
                expectsJSON: true
            )
        } catch let error as AIServiceError {
            guard case .emptyResponse = error else { throw error }
            logger.warning("模型返回空内容，按服务商建议自动重试一次")
            return try await AIService.shared.generateText(
                prompt: """
                \(request.generationPrompt)

                上一次响应为空。这次请直接返回一个非空、完整、可解析的 JSON 对象，不要进行长篇思考。
                """,
                system: Self.systemPrompt(for: request.executionMode),
                provider: provider,
                maxTokens: 1_800,
                expectsJSON: true
            )
        }
    }

    func decodeDraft(
        from text: String,
        expectedExecutionMode: SkillExecutionMode? = nil
    ) throws -> SkillDraft {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let jsonText: String
        if let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}") {
            jsonText = String(cleaned[first...last])
        } else {
            jsonText = cleaned
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw SkillGenerationError.invalidOutput
        }
        do {
            var draft = try JSONDecoder().decode(SkillDraft.self, from: data)
            if let expectedExecutionMode {
                draft.executionMode = expectedExecutionMode
                try validate(draft, expectedExecutionMode: expectedExecutionMode)
            }
            return draft
        } catch let error as SkillGenerationError {
            throw error
        } catch {
            throw SkillGenerationError.invalidJSON(
                details: Self.decodingDetails(for: error),
                responsePreview: String(cleaned.prefix(800))
            )
        }
    }

    private static func decodingDetails(for error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        let context: DecodingError.Context
        let headline: String
        switch decodingError {
        case .typeMismatch(let type, let valueContext):
            context = valueContext
            headline = "字段类型不匹配，程序期望 \(type)"
        case .valueNotFound(let type, let valueContext):
            context = valueContext
            headline = "字段值缺失，程序期望 \(type)"
        case .keyNotFound(let key, let valueContext):
            context = valueContext
            headline = "缺少必填字段 \(key.stringValue)"
        case .dataCorrupted(let valueContext):
            context = valueContext
            headline = "JSON 数据损坏或包含不支持的值"
        @unknown default:
            return error.localizedDescription
        }

        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty
            ? "\(headline)：\(context.debugDescription)"
            : "\(headline)；位置：\(path)；原因：\(context.debugDescription)"
    }

    private func validate(
        _ draft: SkillDraft,
        expectedExecutionMode: SkillExecutionMode
    ) throws {
        let workflowTools = draft.workflow?.map { $0.tool.lowercased() } ?? []
        let requiredTools = draft.requiredTools.map { $0.lowercased() }

        switch expectedExecutionMode {
        case .localOnly:
            guard draft.modelTask == nil,
                  !workflowTools.contains(where: { $0.hasPrefix("model.") }),
                  !requiredTools.contains(where: { $0.hasPrefix("model.") }) else {
                throw SkillGenerationError.modeViolation("本地技能不能包含云端模型调用")
            }
        case .cloudAssisted:
            guard let modelTask = draft.modelTask,
                  modelTask.tool == "model.generateText",
                  !modelTask.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkillGenerationError.modeViolation("云端 AI 技能必须提供 model.generateText 提示词模板")
            }
        }
    }

    static func systemPrompt(for executionMode: SkillExecutionMode) -> String {
        commonPrompt + "\n\n" + modePrompt(for: executionMode)
    }

    private static let commonPrompt = """
    你是 macOS 个人自动化软件 Local Assistant 的技能编译器。把用户需求转换成受约束、可解释、可静态检查的声明式技能定义。

    只输出 JSON，不要输出 Markdown 或额外说明。JSON 必须严格包含这些字段：
    {
      "name": "简短中文名称",
      "aliases": ["2 到 4 个搜索别名"],
      "summary": "一句话说明",
      "trigger": "何时或如何启动",
      "condition": "条件；没有则为 null",
      "actions": ["按顺序排列、每项为自然语言动作"],
      "fallback": "否则执行什么；没有则为 null",
      "output": "如何把结果反馈给用户",
      "explanation": "用自然语言解释完整流程和限制",
      "requiredTools": ["按实际调用顺序去重后的工具 ID"],
      "permissions": ["实际需要的 macOS 权限或 cloud_api"],
      "executionMode": "localOnly 或 cloudAssisted",
      "parameters": [
        {
          "id": "稳定且唯一的参数 ID",
          "name": "参数显示名称",
          "type": "text、paragraph、file、image、folder、number 或 boolean",
          "required": true,
          "description": "用户应该传入什么"
        }
      ],
      "workflow": [
        {
          "id": "step_1",
          "tool": "工具 ID",
          "arguments": {"工具参数名": "常量、{{参数名称}}、{{userInput}} 或 $前一步输出"},
          "saveAs": "可选输出变量名"
        }
      ],
      "modelTask": null,
      "networkHosts": ["需要访问的主机名；不需要则为空数组"],
      "dataDisclosure": ["会离开本机的数据流说明；没有则为空数组"]
    }

    通用规则：
    - workflow 只能引用下面对应模式列出的工具，不得编造已经可用的系统能力。
    - 如果用户需要但注册表没有工具，在 requiredTools 写 missing:能力，并在 explanation 清楚说明。
    - 不要声称已经执行任务，不生成或执行 Shell、AppleScript、Swift、Python、JavaScript 等任意代码。
    - workflow.arguments 必须始终是 JSON 对象。对象中的值可以是字符串、数字、布尔值、数组、嵌套对象或 null，但必须符合对应工具的真实参数结构。
    - arguments 中的运行时值使用 {{参数名称}}、{{userInput}} 或 $变量引用，不把用户示例数据写死。
    - model.generateText 步骤的 arguments 只传运行时输入，例如 {"input":"{{英文单词}}"}。严禁在 arguments 中放入 promptTemplate、inputVariables 或 providerPolicy；这三个字段只属于顶层 modelTask。
    - 不要把声明字段重复嵌套到 arguments。生成前自行检查 workflow 每个步骤只含 id、tool、arguments、saveAs 四个字段。
    - parameters 必须原样保留用户定义的参数数量、名称、类型与必填状态，不得把文件或图片降级成普通文本。
    - workflow 和 modelTask 通过 {{参数名称}} 引用对应运行时参数；仅在确实需要整条原始输入时使用 {{userInput}}。
    - 文件操作只能使用用户授权路径；修改、删除、发送等操作必须在 permissions 中声明确认要求。
    - 网络访问不等于云端大模型调用。经过授权的本地网络工具可以联网，但必须声明具体目标和用途。
    - actions 是给用户阅读的自然语言步骤；workflow 是给执行器读取的结构化步骤，两者必须一致。
    """

    private static func modePrompt(for executionMode: SkillExecutionMode) -> String {
        switch executionMode {
        case .localOnly:
            return """
            当前模式：localOnly（本地执行）。

            允许的工具注册表：
            - clipboard.readText，arguments={}：读取剪贴板纯文本。
            - clipboard.writeText，arguments={"text":"$前一步输出"}：写入剪贴板纯文本。
            - selection.readText，arguments={}：读取用户在其他应用中选中的文字；需要 accessibility。
            - selection.replaceText，arguments={"text":"$前一步输出"}：经用户原生确认后替换选中文字；需要 accessibility 和 confirmation_required。
            - screen.captureRegion，arguments={}：让用户框选屏幕区域并返回图片路径；需要 screen_recording。
            - image.ocr，arguments={"path":"{{图片}}"}：使用本机 Apple Vision 识别图片文字。
            - file.readText，arguments={"path":"{{文件}}"}：读取文本、代码、RTF 或含文字层的 PDF。
            - file.list，arguments={"directory":"{{文件夹}}","limit":50}：列出用户选择目录中的项目。
            - file.search，arguments={"query":"{{文件名}}","directory":"可选用户目录","limit":30}：按名称有界搜索文件。
            - file.rename，arguments={"path":"{{文件}}","newName":"{{新名称}}"}：经用户原生确认后重命名，不覆盖现有文件。
            - file.createEmpty，arguments={"name":"{{名称.后缀}}"}：在用户下载目录创建空文件；文件名必须带后缀且不能包含路径。
            - file.trash，arguments={"path":"{{文件}}"}：经用户原生确认后移到 macOS 废纸篓。
            - system.snapshot，arguments={}：读取诊断所需的系统、磁盘、温度和高占用进程快照。

            强制要求：
            - executionMode 必须为 localOnly。
            - modelTask 必须为 null。
            - workflow 和 requiredTools 禁止出现任何 model.* 或 cloud_api。
            - 当前尚未注册通用 network.request、通知或任意脚本工具；需要这些能力时必须用 missing:能力 标记，不能伪造可执行工作流。
            - dataDisclosure 通常为空。
            """
        case .cloudAssisted:
            return """
            当前模式：cloudAssisted（云端 AI 协同）。

            除 localOnly 模式中已经注册的本地工具外，额外允许：
            - model.generateText：调用用户配置的统一云端文本模型接口。

            强制要求：
            - executionMode 必须为 cloudAssisted。
            - modelTask 必须存在并严格使用以下结构：
              {"tool":"model.generateText","promptTemplate":"运行时提示词模板，变量使用 {{变量名}}","inputVariables":["变量名"],"providerPolicy":"userDefault"}
            - modelTask.promptTemplate 是以后每次运行技能时使用的提示词，不是本次创建时的回答。
            - workflow 中通过 model.generateText 引用 modelTask；模型前后都可以组合本地工具。
            - model.generateText 的 workflow 示例：{"id":"step_1","tool":"model.generateText","arguments":{"input":"{{英文单词}}"},"saveAs":"modelResult"}。
            - inputVariables 只能出现在 modelTask 中，并且必须列出 promptTemplate 实际引用的运行时变量名。
            - requiredTools 必须包含 model.generateText，permissions 必须包含 cloud_api。
            - dataDisclosure 必须逐项说明哪些变量会发送给云端模型；不得用“必要数据”等模糊描述。
            - 不绑定 DeepSeek、GLM、Gemini 或 OpenAI，运行时使用用户默认服务商。
            """
        }
    }
}

enum SkillGenerationError: LocalizedError {
    case invalidOutput
    case invalidJSON(details: String, responsePreview: String)
    case modeViolation(String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput: "模型没有返回可识别的技能定义"
        case .invalidJSON(let details, let responsePreview):
            "模型返回的技能格式无法读取。\n解析错误：\(details)\n\n模型返回内容（前 800 字）：\n\(responsePreview)"
        case .modeViolation(let details):
            "模型生成的技能违反了运行模式约束：\(details)"
        }
    }
}
