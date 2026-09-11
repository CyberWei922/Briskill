import SwiftUI
import UniformTypeIdentifiers

struct SkillEditorView: View {
    @State private var draft: SkillEditorDraft
    @State private var expandedStepID: String?
    @State private var editorError: String?
    @State private var isScrolled = false
    @State private var showsAdvancedSource = false
    @State private var showsDiscardConfirmation = false
    @State private var pendingNavigation: PendingNavigation?
    @State private var originalFingerprint: String
    @State private var namesText: String
    @State private var draggedStepID: String?
    @State private var isEnabled: Bool

    let message: SkillManagementMessage?
    let onBack: () -> Void
    let canGoForward: Bool
    let goForward: () -> Void
    let onEnabledChange: (Bool) -> Bool
    let onSave: (UserSkill) -> Bool
    let onExport: (UserSkill) -> Void
    let onDelete: (UserSkill) -> Void
    let onDirtyChange: (Bool) -> Void

    private enum PendingNavigation {
        case back
        case forward
    }

    init(
        skill: UserSkill,
        message: SkillManagementMessage?,
        onBack: @escaping () -> Void,
        canGoForward: Bool,
        goForward: @escaping () -> Void,
        onEnabledChange: @escaping (Bool) -> Bool,
        onSave: @escaping (UserSkill) -> Bool,
        onExport: @escaping (UserSkill) -> Void,
        onDelete: @escaping (UserSkill) -> Void,
        onDirtyChange: @escaping (Bool) -> Void = { _ in }
    ) {
        let draft = SkillEditorDraft(skill: skill)
        _draft = State(initialValue: draft)
        _originalFingerprint = State(initialValue: Self.fingerprint(draft.materialized()))
        _namesText = State(initialValue: Self.namesText(for: skill))
        _draggedStepID = State(initialValue: nil)
        _isEnabled = State(initialValue: skill.isEnabled)
        self.message = message
        self.onBack = onBack
        self.canGoForward = canGoForward
        self.goForward = goForward
        self.onEnabledChange = onEnabledChange
        self.onSave = onSave
        self.onExport = onExport
        self.onDelete = onDelete
        self.onDirtyChange = onDirtyChange
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            ScrollView {
                LazyVStack(spacing: 14) {
                    invocationCard
                    workflowCard
                    descriptionCard
                    securityCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(Color.settingsPaneBackground)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, newValue in
                if isScrolled != newValue { isScrolled = newValue }
            }

            Divider()
            editorFooter
        }
        .background(Color.settingsPaneBackground)
        .sheet(isPresented: $showsAdvancedSource) {
            AdvancedWorkflowSourceView(
                definition: draft.workflow,
                validate: validateAdvancedDefinition,
                apply: { definition in
                    draft.workflow = definition
                    editorError = nil
                }
            )
        }
        .alert("放弃未保存的修改？", isPresented: $showsDiscardConfirmation) {
            Button("继续编辑", role: .cancel) {
                pendingNavigation = nil
            }
            Button("放弃修改", role: .destructive) {
                performPendingNavigation()
            }
        } message: {
            Text("这项技能已经发生变化，离开后尚未保存的内容会丢失。")
        }
        .onAppear(perform: publishDirtyState)
        .onChange(of: currentFingerprint) {
            publishDirtyState()
        }
        .onDisappear {
            onDirtyChange(false)
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 13) {
            SkillEditorNavigationControl(
                canGoBack: true,
                canGoForward: canGoForward,
                goBack: { requestNavigation(.back) },
                goForward: { requestNavigation(.forward) }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.skill.name.isEmpty ? "未命名技能" : draft.skill.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(draft.invocationExample)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("启用", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button {
                showsAdvancedSource = true
            } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看工作流源码")
        }
        .padding(.horizontal, 11)
        .frame(height: 58)
        .background(Color.settingsPaneBackground)
        .overlay(alignment: .bottom) {
            if isScrolled { Divider().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.12), value: isScrolled)
    }

    private var invocationCard: some View {
        SkillEditorCard {
            VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("名称")
                            .font(.system(size: 11.5))
                            .padding(.top, 8)
                        Spacer(minLength: 12)
                        TextField("每行填写一个名称", text: $namesText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1...6)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(width: 260, alignment: .leading)
                            .background(
                                Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                            }
                    }
                    .onChange(of: namesText) { updateNamesFromText() }

                    SkillEditorDivider()

                    SkillEditorLabeledRow(title: "索引") {
                        TextField("例如 exp", text: keywordBinding)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .frame(width: 260, height: 30)
                            .background(
                                Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                            }
                    }

                    SkillEditorDivider()

                    HStack(alignment: .center, spacing: 18) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("执行类型")
                            Text(draft.skill.resolvedExecutionMode.compactDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Picker("执行类型", selection: executionModeBinding) {
                            ForEach(SkillExecutionMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .fixedSize()
                    }

                    SkillEditorDivider()

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            Text("传入参数")
                                .font(.system(size: 11.5))
                            Spacer()
                            Button {
                                draft.parameters.append(.blank(index: draft.parameters.count + 1))
                            } label: {
                                Label("添加参数", systemImage: "plus")
                                    .font(.system(size: 10.5))
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .background(.regularMaterial, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
                            }
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        }

                        if draft.parameters.isEmpty {
                            Text("无参数")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                                .background(
                                    Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        } else {
                            VStack(spacing: 0) {
                                ForEach($draft.parameters) { $parameter in
                                    InvocationParameterRow(
                                        parameter: $parameter,
                                        remove: { removeParameter(parameter.id) }
                                    )
                                    if parameter.id != draft.parameters.last?.id {
                                        Divider().padding(.horizontal, 10)
                                    }
                                }
                            }
                            .background(
                                Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.7)
                            }
                        }
                    }
            }
        }
    }

    private var workflowCard: some View {
        SkillEditorCard {
            VStack(alignment: .leading, spacing: 12) {
                SkillEditorCardHeader(
                    title: "运行流程",
                    subtitle: nil,
                    trailing: nil
                )

                if draft.workflow.steps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.system(size: 23, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有运行步骤")
                            .font(.system(size: 12, weight: .semibold))
                        Text("添加一个工具后，技能才可以真正执行。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(draft.workflow.steps) { step in
                        let index = draft.workflow.steps.firstIndex(where: { $0.id == step.id }) ?? 0
                        WorkflowStepCard(
                            step: workflowStepBinding(step.id),
                            index: index,
                            totalSteps: draft.workflow.steps.count,
                            parameters: draft.parameters,
                            priorSteps: Array(draft.workflow.steps.prefix(index)),
                            allSteps: draft.workflow.steps,
                            isExpanded: Binding(
                                get: { expandedStepID == step.id },
                                set: { expandedStepID = $0 ? step.id : nil }
                            ),
                            appleScript: $draft.skill.appleScript,
                            draggedStepID: $draggedStepID,
                            moveUp: { moveStep(at: index, offset: -1) },
                            moveDown: { moveStep(at: index, offset: 1) },
                            reorder: reorderStep,
                            duplicate: { duplicateStep(at: index) },
                            delete: { deleteStep(at: index) }
                        )
                    }
                }

                AddWorkflowStepMenu(
                    mode: draft.skill.resolvedExecutionMode,
                    add: addStep
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var descriptionCard: some View {
        SkillEditorCard {
            VStack(alignment: .leading, spacing: 13) {
                SkillEditorCardHeader(
                    title: "输入与输出",
                    subtitle: nil,
                    trailing: nil
                )

                SkillEditorDivider()

                SkillEditorLabeledRow(title: "输入") {
                    TextField("说明会接收什么内容", text: $draft.skill.summary, axis: .vertical)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1...6)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(width: 430, alignment: .trailing)
                        .background(
                            Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                        }
                }

                SkillEditorDivider()

                SkillEditorLabeledRow(title: "输出") {
                    TextField("说明最终会得到什么结果", text: $draft.skill.output, axis: .vertical)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1...6)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(width: 430, alignment: .trailing)
                        .background(
                            Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                        }
                }
            }
        }
    }

    private var securityCard: some View {
        let issues = validationIssues
        let permissions = SkillWorkflowCompiler.permissions(from: draft.workflow)
        return SkillEditorCard {
            VStack(alignment: .leading, spacing: 10) {
                SkillEditorCardHeader(
                    title: "检查与权限",
                    subtitle: issues.contains(where: { $0.severity == .error })
                        ? "保存前需要处理问题"
                        : "工作流定义已通过检查；系统权限仍需单独授权",
                    trailing: issues.contains(where: { $0.severity == .error }) ? "无法保存" : "定义有效"
                )

                if !issues.contains(where: { $0.severity == .error }) {
                    Label(
                        "结构、参数和步骤顺序正确，可以保存。这不代表下列系统权限已经授权。",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                if permissions.isEmpty {
                    Label("不需要额外系统权限", systemImage: "checkmark.shield")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(permissions, id: \.self) { permission in
                                Text(permissionDisplayName(permission))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.055), in: Capsule())
                            }
                        }
                    }
                }

                ForEach(issues) { issue in
                    Label {
                        Text(LocalizedStringKey(issue.message))
                    } icon: {
                        Image(systemName: issue.severity == .error
                            ? "exclamationmark.triangle.fill"
                            : "exclamationmark.circle")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                }

                let inferredMode = SkillWorkflowCompiler.inferExecutionMode(from: draft.workflow)
                if !draft.workflow.steps.isEmpty,
                   inferredMode != draft.skill.resolvedExecutionMode {
                    HStack {
                        Text("当前步骤组合实际属于“\(inferredMode.displayName)”技能。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("改为\(inferredMode.displayName)") {
                            draft.skill.executionMode = inferredMode
                            editorError = nil
                        }
                        .controlSize(.small)
                    }
                }

                if draft.skill.containsAppleScript,
                   !draft.skill.hasValidAppleScriptRiskAcknowledgement {
                    Label("AppleScript 源码发生变化，需要在对应步骤中重新确认风险", systemImage: "hand.raised.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var editorFooter: some View {
        HStack {
            Button("删除", role: .destructive) { onDelete(draft.materialized()) }
            Button("导出…") { onExport(draft.materialized()) }
            Spacer()
            if let displayedMessage {
                Label(
                    displayedMessage.text,
                    systemImage: displayedMessage.isError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(displayedMessage.isError ? Color.red : Color.green)
                .lineLimit(1)
            }
            Button("保存修改", action: saveChanges)
                .buttonStyle(.borderedProminent)
                .disabled(validationIssues.contains(where: { $0.severity == .error }))
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(Color.settingsPaneBackground)
    }

    private var displayedMessage: SkillManagementMessage? {
        if let editorError { return SkillManagementMessage(text: editorError, isError: true) }
        return message
    }

    private var validationIssues: [SkillWorkflowValidationIssue] {
        let skill = draft.materialized()
        return SkillWorkflowValidator.validate(
            draft.workflow,
            parameters: draft.parameters,
            executionMode: skill.resolvedExecutionMode,
            modelTask: skill.modelTask,
            appleScript: skill.appleScript
        )
    }

    private var keywordBinding: Binding<String> {
        Binding(
            get: { draft.skill.registeredKeyword ?? "" },
            set: { draft.skill.registeredKeyword = $0 }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                let previousValue = isEnabled
                isEnabled = newValue
                if !onEnabledChange(newValue) {
                    isEnabled = previousValue
                }
            }
        )
    }

    private var executionModeBinding: Binding<SkillExecutionMode> {
        Binding(
            get: { draft.skill.resolvedExecutionMode },
            set: { mode in
                draft.skill.executionMode = mode
                editorError = nil
            }
        )
    }

    private func workflowStepBinding(_ identifier: String) -> Binding<SkillWorkflowStepV3> {
        Binding(
            get: {
                draft.workflow.steps.first(where: { $0.id == identifier })
                    ?? SkillWorkflowStepV3.blank(toolID: "clipboard.readText", index: 1)
            },
            set: { value in
                guard let index = draft.workflow.steps.firstIndex(where: { $0.id == identifier }) else { return }
                draft.workflow.steps[index] = value
                editorError = nil
            }
        )
    }

    private func removeParameter(_ identifier: String) {
        guard let parameter = draft.parameters.first(where: { $0.id == identifier }) else { return }
        let references = draft.workflow.steps.reduce(0) { count, step in
            let argumentReferences = step.arguments.values.reduce(0) {
                $0 + $1.referenceCount(
                    parameterID: identifier,
                    parameterName: parameter.name
                )
            }
            let promptReferences = step.promptTemplate?.skillPlaceholderReferenceCount(
                identifiers: [identifier, parameter.name]
            ) ?? 0
            return count + argumentReferences + promptReferences
        }
        guard references == 0 else {
            editorError = "这个参数仍被 \(references) 处工作流输入或提示词使用，请先修改对应引用"
            return
        }
        draft.parameters.removeAll { $0.id == identifier }
        draft.skill.modelTask?.inputVariables.removeAll {
            $0 == identifier || $0 == parameter.name
        }
        draft.skill.appleScript?.argumentVariables.removeAll {
            $0 == identifier || $0 == parameter.name
        }
        editorError = nil
    }

    private func addStep(_ descriptor: ToolDescriptor) {
        var step = SkillWorkflowStepV3.blank(
            toolID: descriptor.id,
            index: draft.workflow.steps.count + 1
        )
        let priorSteps = draft.workflow.steps
        for argument in descriptor.arguments where argument.required {
            step.arguments[argument.name] = suggestedBinding(
                for: argument,
                priorSteps: priorSteps
            )
        }
        if descriptor.id == "model.generateText" {
            step.promptTemplate = "根据用户要求处理以下内容。直接输出最终结果，不要添加无关前言。"
        }
        if descriptor.id == "automation.appleScript" {
            step.arguments["argv"] = .array(draft.parameters.map { .parameter($0.id) })
            if draft.skill.appleScript == nil {
                draft.skill.appleScript = SkillAppleScriptDefinition(
                    source: """
                    on run argv
                        return "AppleScript 已执行"
                    end run
                    """,
                    argumentVariables: draft.parameters.map(\.id),
                    targetApplications: [],
                    riskNotes: [],
                    acknowledgedSourceHash: nil
                )
            }
        }
        draft.workflow.steps.append(step)
        expandedStepID = step.id
        editorError = nil
    }

    private func suggestedBinding(
        for argument: ToolArgumentDescriptor,
        priorSteps: [SkillWorkflowStepV3]
    ) -> SkillWorkflowBinding {
        if argument.name == "input" {
            if let prior = priorSteps.last { return .stepOutput(prior.id) }
            if let parameter = draft.parameters.first(where: { $0.type == .text || $0.type == .paragraph }) {
                return .parameter(parameter.id)
            }
            return .userInput
        }
        if argument.type == "file" || argument.type == "folder" {
            if let parameter = draft.parameters.first(where: {
                argument.type == "folder" ? $0.type == .folder : $0.type.acceptsFiles
            }) {
                return .parameter(parameter.id)
            }
            if let prior = priorSteps.last { return .stepOutput(prior.id) }
            return .literal(.string(""))
        }
        if argument.type == "number" { return .literal(.integer(0)) }
        if argument.type == "boolean" { return .literal(.boolean(false)) }
        if argument.type == "array" { return .array([]) }
        if let prior = priorSteps.last { return .stepOutput(prior.id) }
        if let parameter = draft.parameters.first(where: { $0.type == .text || $0.type == .paragraph }) {
            return .parameter(parameter.id)
        }
        return .userInput
    }

    private func moveStep(at index: Int, offset: Int) {
        let destination = index + offset
        guard draft.workflow.steps.indices.contains(index),
              draft.workflow.steps.indices.contains(destination) else { return }
        let step = draft.workflow.steps.remove(at: index)
        draft.workflow.steps.insert(step, at: destination)
        editorError = nil
    }

    private func duplicateStep(at index: Int) {
        guard draft.workflow.steps.indices.contains(index) else { return }
        var copy = draft.workflow.steps[index]
        copy.id = "step_\(draft.workflow.steps.count + 1)_\(UUID().uuidString.prefix(6).lowercased())"
        copy.outputName = nil
        draft.workflow.steps.insert(copy, at: index + 1)
        expandedStepID = copy.id
        editorError = nil
    }

    private func reorderStep(_ sourceID: String, _ targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = draft.workflow.steps.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = draft.workflow.steps.firstIndex(where: { $0.id == targetID }) else { return }
        let step = draft.workflow.steps.remove(at: sourceIndex)
        draft.workflow.steps.insert(
            step,
            at: min(max(0, targetIndex), draft.workflow.steps.count)
        )
        editorError = nil
    }

    private func deleteStep(at index: Int) {
        guard draft.workflow.steps.indices.contains(index) else { return }
        let removed = draft.workflow.steps.remove(at: index)
        if removed.toolID == "automation.appleScript",
           !draft.workflow.steps.contains(where: { $0.toolID == "automation.appleScript" }) {
            draft.skill.appleScript = nil
        }
        if expandedStepID == removed.id { expandedStepID = nil }
        editorError = nil
    }

    private func validateAdvancedDefinition(
        _ definition: SkillWorkflowDefinitionV3
    ) -> [SkillWorkflowValidationIssue] {
        var candidate = draft
        candidate.workflow = definition
        let skill = candidate.materialized()
        return SkillWorkflowValidator.validate(
            definition,
            parameters: candidate.parameters,
            executionMode: skill.resolvedExecutionMode,
            modelTask: skill.modelTask,
            appleScript: skill.appleScript
        )
    }

    private func saveChanges() {
        let materialized = draft.materialized()
        do {
            try SkillWorkflowValidator.validateForSaving(
                draft.workflow,
                parameters: draft.parameters,
                executionMode: materialized.resolvedExecutionMode,
                modelTask: materialized.modelTask,
                appleScript: materialized.appleScript
            )
            if materialized.containsAppleScript,
               !materialized.hasValidAppleScriptRiskAcknowledgement {
                editorError = "请在 AppleScript 步骤中阅读源码并确认风险"
                return
            }
            var value = materialized
            value.isEnabled = isEnabled
            value.updatedAt = Date()
            editorError = nil
            if onSave(value) {
                guard let savedValue = SkillStore.shared.skills.first(where: { $0.id == value.id }) else {
                    editorError = "技能已写入，但无法从技能库读回最新内容"
                    return
                }
                let savedDraft = SkillEditorDraft(skill: savedValue)
                draft = savedDraft
                isEnabled = savedValue.isEnabled
                namesText = Self.namesText(for: savedValue)
                originalFingerprint = Self.fingerprint(savedDraft.materialized())
                onDirtyChange(false)
            }
        } catch {
            editorError = error.localizedDescription
        }
    }

    private var hasUnsavedChanges: Bool {
        currentFingerprint != originalFingerprint
    }

    private var currentFingerprint: String {
        Self.fingerprint(draft.materialized())
    }

    private func publishDirtyState() {
        onDirtyChange(hasUnsavedChanges)
    }

    private func requestNavigation(_ direction: PendingNavigation) {
        guard direction != .forward || canGoForward else { return }
        if hasUnsavedChanges {
            pendingNavigation = direction
            showsDiscardConfirmation = true
        } else {
            switch direction {
            case .back: onBack()
            case .forward: goForward()
            }
        }
    }

    private func performPendingNavigation() {
        defer { pendingNavigation = nil }
        switch pendingNavigation {
        case .back: onBack()
        case .forward: goForward()
        case nil: break
        }
    }

    private func permissionDisplayName(_ permission: String) -> String {
        switch permission {
        case "clipboard": String(localized: "剪贴板")
        case "accessibility": String(localized: "辅助功能")
        case "screen_recording": String(localized: "屏幕录制")
        case "user_selected_file": String(localized: "所选文件")
        case "user_selected_folder": String(localized: "所选文件夹")
        case "downloads_write": String(localized: "下载目录")
        case "process_information": String(localized: "进程信息")
        case "apple_events": String(localized: "自动化控制")
        case "cloud_api": String(localized: "云端模型")
        case "confirmation_required": String(localized: "执行前确认")
        case "risk_acknowledgement_required": String(localized: "脚本风险确认")
        default: permission
        }
    }

    private static func fingerprint(_ skill: UserSkill) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(skill).base64EncodedString()) ?? skill.id.uuidString
    }

    private static func namesText(for skill: UserSkill) -> String {
        ([skill.name] + skill.aliases).joined(separator: "\n")
    }

    private func updateNamesFromText() {
        let lines = namesText.components(separatedBy: .newlines)
        draft.skill.name = lines.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var seen = Set<String>()
        draft.skill.aliases = lines.dropFirst().compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let normalized = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(normalized).inserted else { return nil }
            return value
        }
    }
}

private struct SkillEditorNavigationControl: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            navigationButton("chevron.left", enabled: canGoBack, action: goBack)
            Divider().frame(height: 18)
            navigationButton("chevron.right", enabled: canGoForward, action: goForward)
        }
        .padding(4)
        .skillEditorNavigationGlass()
    }

    private func navigationButton(
        _ symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.24))
                .frame(width: 33, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct SkillEditorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.7)
            }
    }
}

