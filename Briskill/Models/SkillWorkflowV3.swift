import Foundation

enum SkillWorkflowBindingKind: String, Codable, CaseIterable, Identifiable {
    case userInput
    case parameter
    case stepOutput
    case literal
    case template
    case array
    case object

    var id: String { rawValue }
}

indirect enum SkillWorkflowBinding: Codable, Equatable {
    case userInput
    case parameter(String)
    case stepOutput(String)
    case literal(SkillJSONValue)
    case template(String)
    case array([SkillWorkflowBinding])
    case object([String: SkillWorkflowBinding])

    private enum CodingKeys: String, CodingKey {
        case type
        case parameterID
        case stepID
        case value
        case template
        case items
        case fields
    }

    var kind: SkillWorkflowBindingKind {
        switch self {
        case .userInput: .userInput
        case .parameter: .parameter
        case .stepOutput: .stepOutput
        case .literal: .literal
        case .template: .template
        case .array: .array
        case .object: .object
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SkillWorkflowBindingKind.self, forKey: .type)
        switch type {
        case .userInput:
            self = .userInput
        case .parameter:
            self = .parameter(try container.decode(String.self, forKey: .parameterID))
        case .stepOutput:
            self = .stepOutput(try container.decode(String.self, forKey: .stepID))
        case .literal:
            self = .literal(try container.decode(SkillJSONValue.self, forKey: .value))
        case .template:
            self = .template(try container.decode(String.self, forKey: .template))
        case .array:
            self = .array(try container.decode([SkillWorkflowBinding].self, forKey: .items))
        case .object:
            self = .object(try container.decode([String: SkillWorkflowBinding].self, forKey: .fields))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .userInput:
            break
        case .parameter(let identifier):
            try container.encode(identifier, forKey: .parameterID)
        case .stepOutput(let identifier):
            try container.encode(identifier, forKey: .stepID)
        case .literal(let value):
            try container.encode(value, forKey: .value)
        case .template(let value):
            try container.encode(value, forKey: .template)
        case .array(let values):
            try container.encode(values, forKey: .items)
        case .object(let values):
            try container.encode(values, forKey: .fields)
        }
    }
}

/// Shared parser/rewriter for the `{{token}}` syntax used by workflow templates.
/// Keeping this in one place prevents the editor, validator and runtime-facing
/// migration helpers from interpreting the same template differently.
enum SkillWorkflowTemplateReferences {
    static func tokens(in template: String) -> [String] {
        var result: [String] = []
        var cursor = template.startIndex

        while cursor < template.endIndex,
              let opening = template.range(
                  of: "{{",
                  range: cursor..<template.endIndex
              ),
              let closing = template.range(
                  of: "}}",
                  range: opening.upperBound..<template.endIndex
              ) {
            let token = template[opening.upperBound..<closing.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                result.append(token)
            }
            cursor = closing.upperBound
        }

        return result
    }

