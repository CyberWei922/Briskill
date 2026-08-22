import CryptoKit
import Foundation

enum SkillCreationMode: String, Codable, CaseIterable, Identifiable {
    case guided
    case freeform

    var id: String { rawValue }
}

enum SkillOrigin: String, Codable {
    case user
    case builtIn
}

enum SkillExecutionMode: String, Codable, CaseIterable, Identifiable {
    case local
    case hybrid
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "本地"
        case .hybrid: "混合"
        case .cloud: "云端"
        }
    }

    var compactDescription: String {
        switch self {
        case .local: "仅使用本机工具、AppleScript 或本地模型"
        case .hybrid: "组合本机能力与用户选择的云端模型"
        case .cloud: "只处理用户直接提交给云端模型的内容"
        }
    }

    var allowsCloudModel: Bool {
        self != .local
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "local", "localOnly": self = .local
        case "hybrid", "cloudAssisted": self = .hybrid
        case "cloud": self = .cloud
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知的技能执行类型：\(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SkillParameterType: String, Codable, CaseIterable, Identifiable {
    case text
    case paragraph
    case file
    case image
    case folder
    case number
    case boolean

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: "文本"
        case .paragraph: "段落文字"
        case .file: "文件"
        case .image: "图片"
        case .folder: "文件夹"
        case .number: "数字"
        case .boolean: "是 / 否"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.cursor"
        case .paragraph: "text.alignleft"
        case .file: "doc"
        case .image: "photo"
        case .folder: "folder"
        case .number: "number"
        case .boolean: "switch.2"
        }
    }

    var acceptsFiles: Bool {
        self == .file || self == .image || self == .folder
    }
}

struct SkillParameterDefinition: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var type: SkillParameterType
    var required: Bool
    var description: String

    static func blank(index: Int) -> SkillParameterDefinition {
        SkillParameterDefinition(
            id: UUID().uuidString,
            name: "参数\(index)",
            type: .text,
            required: true,
            description: ""
        )
    }
}

enum SkillJSONValue: Codable, Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([SkillJSONValue])
    case object([String: SkillJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SkillJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SkillJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                SkillJSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "参数值必须是有效的 JSON 字符串、数字、布尔值、数组、对象或 null"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var displayText: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): String(value)
        case .boolean(let value): value ? "true" : "false"
        case .array(let values):
            "[\(values.map(\.jsonFragment).joined(separator: ", "))]"
        case .object(let values):
            "{\(values.keys.sorted().map { key in "\"\(key)\": \(values[key]?.jsonFragment ?? "null")" }.joined(separator: ", "))}"
        case .null: "null"
        }
    }

    private var jsonFragment: String {
        switch self {
        case .string(let value): "\"\(value)\""
        default: displayText
        }
    }

    func replacingParameterReferences(_ replacements: [String: String]) -> SkillJSONValue {
        switch self {
        case .string(let value):
            if value.hasPrefix("$"), let replacement = replacements[String(value.dropFirst())] {
                return .string("$\(replacement)")
            }
            return .string(value.replacingSkillParameterPlaceholders(replacements))
        case .array(let values):
            return .array(values.map { $0.replacingParameterReferences(replacements) })
        case .object(let values):
            return .object(values.mapValues { $0.replacingParameterReferences(replacements) })
        default:
            return self
        }
    }
}

struct SkillWorkflowStep: Codable, Equatable {
    var id: String
    var tool: String
    var arguments: [String: SkillJSONValue]
    var saveAs: String?
}

struct SkillModelTask: Codable, Equatable {
    var tool: String
    var promptTemplate: String
    var inputVariables: [String]
    var providerPolicy: String
}

struct SkillAppleScriptDefinition: Codable, Equatable {
    var source: String
    var argumentVariables: [String]
    var targetApplications: [String]
    var riskNotes: [String]
    var acknowledgedSourceHash: String?

    var sourceHash: String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var hasValidRiskAcknowledgement: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acknowledgedSourceHash == sourceHash
    }

    mutating func acknowledgeCurrentSource() {
        acknowledgedSourceHash = sourceHash
    }

    mutating func invalidateAcknowledgement() {
        acknowledgedSourceHash = nil
    }
}

struct SkillCreationRequest {
    var executionMode: SkillExecutionMode
    var mode: SkillCreationMode
    var skillName: String
    var keyword: String
    var parameters: [SkillParameterDefinition]
    var processText: String
    var outputText: String
    var freeformText: String

