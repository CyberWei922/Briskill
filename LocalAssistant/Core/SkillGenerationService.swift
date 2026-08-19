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
        let text = try await requestDraftText(
            description: request.naturalLanguageDescription,
            provider: provider
        )

        do {
            return (try decodeDraft(from: text), provider.displayName)
        } catch {
            logger.warning("第一次技能 JSON 解析失败，正在请求模型修复：\(error.localizedDescription, privacy: .public)")
            let repairedText = try await AIService.shared.generateText(
                prompt: """
                把下面内容修复成符合要求的完整 JSON。保留原意，只输出 JSON：

                \(String(text.prefix(4_000)))
                """,
                system: Self.systemPrompt,
                provider: provider,
                maxTokens: 1_400,
                expectsJSON: true
            )

            do {
                return (try decodeDraft(from: repairedText), provider.displayName)
            } catch {
                logger.error("第二次技能 JSON 解析仍然失败：\(error.localizedDescription, privacy: .public)")
                throw SkillGenerationError.invalidJSON(
                    details: error.localizedDescription,
                    responsePreview: String(repairedText.prefix(800))
                )
            }
        }
    }

    private func requestDraftText(description: String, provider: AIProvider) async throws -> String {
        do {
            return try await AIService.shared.generateText(
                prompt: description,
                system: Self.systemPrompt,
                provider: provider,
                maxTokens: 1_400,
                expectsJSON: true
            )
        } catch let error as AIServiceError {
            guard case .emptyResponse = error else { throw error }
            logger.warning("模型返回空内容，按服务商建议自动重试一次")
            return try await AIService.shared.generateText(
                prompt: """
                \(description)

                上一次响应为空。这次请直接返回一个非空、完整、可解析的 JSON 对象，不要进行长篇思考。
                """,
                system: Self.systemPrompt,
                provider: provider,
                maxTokens: 1_800,
                expectsJSON: true
            )
        }
    }

    private func decodeDraft(from text: String) throws -> SkillDraft {
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
            return try JSONDecoder().decode(SkillDraft.self, from: data)
        } catch {
            throw SkillGenerationError.invalidJSON(
                details: error.localizedDescription,
                responsePreview: String(cleaned.prefix(800))
            )
        }
    }

    private static let systemPrompt = """
    你是一个 macOS 个人自动化软件的技能设计器。把用户描述转换成一个受约束、可解释的技能草稿。

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
      "requiredTools": ["只填写所需能力名称，例如 selected_text、clipboard、ocr、translate、summarize、file_search、notification、model；不确定则写 missing:能力"],
      "permissions": ["只填写实际需要的 macOS 权限或 cloud_api"]
    }

    当前产品只保证文本模型调用和本地技能保存。不要声称已经执行任务，不要生成 Shell、AppleScript 或代码。缺少能力时必须用 missing: 标记。
    """
}

enum SkillGenerationError: LocalizedError {
    case invalidOutput
    case invalidJSON(details: String, responsePreview: String)

    var errorDescription: String? {
        switch self {
        case .invalidOutput: "模型没有返回可识别的技能定义"
        case .invalidJSON(let details, let responsePreview):
            "模型两次返回的技能格式都无法读取。\n解析错误：\(details)\n\n模型返回内容（前 800 字）：\n\(responsePreview)"
        }
    }
}