    static func singleToken(in template: String) -> String? {
        let value = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("{{"), value.hasSuffix("}}"), value.count > 4 else {
            return nil
        }
        let token = String(value.dropFirst(2).dropLast(2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              !token.contains("{{"),
              !token.contains("}}"),
              tokens(in: value) == [token] else {
            return nil
        }
        return token
    }

    static func replacingTokens(
        in template: String,
        replacements: [String: String]
    ) -> String {
        guard !replacements.isEmpty else { return template }

        var result = ""
        var cursor = template.startIndex
        while cursor < template.endIndex,
              let opening = template.range(
                  of: "{{",
                  range: cursor..<template.endIndex
              ),
              let closing = template.range(
                  of: "}}",
                  range: opening.upperBound..<template.endIndex
              ) {
            result += template[cursor..<opening.lowerBound]
            let token = template[opening.upperBound..<closing.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let replacement = replacements[token] {
                result += "{{\(replacement)}}"
            } else {
                result += template[opening.lowerBound..<closing.upperBound]
            }
            cursor = closing.upperBound
        }
        result += template[cursor..<template.endIndex]
        return result
    }
}

extension SkillWorkflowBinding {
    var templateReferenceTokens: [String] {
        switch self {
        case .template(let value):
            return SkillWorkflowTemplateReferences.tokens(in: value)
        case .array(let values):
            return values.flatMap(\.templateReferenceTokens)
        case .object(let values):
            return values.values.flatMap(\.templateReferenceTokens)
        case .userInput, .parameter, .stepOutput, .literal:
            return []
        }
    }

    func referenceCount(matching identifiers: Set<String>) -> Int {
        switch self {
        case .parameter(let identifier):
            return identifiers.contains(identifier) ? 1 : 0
        case .template(let value):
            return SkillWorkflowTemplateReferences.tokens(in: value)
                .filter(identifiers.contains)
                .count
        case .array(let values):
            return values.reduce(0) { $0 + $1.referenceCount(matching: identifiers) }
        case .object(let values):
            return values.values.reduce(0) { $0 + $1.referenceCount(matching: identifiers) }
        case .userInput, .stepOutput, .literal:
            return 0
        }
    }

    func replacingParameterReferences(
        oldID: String,
        oldName: String,
        newID: String,
        newName: String
    ) -> SkillWorkflowBinding {
        var replacements: [String: String] = [:]
        if !oldID.isEmpty, oldID != newID { replacements[oldID] = newID }
        if !oldName.isEmpty, oldName != newName { replacements[oldName] = newName }
        switch self {
        case .parameter(let identifier):
            return .parameter(identifier == oldID ? newID : identifier)
        case .template(let value):
            return .template(
                SkillWorkflowTemplateReferences.replacingTokens(
                    in: value,
                    replacements: replacements
                )
            )
        case .array(let values):
            return .array(values.map {
                $0.replacingParameterReferences(
                    oldID: oldID,
                    oldName: oldName,
                    newID: newID,
                    newName: newName
                )
            })
        case .object(let values):
            return .object(values.mapValues {
                $0.replacingParameterReferences(
                    oldID: oldID,
                    oldName: oldName,
                    newID: newID,
                    newName: newName
                )
            })
        case .userInput, .stepOutput, .literal:
            return self
        }
    }
}

struct SkillWorkflowStepV3: Codable, Equatable, Identifiable {
    var id: String
    var toolID: String
    var arguments: [String: SkillWorkflowBinding]
    var promptTemplate: String?
    var outputName: String?

    static func blank(toolID: String, index: Int) -> SkillWorkflowStepV3 {
        SkillWorkflowStepV3(
            id: "step_\(index)_\(UUID().uuidString.prefix(6).lowercased())",
            toolID: toolID,
            arguments: [:],
            promptTemplate: nil,
            outputName: nil
        )
    }
}

struct SkillWorkflowDefinitionV3: Codable, Equatable {
    static let currentVersion = 3

    var version: Int
    var steps: [SkillWorkflowStepV3]

    init(version: Int = currentVersion, steps: [SkillWorkflowStepV3]) {
        self.version = version
        self.steps = steps
    }

    static func migrate(
        from legacySteps: [SkillWorkflowStep],
        parameters: [SkillParameterDefinition],
        modelTask: SkillModelTask? = nil
    ) -> SkillWorkflowDefinitionV3 {
        var outputReferences: [String: String] = [:]
        var usedIDs = Set<String>()
        var migrated: [SkillWorkflowStepV3] = []

        for (index, step) in legacySteps.enumerated() {
            var identifier = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if identifier.isEmpty {
                identifier = "step_\(index + 1)"
            }
            let baseIdentifier = identifier
            var suffix = 2
            while !usedIDs.insert(identifier).inserted {
                identifier = "\(baseIdentifier)_\(suffix)"
                suffix += 1
            }

            let arguments = step.arguments.mapValues { value in
                SkillWorkflowBinding.migrate(
                    value,
                    parameters: parameters,
                    priorOutputs: outputReferences
                )
            }
            migrated.append(
                SkillWorkflowStepV3(
                    id: identifier,
                    toolID: step.tool,
                    arguments: arguments,
                    promptTemplate: step.tool == "model.generateText"
                        ? modelTask?.promptTemplate
                        : nil,
                    outputName: step.saveAs
                )
            )
            outputReferences[step.id] = identifier
            outputReferences[identifier] = identifier
            outputReferences["step_\(index + 1)"] = identifier
            outputReferences["lastResult"] = identifier
            if let saveAs = step.saveAs, !saveAs.isEmpty {
                outputReferences[saveAs] = identifier
            }
        }

        return SkillWorkflowDefinitionV3(steps: migrated)
    }

    func parameterReferenceCount(parameterID: String, parameterName: String) -> Int {
        let identifiers = Set([parameterID, parameterName].filter { !$0.isEmpty })
        guard !identifiers.isEmpty else { return 0 }

        return steps.reduce(0) { count, step in
            let argumentCount = step.arguments.values.reduce(0) {
                $0 + $1.referenceCount(matching: identifiers)
            }
            let promptCount = step.promptTemplate.map {
                SkillWorkflowTemplateReferences.tokens(in: $0)
                    .filter(identifiers.contains)
                    .count
            } ?? 0
            return count + argumentCount + promptCount
        }
    }

    mutating func replaceParameterReferences(
        oldID: String,
        oldName: String,
        newID: String,
        newName: String
    ) {
        var replacements: [String: String] = [:]
        if !oldID.isEmpty, oldID != newID { replacements[oldID] = newID }
        if !oldName.isEmpty, oldName != newName { replacements[oldName] = newName }
        for index in steps.indices {
            steps[index].arguments = steps[index].arguments.mapValues {
                $0.replacingParameterReferences(
                    oldID: oldID,
                    oldName: oldName,
                    newID: newID,
                    newName: newName
                )
            }
            if let prompt = steps[index].promptTemplate {
                steps[index].promptTemplate = SkillWorkflowTemplateReferences.replacingTokens(
                    in: prompt,
                    replacements: replacements
                )
            }
        }
    }
}

private extension SkillWorkflowBinding {
    static func migrate(
        _ value: SkillJSONValue,
        parameters: [SkillParameterDefinition],
        priorOutputs: [String: String]
    ) -> SkillWorkflowBinding {
        switch value {
        case .string(let string):
            if string == "{{userInput}}" {
                return .userInput
            }
            if let token = SkillWorkflowTemplateReferences.singleToken(in: string) {
                if token == "userInput" { return .userInput }
                if let parameter = parameters.first(where: { $0.id == token || $0.name == token }) {
                    return .parameter(parameter.id)
                }
                return .template(string)
            }
            if string.hasPrefix("$"),
               let identifier = priorOutputs[String(string.dropFirst())] {
                return .stepOutput(identifier)
            }
            if string.contains("{{") || string.hasPrefix("$") {
                return .template(string)
            }
            return .literal(.string(string))
        case .array(let values):
            return .array(values.map {
                migrate($0, parameters: parameters, priorOutputs: priorOutputs)
            })
        case .object(let values):
            return .object(values.mapValues {
                migrate($0, parameters: parameters, priorOutputs: priorOutputs)
            })
        default:
            return .literal(value)
        }
    }
}

enum SkillWorkflowCompiler {
    static func compile(
        _ definition: SkillWorkflowDefinitionV3,
        parameters: [SkillParameterDefinition]
    ) -> [SkillWorkflowStep] {
        definition.steps.map { step in
            SkillWorkflowStep(
                id: step.id,
                tool: step.toolID,
                arguments: step.arguments.mapValues { compile($0, parameters: parameters) },
                saveAs: step.outputName ?? step.id
            )
        }
    }

    static func inferExecutionMode(from definition: SkillWorkflowDefinitionV3) -> SkillExecutionMode {
        let locations = definition.steps.compactMap {
            ToolDescriptorCatalog.byIdentifier[$0.toolID]?.executionLocation
        }
        let hasLocal = locations.contains(.local)
        let hasCloud = locations.contains(.cloud)
        if hasLocal && hasCloud { return .hybrid }
        if hasCloud { return .cloud }
        return .local
    }

    static func toolIdentifiers(from definition: SkillWorkflowDefinitionV3) -> [String] {
        var seen = Set<String>()
        return definition.steps.compactMap { step in
            seen.insert(step.toolID).inserted ? step.toolID : nil
        }
    }

    static func permissions(from definition: SkillWorkflowDefinitionV3) -> [String] {
        var seen = Set<String>()
        return toolIdentifiers(from: definition)
            .flatMap { ToolDescriptorCatalog.byIdentifier[$0]?.permissions ?? [] }
            .filter { seen.insert($0).inserted }
    }

    private static func compile(
        _ binding: SkillWorkflowBinding,
        parameters: [SkillParameterDefinition]
    ) -> SkillJSONValue {
        switch binding {
        case .userInput:
            return .string("{{userInput}}")
        case .parameter(let identifier):
            return .string("{{\(identifier)}}")
        case .stepOutput(let identifier):
            return .string("$\(identifier)")
        case .literal(let value):
            return value
        case .template(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map { compile($0, parameters: parameters) })
        case .object(let values):
            return .object(values.mapValues { compile($0, parameters: parameters) })
        }
    }
}

enum SkillWorkflowIssueSeverity: String, Codable {
    case warning
    case error
}

struct SkillWorkflowValidationIssue: Identifiable, Equatable {
    let severity: SkillWorkflowIssueSeverity
    let message: String
    let stepID: String?
    let argumentName: String?

    var id: String {
        [severity.rawValue, stepID ?? "workflow", argumentName ?? "", message]
            .joined(separator: "|")
    }
}

struct SkillWorkflowValidationError: LocalizedError {
    let issues: [SkillWorkflowValidationIssue]

    var errorDescription: String? {
        issues
            .filter { $0.severity == .error }
            .map(\.message)
            .joined(separator: "；")
    }
}

enum SkillWorkflowValidator {
    static func validate(
        _ definition: SkillWorkflowDefinitionV3,
        parameters: [SkillParameterDefinition],
        executionMode: SkillExecutionMode,
        modelTask: SkillModelTask?,
        appleScript: SkillAppleScriptDefinition?
    ) -> [SkillWorkflowValidationIssue] {
        var issues: [SkillWorkflowValidationIssue] = []
        if definition.version > SkillWorkflowDefinitionV3.currentVersion {
            issues.append(
                issue(
                    .error,
                    "此技能使用更新的工作流版本（\(definition.version)），当前版本最高支持 \(SkillWorkflowDefinitionV3.currentVersion)"
                )
            )
        }
        guard !definition.steps.isEmpty else {
            issues.append(issue(.error, "运行流程至少需要一个步骤"))
            return issues
        }

        var knownStepIDs = Set<String>()
        let parameterIDs = Set(parameters.map(\.id))
        let parameterNames = Set(parameters.map(\.name))
        var parameterTypes: [String: String] = [:]
        var parameterRequired: [String: Bool] = [:]
        var seenParameterIDs = Set<String>()
        var seenParameterNames = Set<String>()
        for parameter in parameters {
            if !seenParameterIDs.insert(parameter.id).inserted {
                issues.append(issue(.error, "用户参数内部标识“\(parameter.id)”重复"))
            }
            let trimmedName = parameter.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
                issues.append(issue(.error, "用户参数名称不能为空"))
            } else if parameter.name != trimmedName {
                issues.append(issue(.error, "用户参数名称“\(parameter.name)”首尾不能包含空白"))
            } else if !seenParameterNames.insert(trimmedName).inserted {
                issues.append(issue(.error, "用户参数名称“\(trimmedName)”重复"))
            }
            parameterTypes[parameter.id] = workflowType(for: parameter.type)
            parameterRequired[parameter.id] = parameter.required
            if !parameter.name.isEmpty {
                parameterRequired[parameter.name] = parameter.required
            }
        }
        for identifier in parameterIDs.intersection(parameterNames) {
            issues.append(issue(.error, "用户参数内部标识“\(identifier)”与参数名称冲突"))
        }
        let allStepIDs = Set(definition.steps.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        var allStepReferenceIndices: [String: Int] = [:]
        for (index, step) in definition.steps.enumerated() {
            let identifiers = [
                step.id.trimmingCharacters(in: .whitespacesAndNewlines),
                step.outputName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ].filter { !$0.isEmpty }
            for identifier in identifiers where allStepReferenceIndices[identifier] == nil {
                allStepReferenceIndices[identifier] = index
            }
        }
        var priorOutputTypes: [String: String] = [:]
        var priorTemplateReferences = parameterIDs.union(parameterNames)
        priorTemplateReferences.insert("userInput")
        var usedOutputNames = Set<String>()
        var hasLocal = false
        var hasCloud = false
        var hasAppleScriptStep = false

        for (index, step) in definition.steps.enumerated() {
            let priorStepIDs = knownStepIDs
            let trimmedID = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedID.isEmpty {
                issues.append(issue(.error, "第 \(index + 1) 步缺少内部标识", step: step.id))
            } else if step.id != trimmedID {
                issues.append(issue(.error, "步骤标识“\(step.id)”首尾不能包含空白", step: step.id))
            } else if !knownStepIDs.insert(trimmedID).inserted {
                issues.append(issue(.error, "步骤标识“\(trimmedID)”重复", step: step.id))
            }
            if parameterIDs.contains(trimmedID) || parameterNames.contains(trimmedID) {
                issues.append(issue(.error, "步骤标识“\(trimmedID)”与用户参数冲突", step: step.id))
            }
            if usedOutputNames.contains(trimmedID) {
                issues.append(issue(.error, "步骤标识“\(trimmedID)”与前序输出名称冲突", step: step.id))
            }

            if let prompt = step.promptTemplate {
                validateTemplateReferences(
                    in: prompt,
                    allowedReferences: priorTemplateReferences,
                    allStepReferenceIndices: allStepReferenceIndices,
                    currentStepIndex: index,
                    stepID: step.id,
                    argumentName: nil,
                    issues: &issues
                )
            }
            if step.toolID == "model.generateText",
               step.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(issue(.error, "每个云端模型步骤都必须填写非空的运行时提示词", step: step.id))
            }

            guard let descriptor = ToolDescriptorCatalog.byIdentifier[step.toolID] else {
                issues.append(issue(.error, "第 \(index + 1) 步引用了不存在的工具 \(step.toolID)", step: step.id))
                if !trimmedID.isEmpty { priorTemplateReferences.insert(trimmedID) }
                if let outputName = step.outputName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !outputName.isEmpty {
                    priorTemplateReferences.insert(outputName)
                }
                priorTemplateReferences.insert("lastResult")
                continue
            }
            if descriptor.executionLocation == .local { hasLocal = true }
            if descriptor.executionLocation == .cloud { hasCloud = true }
            if descriptor.id == "automation.appleScript" { hasAppleScriptStep = true }

            if let rawOutputName = step.outputName,
               !rawOutputName.isEmpty {
                let outputName = rawOutputName.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawOutputName != outputName {
                    issues.append(issue(.error, "输出名称“\(rawOutputName)”首尾不能包含空白", step: step.id))
                }
                if !usedOutputNames.insert(outputName).inserted {
                    issues.append(issue(.error, "输出名称“\(outputName)”重复", step: step.id))
                }
                if parameterIDs.contains(outputName) || parameterNames.contains(outputName) {
                    issues.append(issue(.error, "输出名称“\(outputName)”与用户参数冲突", step: step.id))
                }
                if outputName != trimmedID, allStepIDs.contains(outputName) {
                    issues.append(issue(.error, "输出名称“\(outputName)”与步骤标识冲突", step: step.id))
                }
            }

            let allowedArguments = Set(descriptor.arguments.map(\.name))
            for unknown in Set(step.arguments.keys).subtracting(allowedArguments).sorted() {
                issues.append(issue(.error, "\(descriptor.displayName) 不支持参数“\(unknown)”", step: step.id, argument: unknown))
            }
            for argument in descriptor.arguments where argument.required && step.arguments[argument.name] == nil {
                issues.append(issue(.error, "\(descriptor.displayName) 缺少必填参数“\(argument.name)”", step: step.id, argument: argument.name))
            }

            for (name, binding) in step.arguments {
                let argumentDescriptor = descriptor.arguments.first(where: { $0.name == name })
                validate(
                    binding,
                    parameterIDs: parameterIDs,
                    parameterTypes: parameterTypes,
                    parameterRequired: parameterRequired,
                    priorStepIDs: priorStepIDs,
                    priorOutputTypes: priorOutputTypes,
                    allowedTemplateReferences: priorTemplateReferences,
                    allStepReferenceIndices: allStepReferenceIndices,
                    currentStepIndex: index,
                    expectedType: argumentDescriptor?.type,
                    argumentRequired: argumentDescriptor?.required == true,
                    stepID: step.id,
                    argumentName: name,
                    issues: &issues
                )
            }
            priorOutputTypes[trimmedID] = descriptor.outputType
            if !trimmedID.isEmpty { priorTemplateReferences.insert(trimmedID) }
            if let outputName = step.outputName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !outputName.isEmpty {
                priorTemplateReferences.insert(outputName)
            }
            priorTemplateReferences.insert("lastResult")
        }

        switch executionMode {
        case .local where hasCloud:
            issues.append(issue(.error, "本地技能不能包含云端模型步骤"))
        case .cloud where hasLocal:
            issues.append(issue(.error, "云端技能不能包含本地工具步骤"))
        case .hybrid where !(hasLocal && hasCloud):
            issues.append(issue(.error, "混合技能必须同时包含本地工具和云端模型步骤"))
        default:
            break
        }

        let modelSteps = definition.steps.filter { $0.toolID == "model.generateText" }
        if let firstModelStep = modelSteps.first {
            if let modelTask {
                if modelTask.tool != "model.generateText" {
                    issues.append(issue(.error, "模型任务引用了不受支持的工具 \(modelTask.tool)"))
                }
                if modelTask.promptTemplate != firstModelStep.promptTemplate {
                    issues.append(issue(.error, "模型任务提示词与运行流程中的第一个模型步骤不一致"))
                }
            } else {
                issues.append(issue(.error, "运行流程包含模型步骤，但缺少模型任务元数据"))
            }
        } else if modelTask != nil {
            issues.append(issue(.error, "技能保存了模型任务，但运行流程中没有模型步骤"))
        }

        if hasAppleScriptStep, appleScript == nil {
            issues.append(issue(.error, "AppleScript 步骤缺少脚本源代码"))
        }
        if appleScript != nil, !hasAppleScriptStep {
            issues.append(issue(.error, "技能保存了 AppleScript，但运行流程中没有 AppleScript 步骤"))
        }

        return issues
    }

    static func validateForSaving(
        _ definition: SkillWorkflowDefinitionV3,
        parameters: [SkillParameterDefinition],
        executionMode: SkillExecutionMode,
        modelTask: SkillModelTask?,
        appleScript: SkillAppleScriptDefinition?
    ) throws {
        let issues = validate(
            definition,
            parameters: parameters,
            executionMode: executionMode,
            modelTask: modelTask,
            appleScript: appleScript
        )
        let errors = issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            throw SkillWorkflowValidationError(issues: errors)
        }
    }

    private static func validate(
        _ binding: SkillWorkflowBinding,
        parameterIDs: Set<String>,
        parameterTypes: [String: String],
        parameterRequired: [String: Bool],
        priorStepIDs: Set<String>,
        priorOutputTypes: [String: String],
        allowedTemplateReferences: Set<String>,
        allStepReferenceIndices: [String: Int],
        currentStepIndex: Int,
        expectedType: String?,
        argumentRequired: Bool,
        stepID: String,
        argumentName: String,
        issues: inout [SkillWorkflowValidationIssue]
    ) {
        let actualType = bindingType(
            binding,
            parameterTypes: parameterTypes,
            priorOutputTypes: priorOutputTypes
        )
        if let expectedType, let actualType,
           !typesAreCompatible(actual: actualType, expected: expectedType) {
            issues.append(
                issue(
                    .error,
                    "参数“\(argumentName)”需要 \(expectedType)，当前来源输出 \(actualType)",
                    step: stepID,
                    argument: argumentName
                )
            )
        }

        switch binding {
        case .parameter(let identifier):
            if !parameterIDs.contains(identifier) {
                issues.append(issue(.error, "参数“\(argumentName)”引用了已不存在的用户参数", step: stepID, argument: argumentName))
            } else if argumentRequired, parameterRequired[identifier] == false {
                issues.append(
                    issue(
                        .error,
                        "必填工具参数“\(argumentName)”不能直接绑定可选用户参数",
                        step: stepID,
                        argument: argumentName
                    )
                )
            }
        case .stepOutput(let identifier):
            if !priorStepIDs.contains(identifier) {
                issues.append(issue(.error, "参数“\(argumentName)”只能引用它之前步骤的输出", step: stepID, argument: argumentName))
            }
        case .array(let values):
            for value in values {
                validate(
                    value,
                    parameterIDs: parameterIDs,
                    parameterTypes: parameterTypes,
                    parameterRequired: parameterRequired,
                    priorStepIDs: priorStepIDs,
                    priorOutputTypes: priorOutputTypes,
                    allowedTemplateReferences: allowedTemplateReferences,
                    allStepReferenceIndices: allStepReferenceIndices,
                    currentStepIndex: currentStepIndex,
                    expectedType: nil,
                    argumentRequired: false,
                    stepID: stepID,
                    argumentName: argumentName,
                    issues: &issues
                )
            }
        case .object(let values):
            for value in values.values {
                validate(
                    value,
                    parameterIDs: parameterIDs,
                    parameterTypes: parameterTypes,
                    parameterRequired: parameterRequired,
                    priorStepIDs: priorStepIDs,
                    priorOutputTypes: priorOutputTypes,
                    allowedTemplateReferences: allowedTemplateReferences,
                    allStepReferenceIndices: allStepReferenceIndices,
                    currentStepIndex: currentStepIndex,
                    expectedType: nil,
                    argumentRequired: false,
                    stepID: stepID,
                    argumentName: argumentName,
                    issues: &issues
                )
            }
        case .template(let value):
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue(.warning, "参数“\(argumentName)”使用了空模板", step: stepID, argument: argumentName))
            }
            validateTemplateReferences(
                in: value,
                allowedReferences: allowedTemplateReferences,
                allStepReferenceIndices: allStepReferenceIndices,
                currentStepIndex: currentStepIndex,
                stepID: stepID,
                argumentName: argumentName,
                issues: &issues
            )
            if argumentRequired,
               SkillWorkflowTemplateReferences.tokens(in: value)
                .contains(where: { parameterRequired[$0] == false }) {
                issues.append(
                    issue(
                        .error,
                        "必填工具参数“\(argumentName)”的模板不能依赖可选用户参数",
                        step: stepID,
                        argument: argumentName
                    )
                )
            }
        case .literal(.null):
            if argumentRequired {
                issues.append(
                    issue(
                        .error,
                        "必填工具参数“\(argumentName)”不能设置为空值",
                        step: stepID,
                        argument: argumentName
                    )
                )
            }
        case .userInput, .literal:
            break
        }
    }

    private static func validateTemplateReferences(
        in template: String,
        allowedReferences: Set<String>,
        allStepReferenceIndices: [String: Int],
        currentStepIndex: Int,
        stepID: String,
        argumentName: String?,
        issues: inout [SkillWorkflowValidationIssue]
    ) {
        let unknownTokens = Set(SkillWorkflowTemplateReferences.tokens(in: template))
            .subtracting(allowedReferences)
            .sorted()
        for token in unknownTokens {
            let target = argumentName.map { "参数“\($0)”" } ?? "提示词"
            if let referenceIndex = allStepReferenceIndices[token],
               referenceIndex >= currentStepIndex {
                issues.append(
                    issue(
                        .error,
                        "\(target)引用了尚未产生的当前或后续步骤输出“\(token)”",
                        step: stepID,
                        argument: argumentName
                    )
                )
            } else {
                issues.append(
                    issue(
                        .error,
                        "\(target)引用了未知变量“\(token)”",
                        step: stepID,
                        argument: argumentName
                    )
                )
            }
        }
    }

    private static func workflowType(for parameterType: SkillParameterType) -> String {
        switch parameterType {
        case .text, .paragraph: "text"
        case .file: "file"
        case .image: "image"
        case .folder: "folder"
        case .number: "number"
        case .boolean: "boolean"
        }
    }

    private static func bindingType(
        _ binding: SkillWorkflowBinding,
        parameterTypes: [String: String],
        priorOutputTypes: [String: String]
    ) -> String? {
        switch binding {
        case .userInput, .template:
            return "text"
        case .parameter(let identifier):
            return parameterTypes[identifier]
        case .stepOutput(let identifier):
            return priorOutputTypes[identifier]
        case .literal(let value):
            switch value {
            case .string: return "text"
            case .integer, .number: return "number"
            case .boolean: return "boolean"
            case .array: return "array"
            case .object: return "object"
            case .null: return nil
            }
        case .array:
            return "array"
        case .object:
            return "object"
        }
    }

    private static func typesAreCompatible(actual: String, expected: String) -> Bool {
        if actual == expected { return true }
        switch expected {
        case "text":
            return ["number", "boolean", "file", "image", "folder", "array", "object"].contains(actual)
        case "file":
            return ["image", "text"].contains(actual)
        case "folder":
            return actual == "text"
        case "number", "boolean":
            return actual == "text"
        default:
            return false
        }
    }

    private static func issue(
        _ severity: SkillWorkflowIssueSeverity,
        _ message: String,
        step: String? = nil,
        argument: String? = nil
    ) -> SkillWorkflowValidationIssue {
        SkillWorkflowValidationIssue(
            severity: severity,
            message: message,
            stepID: step,
            argumentName: argument
        )
    }
}

