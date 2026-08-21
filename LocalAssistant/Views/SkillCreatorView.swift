import AppKit
import SwiftUI

struct SkillCreatorView: View {
    @ObservedObject private var settings = AISettingsStore.shared
    @ObservedObject private var skillStore = SkillStore.shared
    @AppStorage("appAccent") private var appAccent = AppAccent.purple.rawValue

    @State private var executionMode: SkillExecutionMode = .localOnly
    @AppStorage("skillCreator.deepThinkingEnabled") private var deepThinkingEnabled = true
    @State private var mode: SkillCreationMode = .guided
    @State private var guidedStep = 0
    @State private var skillName = ""
    @State private var keyword = ""
    @State private var parameters: [SkillParameterDefinition] = []
    @State private var processText = ""
    @State private var outputText = "在助手面板显示，并复制到剪贴板"
    @State private var freeformText = ""
    @State private var draft: SkillDraft?
    @State private var generatedBy = ""
    @State private var generatedModel = ""
    @State private var message: CreatorMessage?
    @State private var phase: CreatorPhase = .editing
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID = UUID()
    @State private var generationStartedAt: Date?
    @State private var generationEndedAt: Date?
    @State private var reasoningText = ""
    @State private var streamedOutput = ""
    @State private var tokenUsage: GenerationTokenUsage?
    @State private var finishReason: String?
    @State private var currentGenerationRequest: SkillCreationRequest?
    @State private var currentGenerationUsesThinking = false
    @State private var generatedInputFingerprint: String?
    @State private var showHistory = false