    var naturalLanguageDescription: String {
        switch mode {
        case .guided:
            return [
                skillName.isEmpty ? nil : "功能名称：\(skillName)",
                keyword.isEmpty ? nil : "注册关键词：\(keyword)",
                "传入参数：\(parameterDescription)",
                processText.isEmpty ? nil : "处理过程：\(processText)",
                outputText.isEmpty ? nil : "结果：\(outputText)"
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .freeform:
            return [
                "注册关键词：\(keyword)",
                "传入参数：\(parameterDescription)",
                "用户完整提示词：\(freeformText.trimmingCharacters(in: .whitespacesAndNewlines))"
            ].joined(separator: "\n")
        }
    }

    private var parameterDescription: String {
        guard !parameters.isEmpty else { return "无" }
        return parameters.map { parameter in
            let requirement = parameter.required ? "必填" : "可选"
            let note = parameter.description.isEmpty ? "" : "，\(parameter.description)"
            return "\(parameter.name)（\(parameter.type.displayName)，\(requirement)\(note)）"
        }.joined(separator: "；")
    }

    var generationPrompt: String {
        """
        <skill_request>
        execution_mode: \(executionMode.rawValue)
        editor_mode: \(mode.rawValue)
        user_requirement:
        \(naturalLanguageDescription)
        </skill_request>
        """
    }
}

struct SkillDraft: Codable, Equatable {
    var name: String
    var aliases: [String]
    var summary: String
    var trigger: String
    var condition: String?
    var actions: [String]
    var fallback: String?
    var output: String
    var explanation: String
    var requiredTools: [String]
    var permissions: [String]
    var executionMode: SkillExecutionMode?
    var workflow: [SkillWorkflowStep]?
    var modelTask: SkillModelTask?
    var appleScript: SkillAppleScriptDefinition?
    var networkHosts: [String]?
    var dataDisclosure: [String]?
    var parameters: [SkillParameterDefinition]?

    var resolvedExecutionMode: SkillExecutionMode {
        executionMode ?? .hybrid
    }

    var resolvedParameters: [SkillParameterDefinition] {
        parameters ?? []
    }

    static func localDraft(from request: SkillCreationRequest) -> SkillDraft {
        let action = request.mode == .guided ? request.processText : request.freeformText
        let conciseAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedName = request.skillName.nilIfEmpty ?? (conciseAction.isEmpty ? "我的新技能" : String(conciseAction.prefix(12)))

        return SkillDraft(
            name: generatedName,
            aliases: [],
            summary: request.naturalLanguageDescription,
            trigger: request.keyword.isEmpty ? "从快捷面板手动运行" : "输入 \(request.keyword)",
            condition: nil,
            actions: conciseAction.isEmpty ? ["等待补充要执行的动作"] : [conciseAction],
            fallback: nil,
            output: request.outputText.isEmpty ? "在助手面板中显示结果" : request.outputText,
            explanation: "这是由本地模板生成的草稿。配置 AI 服务后，可以获得更准确的步骤、别名和能力分析。",
            requiredTools: [],
            permissions: [],
            executionMode: request.executionMode,
            workflow: [],
            modelTask: request.executionMode.allowsCloudModel
                ? SkillModelTask(
                    tool: "model.generateText",
                    promptTemplate: request.naturalLanguageDescription + "\n\n用户本次输入：{{userInput}}",
                    inputVariables: ["userInput"],
                    providerPolicy: "userDefault"
                )
                : nil,
            appleScript: nil,
            networkHosts: [],
            dataDisclosure: [],
            parameters: request.parameters
        )
    }
}

struct UserSkill: Codable, Identifiable {
    var schemaVersion: Int?
    var id: UUID
    var name: String
    var aliases: [String]
    var registeredKeyword: String?
    var summary: String
    var originalRequest: String
    var creationMode: SkillCreationMode
    var trigger: String
    var condition: String?
    var actions: [String]
    var fallback: String?
    var output: String
    var explanation: String
    var requiredTools: [String]
    var permissions: [String]
    var executionMode: SkillExecutionMode?
    var workflow: [SkillWorkflowStep]?
    var workflowV3: SkillWorkflowDefinitionV3?
    var modelTask: SkillModelTask?
    var appleScript: SkillAppleScriptDefinition?
    var networkHosts: [String]?
    var dataDisclosure: [String]?
    var parameters: [SkillParameterDefinition]?
    var generatedBy: String
    var createdAt: Date
    var updatedAt: Date
    var isEnabled: Bool
    var origin: SkillOrigin?
    var builtInIdentifier: String?