enum SkillWorkflowDescriber {
    static func actionLines(for definition: SkillWorkflowDefinitionV3) -> [String] {
        definition.steps.enumerated().map { index, step in
            let rawName = ToolDescriptorCatalog.byIdentifier[step.toolID]?.displayName ?? step.toolID
            let name = Bundle.main.localizedString(forKey: rawName, value: rawName, table: nil)
            return "\(index + 1). \(name)"
        }
    }

    static func bindingDescription(
        _ binding: SkillWorkflowBinding,
        parameters: [SkillParameterDefinition],
        steps: [SkillWorkflowStepV3]
    ) -> String {
        switch binding {
        case .userInput:
            return String(localized: "完整输入")
        case .parameter(let identifier):
            return parameters.first(where: { $0.id == identifier })?.name ?? String(localized: "已删除的参数")
        case .stepOutput(let identifier):
            guard let index = steps.firstIndex(where: { $0.id == identifier }) else {
                return String(localized: "未知步骤输出")
            }
            let rawName = ToolDescriptorCatalog.byIdentifier[steps[index].toolID]?.displayName ?? "步骤"
            let name = Bundle.main.localizedString(forKey: rawName, value: rawName, table: nil)
            return String(format: String(localized: "第 %lld 步 · %@"), index + 1, name)
        case .literal(let value):
            let text = value.displayText
            return text.isEmpty ? String(localized: "空内容") : String(text.prefix(48))
        case .template:
            return String(localized: "文本模板")
        case .array(let values):
            return String(format: String(localized: "%lld 项内容"), values.count)
        case .object(let values):
            return String(format: String(localized: "%lld 个字段"), values.count)
        }
    }
}