    var body: some View {
        HSplitView {
            creatorColumn
                .frame(minWidth: 380, idealWidth: 430)

            previewColumn
                .frame(minWidth: 360, idealWidth: 470)
        }
        .background(.ultraThickMaterial)
        .tint(AppAccent.resolve(appAccent).color)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHistory = true
                } label: {
                    Label("生成历史", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    startNewPage()
                } label: {
                    Label("新建", systemImage: "plus")
                }

                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            GenerationHistoryView()
        }
        .onChange(of: inputFingerprint) {
            clearStaleResultIfNeeded()
        }
    }

    private var creatorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            CreationModePicker(selection: $mode)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .disabled(isGenerating)

            ExecutionModePicker(selection: $executionMode)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
                .disabled(isGenerating)

            Group {
                if mode == .guided {
                    guidedForm
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                } else {
                    freeformEditor
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(isGenerating)

            Divider()

            HStack {
                HStack(spacing: 6) {
                    Text("选择模型")
                    Picker("生成服务", selection: $settings.selectedProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(isGenerating)
                }
                .font(.system(size: 11, weight: .medium))

                Spacer()

                ThinkModeButton(isOn: $deepThinkingEnabled)
                    .disabled(isGenerating)

                Button {
                    performPrimaryAction()
                } label: {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .frame(width: 76, height: 30)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Text(primaryActionTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(
                                canGenerate ? Color.indigo : Color.primary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canPerformPrimaryAction || isGenerating)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private var guidedForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            GuidedStepHeader(currentStep: guidedStep) { step in
                guard step <= guidedStep || (step == guidedStep + 1 && guidedStepCanAdvance) else { return }
                guidedStep = step
            }

            Group {
                switch guidedStep {
                case 0:
                    GuidedIdentityStep(skillName: $skillName, keyword: $keyword)
                case 1:
                    ScrollView {
                        ParameterEditor(parameters: $parameters)
                    }
                    .scrollIndicators(parameters.count > 2 ? .automatic : .hidden)
                case 2:
                    LongTextEntry(
                        title: "处理过程",
                        placeholder: "说明拿到参数后要依次做什么。例如：识别图片中的文字，保留段落结构，再清理明显的识别错误。",
                        text: $processText
                    )
                default:
                    LongTextEntry(
                        title: "输出形式和内容",
                        placeholder: "例如：在面板显示识别结果，并提供复制按钮。",
                        text: $outputText
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if guidedStep > 0 {
                Button("上一步") {
                    guidedStep -= 1
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var freeformEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("描述你的需求")
                .font(.system(size: 13, weight: .semibold))

            TextEditor(text: $freeformText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 110, idealHeight: 130, maxHeight: 150)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if freeformText.isEmpty {
                        Text("例如：以后我输入“会议收尾”，就把当前选中的会议记录总结成待办，按优先级排序，然后复制到剪贴板。没有选中文字时提醒我先选择内容。")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(17)
                            .allowsHitTesting(false)
                    }
                }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("调用格式")
                    .font(.system(size: 13, weight: .semibold))

                TextField("注册关键词，例如 ocr", text: $keyword)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                ScrollView {
                    ParameterEditor(parameters: $parameters, compact: true)
                }
                .scrollIndicators(parameters.count > 2 ? .automatic : .hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var previewColumn: some View {
        if phase == .generating || phase == .cancelled || phase == .failed {
            GenerationProgressView(
                phase: phase,
                startedAt: generationStartedAt,
                endedAt: generationEndedAt,
                reasoning: reasoningText,
                streamedOutput: streamedOutput,
                usage: tokenUsage,
                estimatedTokens: estimatedTokenCount,
                thinkingEnabled: currentGenerationUsesThinking,
                provider: generatedBy.isEmpty ? settings.selectedProvider.displayName : generatedBy,
                model: generatedModel.isEmpty ? settings.configuration(for: settings.selectedProvider).model : generatedModel,
                message: message,
                onStop: stopGeneration,
                onRetry: generate
            )
        } else if let draft {
            SkillDraftPreview(
                draft: Binding(
                    get: { draft },
                    set: { self.draft = $0 }
                ),
                source: generatedBy,
                isSaving: false,
                message: message,
                onSave: saveDraft,
                onRegenerate: generate
            )
        } else {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("技能预览会出现在这里")
                        .font(.system(size: 15, weight: .semibold))
                    Text("你会在保存前看到执行步骤、需要的能力、权限和模型给出的自然语言解释。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }

                if let message {
                    CreatorMessageCard(message: message)
                        .frame(maxWidth: 340)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var request: SkillCreationRequest {
        SkillCreationRequest(
            executionMode: executionMode,
            mode: mode,
            skillName: skillName,
            keyword: keyword,
            parameters: parameters,
            processText: processText,
            outputText: outputText,
            freeformText: freeformText
        )
    }

    private var canGenerate: Bool {
        switch mode {
        case .guided:
            guidedStep == 3 && guidedStepCanAdvance
        case .freeform:
            !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && freeformText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        }
    }

    private var guidedStepCanAdvance: Bool {
        switch guidedStep {
        case 0:
            return !skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1:
            return parameters.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case 2:
            return !processText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canPerformPrimaryAction: Bool {
        mode == .guided && guidedStep < 3 ? guidedStepCanAdvance : canGenerate
    }

    private var primaryActionTitle: String {
        mode == .guided && guidedStep < 3 ? "下一步" : "生成草稿"
    }

    private func performPrimaryAction() {
        if let keywordValidationError {
            message = CreatorMessage(text: keywordValidationError, details: nil, isError: true)
            return
        }
        if mode == .guided && guidedStep < 3 {
            guard guidedStepCanAdvance else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                guidedStep += 1
            }
            return
        }
        generate()
    }

    private var isGenerating: Bool {
        phase == .generating
    }

    private var inputFingerprint: String {
        let parameterFingerprint = parameters.map {
            [$0.id, $0.name, $0.type.rawValue, String($0.required), $0.description].joined(separator: "|")
        }.joined(separator: "~")
        return [settings.selectedProvider.rawValue, executionMode.rawValue, String(deepThinkingEnabled), mode.rawValue, skillName, keyword, parameterFingerprint, processText, outputText, freeformText]
            .joined(separator: "\u{1F}")
    }

    private var estimatedTokenCount: Int {
        let inputCharacters = currentGenerationRequest?.naturalLanguageDescription.count ?? 0
        return max(0, (inputCharacters + reasoningText.count + streamedOutput.count + 2) / 3)
    }

    private func generate() {
        guard canGenerate else { return }
        if let keywordValidationError {
            message = CreatorMessage(text: keywordValidationError, details: nil, isError: true)
            return
        }
        generationTask?.cancel()

        let currentRequest = request
        let currentID = UUID()
        let provider = settings.selectedProvider
        let configuration = settings.configuration(for: provider)
        let shouldUseThinking = deepThinkingEnabled

        generationID = currentID
        currentGenerationRequest = currentRequest
        currentGenerationUsesThinking = shouldUseThinking
        generationStartedAt = Date()
        generationEndedAt = nil
        reasoningText = ""
        streamedOutput = ""
        tokenUsage = nil
        finishReason = nil
        draft = nil
        generatedBy = provider.displayName
        generatedModel = configuration.model
        message = nil
        phase = .generating

        AppConsole.shared.info(
            "开始生成技能；模式=\(currentRequest.mode.rawValue)，服务商=\(provider.displayName)，模型=\(configuration.model)，Think=\(shouldUseThinking ? "开启" : "关闭")",
            category: "SkillCreator"
        )

        generationTask = Task {
            do {
                if settings.isConfigured() {
                    let stream = AIService.shared.streamSkillDraft(
                        description: currentRequest.generationPrompt,
                        system: SkillGenerationService.systemPrompt(for: currentRequest.executionMode),
                        provider: provider,
                        thinkingEnabled: shouldUseThinking
                    )

                    for try await event in stream {
                        guard generationID == currentID else { return }
                        switch event {
                        case .reasoning(let text):
                            reasoningText += text
                        case .content(let text):
                            streamedOutput += text
                        case .usage(let usage):
                            tokenUsage = usage
                        case .finished(let reason):
                            finishReason = reason
                        }
                    }

                    try Task.checkCancellation()
                    guard generationID == currentID else { return }
                    guard !streamedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AIServiceError.emptyResponse("流式响应结束，但 content 为空；finish_reason=\(finishReason ?? "未知")")
                    }
                    var parsedDraft = try SkillGenerationService.shared.decodeDraft(
                        from: streamedOutput,
                        expectedExecutionMode: currentRequest.executionMode
                    )
                    parsedDraft.parameters = currentRequest.parameters
                    generationEndedAt = Date()
                    draft = parsedDraft
                    generatedInputFingerprint = inputFingerprint
                    phase = .preview
                    storeGenerationRecord(status: .completed, request: currentRequest, draft: parsedDraft, error: nil)
                    AppConsole.shared.success(
                        "技能生成完成：\(parsedDraft.name)；耗时=\(formattedGenerationDuration)；tokens=\(tokenUsage?.totalTokens ?? estimatedTokenCount)",
                        category: "SkillCreator"
                    )
                } else {
                    let localDraft = SkillDraft.localDraft(from: currentRequest)
                    generationEndedAt = Date()
                    draft = localDraft
                    generatedBy = "本地模板"
                    generatedInputFingerprint = inputFingerprint
                    phase = .preview
                    storeGenerationRecord(status: .completed, request: currentRequest, draft: localDraft, error: nil)
                    AppConsole.shared.warning("未配置 API，使用本地模板生成技能草稿", category: "SkillCreator")
                }
            } catch is CancellationError {
                guard generationID == currentID else { return }
                generationEndedAt = Date()
                phase = .cancelled
                message = CreatorMessage(text: "生成已由用户终止", details: nil, isError: false)
                storeGenerationRecord(status: .cancelled, request: currentRequest, draft: nil, error: nil)
            } catch {
                guard generationID == currentID else { return }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    generationEndedAt = Date()
                    phase = .cancelled
                    message = CreatorMessage(text: "生成已由用户终止", details: nil, isError: false)
                    storeGenerationRecord(status: .cancelled, request: currentRequest, draft: nil, error: nil)
                    return
                }
                generationEndedAt = Date()
                phase = .failed
                message = CreatorMessage(
                    text: "生成失败",
                    details: diagnosticDetails(for: error),
                    isError: true
                )
                storeGenerationRecord(status: .failed, request: currentRequest, draft: nil, error: error.localizedDescription)
                AppConsole.shared.error("技能生成失败：\(error.localizedDescription)", category: "SkillCreator")
            }
        }
    }

    private var keywordValidationError: String? {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "唯一索引不能为空" }
        guard !value.contains(where: \.isWhitespace), !value.hasPrefix("-") else {
            return "唯一索引不能包含空格，也不能以“-”开头"
        }
        let isDuplicate = skillStore.skills.contains { skill in
            guard let existing = skill.registeredKeyword else { return false }
            return existing.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return isDuplicate ? "唯一索引“\(value)”已被其他技能使用" : nil
    }

    private func stopGeneration() {
        guard isGenerating else { return }
        AppConsole.shared.warning("用户点击终止技能生成", category: "SkillCreator")
        generationTask?.cancel()
    }

    private func startNewPage() {
        if isGenerating, let currentGenerationRequest {
            generationTask?.cancel()
            generationEndedAt = Date()
            storeGenerationRecord(status: .cancelled, request: currentGenerationRequest, draft: nil, error: "用户新建了另一个技能")
        }
        generationID = UUID()
        generationTask = nil
        executionMode = .localOnly
        mode = .guided
        guidedStep = 0
        skillName = ""
        keyword = ""
        parameters = []
        processText = ""
        outputText = "在助手面板显示，并复制到剪贴板"
        freeformText = ""
        clearGenerationState()
        AppConsole.shared.info("已新建空白技能页面", category: "SkillCreator")
    }

    private func clearStaleResultIfNeeded() {
        guard !isGenerating,
              let generatedInputFingerprint,
              inputFingerprint != generatedInputFingerprint else { return }
        clearGenerationState()
        self.generatedInputFingerprint = nil
        AppConsole.shared.info("创建内容已修改，旧生成结果已从当前页面移除", category: "SkillCreator")
    }

    private func clearGenerationState() {
        draft = nil
        generatedBy = ""
        generatedModel = ""
        message = nil
        phase = .editing
        generationStartedAt = nil
        generationEndedAt = nil
        reasoningText = ""
        streamedOutput = ""
        tokenUsage = nil
        finishReason = nil
        currentGenerationRequest = nil
        currentGenerationUsesThinking = false
    }

    private func storeGenerationRecord(
        status: GenerationRecordStatus,
        request: SkillCreationRequest,
        draft: SkillDraft?,
        error: String?
    ) {
        guard let startedAt = generationStartedAt else { return }
        GenerationHistoryStore.shared.add(
            GenerationRecord(
                id: UUID(),
                startedAt: startedAt,
                endedAt: generationEndedAt ?? Date(),
                status: status,
                requestDescription: request.naturalLanguageDescription,
                mode: request.mode,
                executionMode: request.executionMode,
                provider: generatedBy.isEmpty ? settings.selectedProvider.displayName : generatedBy,
                model: generatedModel,
                reasoning: reasoningText,
                rawOutput: streamedOutput,
                draft: draft,
                usage: tokenUsage,
                estimatedTokens: estimatedTokenCount,
                errorMessage: error
            )
        )
    }

    private var formattedGenerationDuration: String {
        guard let generationStartedAt else { return "0.0 秒" }
        let end = generationEndedAt ?? Date()
        return String(format: "%.1f 秒", end.timeIntervalSince(generationStartedAt))
    }

    private func saveDraft() {
        guard let draft else { return }
        do {
            let skill = UserSkill(draft: draft, request: request, generatedBy: generatedBy)
            try skillStore.save(skill)
            message = CreatorMessage(
                text: "“\(skill.name)”已保存，现在可以在快捷面板中搜索。",
                details: nil,
                isError: false
            )
        } catch {
            message = CreatorMessage(
                text: "保存失败",
                details: error.localizedDescription,
                isError: true
            )
        }
    }

    private func diagnosticDetails(for error: Error) -> String {
        let provider = settings.selectedProvider.displayName
        let configuration = settings.configuration(for: settings.selectedProvider)
        return """
        \(error.localizedDescription)

        服务商：\(provider)
        模型：\(configuration.model)
        API 地址：\(configuration.endpoint)
        时间：\(Date().formatted(date: .numeric, time: .standard))
        """
    }
}

private enum CreatorPhase {
    case editing
    case generating
    case preview
    case cancelled
    case failed
}

private struct GenerationProgressView: View {
    let phase: CreatorPhase
    let startedAt: Date?
    let endedAt: Date?
    let reasoning: String
    let streamedOutput: String
    let usage: GenerationTokenUsage?
    let estimatedTokens: Int
    let thinkingEnabled: Bool
    let provider: String
    let model: String
    let message: CreatorMessage?
    let onStop: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.11))
                        .frame(width: 38, height: 38)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: phase == .generating)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(provider) · \(model)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if phase == .generating {
                    Button(role: .destructive, action: onStop) {
                        Label("终止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: onRetry) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(thinkingEnabled ? "模型思考过程" : "生成过程", systemImage: thinkingEnabled ? "brain.head.profile" : "text.append")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)

                            MarkdownContentView(
                                markdown: reasoningDisplayText,
                                baseFontSize: 12.5,
                                textColor: reasoning.isEmpty ? Color.secondary.opacity(0.55) : .primary,
                                blockSpacing: 8
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if !streamedOutput.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("正在组织技能定义", systemImage: "curlybraces")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                MarkdownCodeBlockView(
                                    code: streamedOutput,
                                    language: "json",
                                    fontSize: 10.5
                                )
                            }
                            .padding(14)
                            .background(Color.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        if let message {
                            CreatorMessageCard(message: message)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("generation-bottom")
                    }
                    .padding(20)
                }
                .onChange(of: reasoning.count + streamedOutput.count) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("generation-bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                HStack(spacing: 22) {
                    GenerationMetric(
                        symbol: "timer",
                        title: "已消耗时间",
                        value: elapsedText(at: context.date)
                    )
                    GenerationMetric(
                        symbol: "number",
                        title: usage == nil ? "预估 Token" : "实际 Token",
                        value: "\(usage?.totalTokens ?? estimatedTokens)"
                    )
                    if thinkingEnabled, let usage {
                        GenerationMetric(
                            symbol: "brain",
                            title: "思考 Token",
                            value: "\(usage.reasoningTokens)"
                        )
                    }
                    Spacer()
                    if phase == .generating {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(streamedOutput.isEmpty ? (thinkingEnabled ? "正在思考" : "正在生成") : "正在生成结构")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .frame(height: 64)
            }
        }
    }

    private var reasoningDisplayText: String {
        if !reasoning.isEmpty { return reasoning }
        if !thinkingEnabled {
            return switch phase {
            case .generating: "Think 深度思考未开启，模型正在直接生成技能定义…"
            case .cancelled: "生成已终止。"
            case .failed: "生成失败，没有可显示的过程信息。"
            default: ""
            }
        }
        return switch phase {
        case .generating: "正在等待 \(provider) 返回思考过程…"
        case .cancelled: "生成在收到思考内容前被终止。"
        case .failed: "模型没有返回可显示的思考过程。"
        default: ""
        }
    }

    private func elapsedText(at date: Date) -> String {
        guard let startedAt else { return "0.0 秒" }
        let end = endedAt ?? date
        return String(format: "%.1f 秒", max(0, end.timeIntervalSince(startedAt)))
    }

    private var statusTitle: String {
        switch phase {
        case .generating: "正在生成技能"
        case .cancelled: "生成已终止"
        case .failed: "生成失败"
        default: "生成技能"
        }
    }

    private var statusSymbol: String {
        switch phase {
        case .generating: "sparkles"
        case .cancelled: "stop.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "sparkles"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .generating: .indigo
        case .cancelled: .orange
        case .failed: .red
        default: .indigo
        }
    }
}

private struct CreationModePicker: View {
    @Binding var selection: SkillCreationMode

    var body: some View {
        HStack(spacing: 6) {
            modeButton(.guided, title: "引导模式", symbol: "list.bullet.rectangle")
            modeButton(.freeform, title: "自由模式", symbol: "text.alignleft")
        }
        .padding(5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func modeButton(
        _ mode: SkillCreationMode,
        title: String,
        symbol: String
    ) -> some View {
        let isSelected = selection == mode

        return Button {
            selection = mode
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isSelected ? Color.indigo : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ThinkModeButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text("深度思考")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    isOn ? Color.indigo : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isOn ? Color.indigo.opacity(0.7) : Color.primary.opacity(0.08))
                }
        }
        .buttonStyle(.plain)
        .help(isOn ? "关闭深度思考" : "开启深度思考")
    }
}

private struct GenerationMetric: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
        }
    }
}

private struct ExecutionModePicker: View {
    @Binding var selection: SkillExecutionMode

    var body: some View {
        HStack(spacing: 10) {
            modeButton(
                .localOnly,
                symbol: "desktopcomputer",
                detail: "工具、工作流与受控网络"
            )
            modeButton(
                .cloudAssisted,
                symbol: "cloud",
                detail: "本地工具 + 模型生成"
            )
        }
    }

    private func modeButton(
        _ mode: SkillExecutionMode,
        symbol: String,
        detail: String
    ) -> some View {
        let isSelected = selection == mode
        let accentColor: Color = isSelected ? .indigo : .secondary
        let iconBackground: Color = isSelected ? Color.indigo.opacity(0.08) : Color.primary.opacity(0.08)
        let cardBackground: Color = isSelected ? Color.indigo.opacity(0.075) : Color.primary.opacity(0.035)
        let borderColor: Color = isSelected ? Color.indigo.opacity(0.4) : Color.primary.opacity(0.06)

        return Button {
            selection = mode
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 25, height: 25)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.2 : 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct GuidedStepHeader: View {
    let currentStep: Int
    let select: (Int) -> Void

    private let titles = ["名称", "参数", "处理", "输出"]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    select(index)
                } label: {
                    HStack(spacing: 5) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .frame(width: 18, height: 18)
                            .background(index == currentStep ? Color.white.opacity(0.18) : Color.primary.opacity(0.07), in: Circle())
                        Text(titles[index])
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(index == currentStep ? Color.white : (index < currentStep ? Color.indigo : Color.secondary))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(index == currentStep ? Color.indigo : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct GuidedIdentityStep: View {
    @Binding var skillName: String
    @Binding var keyword: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("功能名称")
                    .font(.system(size: 13, weight: .semibold))
                TextField("例如：图片文字识别", text: $skillName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("注册关键词")
                    .font(.system(size: 13, weight: .semibold))
                TextField("例如：ocr", text: $keyword)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("以后在快捷面板输入这个关键词即可调用技能。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ParameterEditor: View {
    @Binding var parameters: [SkillParameterDefinition]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(compact ? "传入参数" : "运行时需要传入什么？")
                        .font(.system(size: 13, weight: .semibold))
                    if !compact {
                        Text(parameters.isEmpty ? "没有参数时，输入关键词就会立即执行。" : "文本可直接跟在关键词后；文件和图片可拖入、粘贴或选择。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button {
                    parameters.append(.blank(index: parameters.count + 1))
                } label: {
                    Label("添加参数", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if parameters.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "nosign")
                    Text("当前技能不接收参数")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 62)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach($parameters) { $parameter in
                        ParameterDefinitionRow(parameter: $parameter) {
                            parameters.removeAll { $0.id == parameter.id }
                        }
                    }
                }
            }
        }
    }
}

private struct ParameterDefinitionRow: View {
    @Binding var parameter: SkillParameterDefinition
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("参数名称", text: $parameter.name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Picker("类型", selection: $parameter.type) {
                    ForEach(SkillParameterType.allCases) { type in
                        Label(type.displayName, systemImage: type.symbol).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 104)

                Toggle("必填", isOn: $parameter.required)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))

                Button(action: remove) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除参数")
            }

            TextField("用途或格式说明（可选）", text: $parameter.description)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LongTextEntry: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 230)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct PromptField: View {
    let keyword: String
    let english: String
    let prompt: String
    @Binding var text: String
    var optional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(keyword)
                    .font(.system(size: 12.5, weight: .bold))
                Text(english)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                if optional {
                    Text("可选")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct SkillDraftPreview: View {
    @Binding var draft: SkillDraft
    let source: String
    let isSaving: Bool
    let message: CreatorMessage?
    let onSave: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("生成结果")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("技能名称", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 21, weight: .bold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(draft.resolvedExecutionMode.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            draft.resolvedExecutionMode == .localOnly
                                ? Color.green.opacity(0.11)
                                : Color.indigo.opacity(0.10),
                            in: Capsule()
                        )
                        .foregroundStyle(draft.resolvedExecutionMode == .localOnly ? Color.green : Color.indigo)
                    Text("由 \(source) 设计")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MarkdownContentView(
                        markdown: draft.summary,
                        baseFontSize: 13.5,
                        textColor: .secondary,
                        blockSpacing: 8
                    )

                    PreviewSection(title: "运行方式", symbol: "play.circle") {
                        Text(draft.trigger)
                        if let condition = draft.condition {
                            Label(condition, systemImage: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !draft.resolvedParameters.isEmpty {
                        PreviewSection(title: "传入参数", symbol: "curlybraces") {
                            ForEach(draft.resolvedParameters) { parameter in
                                HStack(spacing: 8) {
                                    Image(systemName: parameter.type.symbol)
                                        .foregroundStyle(.indigo)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(parameter.name)
                                            .font(.system(size: 11.5, weight: .semibold))
                                        if !parameter.description.isEmpty {
                                            Text(parameter.description)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text("\(parameter.type.displayName) · \(parameter.required ? "必填" : "可选")")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    PreviewSection(title: "执行步骤", symbol: "list.number") {
                        ForEach(Array(draft.actions.enumerated()), id: \.offset) { index, action in
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .frame(width: 20, height: 20)
                                    .background(Color.indigo.opacity(0.10), in: Circle())
                                Text(action)
                            }
                        }
                        Label(draft.output, systemImage: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                    }

                    if let workflow = draft.workflow, !workflow.isEmpty {
                        PreviewSection(title: "工具工作流", symbol: "point.3.connected.trianglepath.dotted") {
                            ForEach(Array(workflow.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(index + 1)")
                                        .foregroundStyle(.tertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(step.tool)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        if !step.arguments.isEmpty {
                                            Text(step.arguments.map { "\($0.key)=\($0.value.displayText)" }.sorted().joined(separator: " · "))
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let modelTask = draft.modelTask {
                        PreviewSection(title: "运行时 AI 提示词", symbol: "cloud") {
                            MarkdownCodeBlockView(
                                code: modelTask.promptTemplate,
                                language: "prompt",
                                fontSize: 11
                            )
                            Text("模型策略：\(modelTask.providerPolicy)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let hosts = draft.networkHosts, !hosts.isEmpty {
                        PreviewSection(title: "网络访问", symbol: "network") {
                            FlowTags(values: hosts, tint: .blue)
                        }
                    }

                    if let disclosure = draft.dataDisclosure, !disclosure.isEmpty {
                        PreviewSection(title: "数据发送范围", symbol: "arrow.up.forward.circle") {
                            ForEach(disclosure, id: \.self) { item in
                                Label(item, systemImage: "arrow.up.forward")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if !draft.requiredTools.isEmpty || !draft.permissions.isEmpty {
                        PreviewSection(title: "能力与权限", symbol: "checkmark.shield") {
                            FlowTags(values: draft.requiredTools, tint: .indigo)
                            FlowTags(values: draft.permissions, tint: .orange)
                        }
                    }

                    PreviewSection(title: "AI 的解释", symbol: "text.bubble") {
                        MarkdownContentView(
                            markdown: draft.explanation,
                            baseFontSize: 12.5,
                            textColor: .secondary,
                            blockSpacing: 8
                        )
                    }

                    if let message {
                        CreatorMessageCard(message: message)
                    }
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            Divider()

            HStack {
                Button("重新生成", action: onRegenerate)
                    .buttonStyle(.borderless)
                Spacer()
                Button(action: onSave) {
                    Label("保存技能", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}

private struct PreviewSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct FlowTags: View {
    let values: [String]
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values.prefix(4), id: \.self) { value in
                Text(value)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.10), in: Capsule())
                    .foregroundStyle(tint)
            }
        }
    }
}

private struct CreatorMessageCard: View {
    let message: CreatorMessage

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.isError ? Color.red : Color.green)

            if let details = message.details {
                Text(details)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(message.text)\n\(details)", forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制诊断信息", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (message.isError ? Color.red : Color.green).opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct CreatorMessage {
    let text: String
    let details: String?
    let isError: Bool
}

#Preview {
    SkillCreatorView()
        .frame(width: 920, height: 640)
}