private struct SkillEditorCardHeader: View {
    let title: String
    let subtitle: String?
    let trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12.5, weight: .semibold))
                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(LocalizedStringKey(trailing))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct SkillEditorLabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title))
            Spacer(minLength: 12)
            content
        }
        .font(.system(size: 11.5))
    }
}

private struct SkillEditorDivider: View {
    var body: some View {
        Divider().opacity(0.65)
    }
}

private struct InvocationParameterRow: View {
    @Binding var parameter: SkillParameterDefinition
    @State private var showsDetails = false
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: parameter.type.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                TextField("参数名称", text: $parameter.name)
                    .textFieldStyle(.plain)
                Picker("类型", selection: $parameter.type) {
                    ForEach(SkillParameterType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(width: 105)
                Toggle("必填", isOn: $parameter.required)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .fixedSize()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showsDetails.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(showsDetails ? Color.accentColor : .secondary)
                Button(action: remove) {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)

            if showsDetails {
                Divider().padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("用途、格式或示例", text: $parameter.description, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    Text("帮助生成器和使用者理解这个参数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
        }
    }
}

private struct WorkflowStepDragPreview: View {
    let index: Int
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(index + 1)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 23)
                .background(Color.primary.opacity(0.08), in: Circle())
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

private struct WorkflowStepDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedStepID: String?
    let reorder: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedStepID, sourceID != targetID else { return }
        withAnimation(.snappy(duration: 0.18)) {
            reorder(sourceID, targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedStepID = nil
        return true
    }
}

private struct WorkflowStepCard: View {
    @Binding var step: SkillWorkflowStepV3
    let index: Int
    let totalSteps: Int
    let parameters: [SkillParameterDefinition]
    let priorSteps: [SkillWorkflowStepV3]
    let allSteps: [SkillWorkflowStepV3]
    @Binding var isExpanded: Bool
    @Binding var appleScript: SkillAppleScriptDefinition?
    @Binding var draggedStepID: String?
    let moveUp: () -> Void
    let moveDown: () -> Void
    let reorder: (String, String) -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    private var descriptor: ToolDescriptor? {
        ToolDescriptorCatalog.byIdentifier[step.toolID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 13, height: 23)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggedStepID = step.id
                        return NSItemProvider(object: step.id as NSString)
                    } preview: {
                        WorkflowStepDragPreview(
                            index: index,
                            symbol: toolSymbol(step.toolID),
                            title: descriptor?.displayName ?? step.toolID,
                            subtitle: stepSummary
                        )
                    }

                Text("\(index + 1)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: 23)
                    .background(Color.primary.opacity(0.06), in: Circle())

                Image(systemName: toolSymbol(step.toolID))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(descriptor?.displayName ?? step.toolID))
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(stepSummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Menu {
                    Button("上移", systemImage: "arrow.up", action: moveUp)
                        .disabled(index == 0)
                    Button("下移", systemImage: "arrow.down", action: moveDown)
                        .disabled(index + 1 >= totalSteps)
                    Button("复制步骤", systemImage: "plus.square.on.square", action: duplicate)
                    Divider()
                    Button("删除步骤", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 25, height: 25)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .tint(.primary)
                .fixedSize()

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 25, height: 25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            }

            if isExpanded {
                SkillEditorDivider()
                    .padding(.vertical, 11)

                VStack(alignment: .leading, spacing: 12) {
                    if let descriptor {
                        ForEach(descriptor.arguments) { argument in
                            argumentEditor(argument)
                        }
                    }

                    if step.toolID == "model.generateText" {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("模型提示词")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Spacer()
                                Menu {
                                    Button("完整用户输入") { appendPromptVariable("userInput") }
                                    if !parameters.isEmpty {
                                        Section("用户参数") {
                                            ForEach(parameters) { parameter in
                                                Button(parameter.name) { appendPromptVariable(parameter.id) }
                                            }
                                        }
                                    }
                                    if !priorSteps.isEmpty {
                                        Section("步骤输出") {
                                            ForEach(priorSteps) { priorStep in
                                                Button {
                                                    appendPromptVariable(priorStep.outputName ?? priorStep.id)
                                                } label: {
                                                    Text(LocalizedStringKey(ToolDescriptorCatalog.byIdentifier[priorStep.toolID]?.displayName ?? priorStep.toolID))
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Label("插入变量", systemImage: "plus.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .tint(.primary)
                                .fixedSize()
                            }
                            TextEditor(text: promptBinding)
                                .font(.system(size: 10.5))
                                .frame(minHeight: 92)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text("提示词属于这个模型步骤；流程中存在多个模型步骤时可以分别设置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if step.toolID == "automation.appleScript" {
                        appleScriptEditor
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isExpanded ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.04), lineWidth: 0.8)
        }
        .onDrop(
            of: [UTType.text],
            delegate: WorkflowStepDropDelegate(
                targetID: step.id,
                draggedStepID: $draggedStepID,
                reorder: reorder
            )
        )
    }

    @ViewBuilder
    private func argumentEditor(_ argument: ToolArgumentDescriptor) -> some View {
        if step.arguments[argument.name] != nil {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(argument.summary)
                            .font(.system(size: 10.5, weight: .medium))
                        Text(argument.name)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !argument.required {
                        Button("移除") { step.arguments.removeValue(forKey: argument.name) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                WorkflowBindingEditor(
                    binding: argumentBinding(argument.name),
                    expectedType: argument.type,
                    parameters: parameters,
                    priorSteps: priorSteps
                )
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(argument.summary))
                        .font(.system(size: 10.5, weight: .medium))
                    Text(argument.required ? "必填输入尚未设置" : "可选输入")
                        .font(.caption)
                        .foregroundStyle(argument.required ? Color.red : Color.secondary)
                }
                Spacer()
                Button(argument.required ? "设置" : "添加") {
                    step.arguments[argument.name] = defaultBinding(for: argument.type)
                }
                .controlSize(.small)
            }
        }
    }

    private var appleScriptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AppleScript 源代码")
                .font(.system(size: 10.5, weight: .semibold))
            TextEditor(text: appleScriptSourceBinding)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if let appleScript {
                if !appleScript.targetApplications.isEmpty {
                    LabeledContent("目标应用", value: appleScript.targetApplications.joined(separator: "、"))
                        .font(.system(size: 10))
                }
                ForEach(appleScript.riskNotes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
            }

            Toggle(isOn: appleScriptAcknowledgementBinding) {
                Text("我已阅读这段 AppleScript，并知晓它可能操作其他应用或本地数据")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .toggleStyle(.checkbox)
        }
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { step.promptTemplate ?? "" },
            set: { step.promptTemplate = $0 }
        )
    }

    private func appendPromptVariable(_ identifier: String) {
        let token = "{{\(identifier)}}"
        let current = step.promptTemplate ?? ""
        if current.isEmpty {
            step.promptTemplate = token
        } else {
            step.promptTemplate = current + (current.last?.isWhitespace == true ? "" : " ") + token
        }
    }

    private var appleScriptSourceBinding: Binding<String> {
        Binding(
            get: { appleScript?.source ?? "" },
            set: { value in
                var definition = appleScript ?? SkillAppleScriptDefinition(
                    source: "",
                    argumentVariables: parameters.map(\.id),
                    targetApplications: [],
                    riskNotes: [],
                    acknowledgedSourceHash: nil
                )
                definition.source = value
                definition.invalidateAcknowledgement()
                let report = AppleScriptRiskAnalyzer.analyze(value)
                definition.targetApplications = report.targetApplications
                definition.riskNotes = report.notes
                appleScript = definition
            }
        )
    }

    private var appleScriptAcknowledgementBinding: Binding<Bool> {
        Binding(
            get: { appleScript?.hasValidRiskAcknowledgement == true },
            set: { accepted in
                guard var definition = appleScript else { return }
                if accepted {
                    definition.acknowledgeCurrentSource()
                } else {
                    definition.invalidateAcknowledgement()
                }
                appleScript = definition
            }
        )
    }

    private func argumentBinding(_ name: String) -> Binding<SkillWorkflowBinding> {
        Binding(
            get: { step.arguments[name] ?? .literal(.string("")) },
            set: { step.arguments[name] = $0 }
        )
    }

    private func defaultBinding(for type: String) -> SkillWorkflowBinding {
        switch type {
        case "number": .literal(.integer(0))
        case "boolean": .literal(.boolean(false))
        case "array": .array([])
        case "object": .object([:])
        default: .userInput
        }
    }

    private var stepSummary: String {
        guard !step.arguments.isEmpty else {
            let summary = descriptor?.summary ?? "没有输入参数"
            return Bundle.main.localizedString(forKey: summary, value: summary, table: nil)
        }
        let values = step.arguments.keys.sorted().compactMap { name -> String? in
            guard let binding = step.arguments[name] else { return nil }
            let value = SkillWorkflowDescriber.bindingDescription(
                binding,
                parameters: parameters,
                steps: allSteps
            )
            let rawLabel = descriptor?.arguments.first(where: { $0.name == name })?.summary ?? name
            let label = Bundle.main.localizedString(forKey: rawLabel, value: rawLabel, table: nil)
            return "\(label)：\(value)"
        }
        return values.joined(separator: " · ")
    }
}

private enum WorkflowBindingChoice: Hashable {
    case userInput
    case parameter(String)
    case stepOutput(String)
    case fixed
    case template
}

private struct WorkflowBindingEditor: View {
    @Binding var binding: SkillWorkflowBinding
    let expectedType: String
    let parameters: [SkillParameterDefinition]
    let priorSteps: [SkillWorkflowStepV3]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("来源")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Picker("来源", selection: choiceBinding) {
                    Text("完整用户输入").tag(WorkflowBindingChoice.userInput)
                    if !parameters.isEmpty {
                        Section("用户参数") {
                            ForEach(parameters) { parameter in
                                Text(parameter.name).tag(WorkflowBindingChoice.parameter(parameter.id))
                            }
                        }
                    }
                    if !priorSteps.isEmpty {
                        Section("步骤输出") {
                            ForEach(priorSteps) { step in
                                Text(LocalizedStringKey(ToolDescriptorCatalog.byIdentifier[step.toolID]?.displayName ?? step.toolID))
                                    .tag(WorkflowBindingChoice.stepOutput(step.id))
                            }
                        }
                    }
                    Text("固定内容").tag(WorkflowBindingChoice.fixed)
                    Text("文本模板").tag(WorkflowBindingChoice.template)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.primary)
                .fixedSize()
                Spacer()
            }

            bindingValueEditor
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var bindingValueEditor: some View {
        switch binding {
        case .literal(.boolean(let value)):
            Toggle("值", isOn: Binding(
                get: { value },
                set: { binding = .literal(.boolean($0)) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        case .literal:
            TextField("固定内容", text: literalTextBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5))
        case .template:
            TextField("可使用 {{变量}} 的文本模板", text: templateBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, design: .monospaced))
        case .array:
            WorkflowArrayBindingEditor(
                binding: $binding,
                parameters: parameters,
                priorSteps: priorSteps
            )
        case .object:
            Text("复杂对象可以在右上角的工作流源码中修改")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .userInput, .parameter, .stepOutput:
            EmptyView()
        }
    }

    private var choiceBinding: Binding<WorkflowBindingChoice> {
        Binding(
            get: {
                switch binding {
                case .userInput: .userInput
                case .parameter(let identifier): .parameter(identifier)
                case .stepOutput(let identifier): .stepOutput(identifier)
                case .template: .template
                case .literal, .array, .object: .fixed
                }
            },
            set: { choice in
                switch choice {
                case .userInput:
                    binding = .userInput
                case .parameter(let identifier):
                    binding = .parameter(identifier)
                case .stepOutput(let identifier):
                    binding = .stepOutput(identifier)
                case .fixed:
                    binding = defaultLiteral
                case .template:
                    binding = .template("")
                }
            }
        )
    }

    private var defaultLiteral: SkillWorkflowBinding {
        switch expectedType {
        case "number": .literal(.integer(0))
        case "boolean": .literal(.boolean(false))
        case "array": .array([])
        case "object": .object([:])
        default: .literal(.string(""))
        }
    }

    private var literalTextBinding: Binding<String> {
        Binding(
            get: {
                if case .literal(let value) = binding { return value.displayText }
                return ""
            },
            set: { value in
                if expectedType == "number", let integer = Int(value) {
                    binding = .literal(.integer(integer))
                } else if expectedType == "number", let number = Double(value) {
                    binding = .literal(.number(number))
                } else {
                    binding = .literal(.string(value))
                }
            }
        )
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: {
                if case .template(let value) = binding { return value }
                return ""
            },
            set: { binding = .template($0) }
        )
    }
}

private struct WorkflowArrayBindingEditor: View {
    @Binding var binding: SkillWorkflowBinding
    let parameters: [SkillParameterDefinition]
    let priorSteps: [SkillWorkflowStepV3]

    private var values: [SkillWorkflowBinding] {
        if case .array(let values) = binding { return values }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack {
                    Text(SkillWorkflowDescriber.bindingDescription(value, parameters: parameters, steps: priorSteps))
                        .font(.system(size: 9.5))
                    Spacer()
                    Button {
                        var next = values
                        next.remove(at: index)
                        binding = .array(next)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
            Menu {
                Button("完整用户输入") { append(.userInput) }
                ForEach(parameters) { parameter in
                    Button(parameter.name) { append(.parameter(parameter.id)) }
                }
                ForEach(priorSteps) { step in
                    Button("第 \((priorSteps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1) 步输出") {
                        append(.stepOutput(step.id))
                    }
                }
                Button("固定文字") { append(.literal(.string(""))) }
            } label: {
                Label("添加一项", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .tint(.primary)
            .fixedSize()
        }
    }

    private func append(_ value: SkillWorkflowBinding) {
        binding = .array(values + [value])
    }
}

private struct AddWorkflowStepMenu: View {
    let mode: SkillExecutionMode
    let add: (ToolDescriptor) -> Void

    private var descriptors: [ToolDescriptor] {
        ToolDescriptorCatalog.descriptors(for: mode)
    }

    private var categories: [String] {
        Array(Set(descriptors.map(\.category))).sorted()
    }

    var body: some View {
        Menu {
            ForEach(categories, id: \.self) { category in
                Menu(category) {
                    ForEach(descriptors.filter { $0.category == category }) { descriptor in
                        Button {
                            add(descriptor)
                        } label: {
                            Label(descriptor.displayName, systemImage: toolSymbol(descriptor.id))
                        }
                    }
                }
            }
        } label: {
            Label("添加运行步骤", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 13)
                .frame(height: 32)
        }
        .menuStyle(.borderlessButton)
        .tint(.primary)
        .fixedSize()
    }
}

private struct AdvancedWorkflowSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var errorMessage: String?
    @State private var validationIssues: [SkillWorkflowValidationIssue] = []

    let validate: (SkillWorkflowDefinitionV3) -> [SkillWorkflowValidationIssue]
    let apply: (SkillWorkflowDefinitionV3) -> Void

    init(
        definition: SkillWorkflowDefinitionV3,
        validate: @escaping (SkillWorkflowDefinitionV3) -> [SkillWorkflowValidationIssue],
        apply: @escaping (SkillWorkflowDefinitionV3) -> Void
    ) {
        _source = State(initialValue: Self.encode(definition))
        self.validate = validate
        self.apply = apply
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("工作流源码")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Skill V3 · 修改只会在验证并应用后生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("格式化", action: formatSource)
            }
            .padding(16)

            Divider()

            TextEditor(text: $source)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            } else if !validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validationIssues) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            Divider()

            HStack {
                Text("字段采用带 type 的显式绑定，不再依赖 $变量 或参数显示名称。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("验证并应用", action: validateAndApply)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 680, minHeight: 540)
        .background(Color.settingsPaneBackground)
    }

    private func formatSource() {
        do {
            let definition = try decode()
            source = Self.encode(definition)
            errorMessage = nil
        } catch {
            errorMessage = decodingMessage(error)
        }
    }

    private func validateAndApply() {
        do {
            let definition = try decode()
            let issues = validate(definition)
            validationIssues = issues
            guard !issues.contains(where: { $0.severity == .error }) else {
                errorMessage = nil
                return
            }
            apply(definition)
            dismiss()
        } catch {
            errorMessage = decodingMessage(error)
        }
    }

    private func decode() throws -> SkillWorkflowDefinitionV3 {
        guard let data = source.data(using: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(SkillWorkflowDefinitionV3.self, from: data)
    }

    private static func encode(_ definition: SkillWorkflowDefinitionV3) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(definition),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private func decodingMessage(_ error: Error) -> String {
        if let error = error as? DecodingError {
            switch error {
            case .keyNotFound(let key, let context):
                return "缺少字段 \(key.stringValue)：\(context.debugDescription)"
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                return "字段类型不正确：\(context.debugDescription)"
            case .dataCorrupted(let context):
                return "JSON 内容损坏：\(context.debugDescription)"
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}

private func toolSymbol(_ identifier: String) -> String {
    switch identifier {
    case "clipboard.readText", "clipboard.writeText": "clipboard"
    case "screen.captureRegion": "viewfinder"
    case "image.ocr": "text.viewfinder"
    case "file.readText": "doc.text"
    case "file.list": "folder"
    case "file.search": "magnifyingglass"
    case "file.rename": "pencil"
    case "file.createEmpty": "doc.badge.plus"
    case "file.trash": "trash"
    case "system.snapshot": "gauge.with.dots.needle.67percent"
    case "automation.appleScript": "applescript"
    case "model.generateText": "sparkles"
    default: "gearshape.2"
    }
}

private extension SkillWorkflowBinding {
    func referenceCount(parameterID: String, parameterName: String) -> Int {
        switch self {
        case .parameter(let identifier):
            identifier == parameterID ? 1 : 0
        case .template(let value):
            value.skillPlaceholderReferenceCount(
                identifiers: [parameterID, parameterName]
            )
        case .array(let values):
            values.reduce(0) {
                $0 + $1.referenceCount(
                    parameterID: parameterID,
                    parameterName: parameterName
                )
            }
        case .object(let values):
            values.values.reduce(0) {
                $0 + $1.referenceCount(
                    parameterID: parameterID,
                    parameterName: parameterName
                )
            }
        case .userInput, .stepOutput, .literal:
            0
        }
    }
}

private extension String {
    func skillPlaceholderReferenceCount(identifiers: [String]) -> Int {
        Set(identifiers.filter { !$0.isEmpty }).reduce(0) { result, identifier in
            let token = "{{\(identifier)}}"
            return result + components(separatedBy: token).count - 1
        }
    }
}

private extension View {
    @ViewBuilder
    func skillEditorNavigationGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
        }
    }
}