struct SkillEditorDraft {
    var skill: UserSkill
    var parameters: [SkillParameterDefinition]
    var workflow: SkillWorkflowDefinitionV3

    init(skill: UserSkill) {
        self.skill = skill
        parameters = skill.resolvedParameters
        workflow = skill.resolvedWorkflowV3
    }

    var invocationExample: String {
        let command = skill.registeredKeyword?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyValue ?? skill.name
        let arguments = parameters.map { parameter in
            let name = parameter.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = name.isEmpty ? parameter.type.displayName : name
            return parameter.required ? value : "[\(value)]"
        }
        return ([command] + arguments).joined(separator: " ")
    }

    func materialized() -> UserSkill {
        var value = skill
        value.parameters = parameters
        value.schemaVersion = SkillWorkflowDefinitionV3.currentVersion
        value.workflowV3 = workflow
        value.workflow = SkillWorkflowCompiler.compile(workflow, parameters: value.resolvedParameters)
        value.requiredTools = SkillWorkflowCompiler.toolIdentifiers(from: workflow)
        value.permissions = SkillWorkflowCompiler.permissions(from: workflow)
        value.actions = SkillWorkflowDescriber.actionLines(for: workflow)
        value.trigger = "用户输入 \(value.executionExample)"
        if let firstPrompt = workflow.steps.first(where: { $0.toolID == "model.generateText" })?.promptTemplate {
            value.modelTask = SkillModelTask(
                tool: "model.generateText",
                promptTemplate: firstPrompt,
                inputVariables: value.resolvedParameters.map(\.id) + ["userInput"],
                providerPolicy: value.modelTask?.providerPolicy ?? "userDefault"
            )
        } else if !workflow.steps.contains(where: { $0.toolID == "model.generateText" }) {
            value.modelTask = nil
        }
        if var appleScript = value.appleScript {
            appleScript.argumentVariables = value.resolvedParameters.map(\.id)
            value.appleScript = appleScript
        }
        return value
    }
}

private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}