    init(draft: SkillDraft, request: SkillCreationRequest, generatedBy: String) {
        schemaVersion = SkillWorkflowDefinitionV3.currentVersion
        id = UUID()
        name = draft.name
        let registeredKeyword = request.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        aliases = Array(Set(draft.aliases))
        self.registeredKeyword = registeredKeyword.nilIfEmpty
        summary = draft.summary
        originalRequest = request.naturalLanguageDescription
        creationMode = request.mode
        trigger = draft.trigger
        condition = draft.condition
        actions = draft.actions
        fallback = draft.fallback
        output = draft.output
        explanation = draft.explanation
        requiredTools = draft.requiredTools
        permissions = draft.permissions
        executionMode = draft.executionMode ?? request.executionMode
        workflow = draft.workflow
        workflowV3 = SkillWorkflowDefinitionV3.migrate(
            from: draft.workflow ?? [],
            parameters: draft.parameters ?? request.parameters,
            modelTask: draft.modelTask
        )
        modelTask = draft.modelTask
        appleScript = draft.appleScript
        networkHosts = draft.networkHosts
        dataDisclosure = draft.dataDisclosure
        parameters = draft.parameters ?? request.parameters
        self.generatedBy = generatedBy
        createdAt = Date()
        updatedAt = Date()
        isEnabled = true
        origin = .user
        builtInIdentifier = nil
    }

    init(
        builtInIdentifier: String,
        id: UUID,
        name: String,
        keyword: String,
        aliases: [String],
        summary: String,
        actions: [String],
        output: String,
        requiredTools: [String],
        permissions: [String],
        executionMode: SkillExecutionMode,
        parameters: [SkillParameterDefinition] = [],
        workflow: [SkillWorkflowStep],
        modelTask: SkillModelTask? = nil,
        dataDisclosure: [String] = []
    ) {
        schemaVersion = SkillWorkflowDefinitionV3.currentVersion
        self.id = id
        self.name = name
        self.aliases = Array(Set(aliases))
        registeredKeyword = keyword
        self.summary = summary
        originalRequest = summary
        creationMode = .guided
        trigger = "输入 \(keyword)" + (parameters.isEmpty ? "" : "，并提供所需参数")
        condition = nil
        self.actions = actions
        fallback = "执行失败时显示具体错误，不进行未授权的替代操作"
        self.output = output
        explanation = summary + " 这是随软件提供的可编辑默认技能；它与用户技能使用相同格式，可以关闭、修改、导出或删除。"
        self.requiredTools = requiredTools
        self.permissions = permissions
        self.executionMode = executionMode
        self.workflow = workflow
        workflowV3 = SkillWorkflowDefinitionV3.migrate(
            from: workflow,
            parameters: parameters,
            modelTask: modelTask
        )
        self.modelTask = modelTask
        appleScript = nil
        networkHosts = []
        self.dataDisclosure = dataDisclosure
        self.parameters = parameters
        generatedBy = "Local Assistant"
        createdAt = Date(timeIntervalSince1970: 1_787_225_600)
        updatedAt = createdAt
        isEnabled = true
        origin = .builtIn
        self.builtInIdentifier = builtInIdentifier
    }

    var searchTerms: [String] {
        [registeredKeyword].compactMap { $0 } + aliases + [name, summary, originalRequest]
    }

    var resolvedExecutionMode: SkillExecutionMode {
        executionMode ?? .hybrid
    }

    var resolvedSchemaVersion: Int {
        schemaVersion ?? 1
    }

    var resolvedWorkflowV3: SkillWorkflowDefinitionV3 {
        workflowV3 ?? SkillWorkflowDefinitionV3.migrate(
            from: workflow ?? [],
            parameters: resolvedParameters,
            modelTask: modelTask
        )
    }

    var resolvedWorkflowToolIdentifiers: [String] {
        if let workflowV3, !workflowV3.steps.isEmpty {
            return workflowV3.steps.map(\.toolID)
        }
        return workflow?.map(\.tool) ?? []
    }

    var containsAppleScript: Bool {
        guard let appleScript else { return false }
        return !appleScript.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasValidAppleScriptRiskAcknowledgement: Bool {
        !containsAppleScript || appleScript?.hasValidRiskAcknowledgement == true
    }

    mutating func acknowledgeAppleScriptRisk() {
        appleScript?.acknowledgeCurrentSource()
    }

    var resolvedParameters: [SkillParameterDefinition] {
        parameters ?? []
    }

    var isBuiltIn: Bool {
        origin == .builtIn || builtInIdentifier != nil
    }

    var executionExample: String {
        let command = registeredKeyword?.nilIfEmpty
            ?? name
        let arguments = resolvedParameters.map { parameter in
            let value = parameter.name.nilIfEmpty ?? parameter.type.displayName
            return parameter.required ? value : "[\(value)]"
        }
        return ([command] + arguments).joined(separator: " ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension String {
    func replacingSkillParameterPlaceholders(_ replacements: [String: String]) -> String {
        var result = self
        let staged = replacements.keys.sorted().enumerated().map { index, oldName in
            (oldName, "__LOCAL_ASSISTANT_PARAMETER_\(index)__")
        }
        for (oldName, marker) in staged {
            result = result.replacingOccurrences(of: "{{\(oldName)}}", with: marker)
        }
        for (oldName, marker) in staged {
            guard let newName = replacements[oldName] else { continue }
            result = result.replacingOccurrences(of: marker, with: "{{\(newName)}}")
        }
        return result
    }
}
