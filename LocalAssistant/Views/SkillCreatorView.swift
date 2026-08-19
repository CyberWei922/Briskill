import AppKit
import SwiftUI

struct SkillCreatorView: View {
    @ObservedObject private var settings = AISettingsStore.shared
    @ObservedObject private var skillStore = SkillStore.shared

    @State private var mode: SkillCreationMode = .guided
    @State private var whenText = ""
    @State private var conditionText = ""
    @State private var actionText = ""
    @State private var otherwiseText = ""
    @State private var outputText = "在助手面板显示，并复制到剪贴板"
    @State private var freeformText = ""
    @State private var draft: SkillDraft?
    @State private var generatedBy = ""
    @State private var isGenerating = false
    @State private var message: CreatorMessage?

    var body: some View {
        HSplitView {
            creatorColumn
                .frame(minWidth: 380, idealWidth: 430)

            previewColumn
                .frame(minWidth: 360, idealWidth: 470)
        }
        .background(.ultraThickMaterial)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label(settings.isConfigured() ? settings.selectedProvider.shortName : "设置 AI", systemImage: "cpu")
                }
            }
        }
    }

    private var creatorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("把一句需求变成你的技能")
                    .font(.system(size: 22, weight: .bold))
                Text("描述触发时机、要做的事和结果形式。生成后先预览，再决定是否保存。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 18)

            Picker("创建模式", selection: $mode) {
                Text("引导模式").tag(SkillCreationMode.guided)
                Text("自由发挥").tag(SkillCreationMode.freeform)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .onChange(of: mode) {
                draft = nil
                message = nil
            }

            ScrollView {
                Group {
                    if mode == .guided {
                        guidedForm
                    } else {
                        freeformEditor
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.isConfigured() ? "由 \(settings.selectedProvider.displayName) 生成" : "未配置 API，将生成本地模板草稿")
                        .font(.system(size: 11, weight: .medium))
                    Text("不会在创建阶段上传真实文件、截图或剪贴板内容")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    generate()
                } label: {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 76)
                    } else {
                        Label("生成草稿", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canGenerate || isGenerating)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private var guidedForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            PromptField(
                keyword: "当",
                english: "WHEN",
                prompt: "什么时候运行？例如：我输入“会议收尾”时",
                text: $whenText
            )
            PromptField(
                keyword: "如果",
                english: "IF",
                prompt: "可选条件，例如：选中了文字",
                text: $conditionText,
                optional: true
            )
            PromptField(
                keyword: "就",
                english: "THEN",
                prompt: "要完成什么？例如：提取待办并按优先级排序",
                text: $actionText
            )
            PromptField(
                keyword: "否则",
                english: "ELSE",
                prompt: "条件不满足时怎么办？",
                text: $otherwiseText,
                optional: true
            )
            PromptField(
                keyword: "反馈",
                english: "OUTPUT",
                prompt: "结果如何交给你？",
                text: $outputText
            )
        }
    }

    private var freeformEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("直接描述完整需求")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("建议包含：何时、做什么、结果、反馈方式")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $freeformText)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 260)
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
        }
    }

    @ViewBuilder
    private var previewColumn: some View {
        if let draft {
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

                if !skillStore.skills.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已保存的技能")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(skillStore.skills.prefix(3)) { skill in
                            Label(skill.name, systemImage: "bolt.fill")
                                .font(.system(size: 12))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 300, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var request: SkillCreationRequest {
        SkillCreationRequest(
            mode: mode,
            whenText: whenText,
            conditionText: conditionText,
            actionText: actionText,
            otherwiseText: otherwiseText,
            outputText: outputText,
            freeformText: freeformText
        )
    }

    private var canGenerate: Bool {
        switch mode {
        case .guided: !actionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .freeform: freeformText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        }
    }

    private func generate() {
        guard canGenerate else { return }
        isGenerating = true
        message = nil
        let currentRequest = request

        Task {
            do {
                let result = try await SkillGenerationService.shared.generate(from: currentRequest)
                draft = result.draft
                generatedBy = result.source
            } catch {
                message = CreatorMessage(
                    text: "生成失败",
                    details: diagnosticDetails(for: error),
                    isError: true
                )
            }
            isGenerating = false
        }
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
                Text(source)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.indigo.opacity(0.10), in: Capsule())
                    .foregroundStyle(.indigo)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(draft.summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)

                    PreviewSection(title: "运行方式", symbol: "play.circle") {
                        Text(draft.trigger)
                        if let condition = draft.condition {
                            Label(condition, systemImage: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
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

                    if !draft.requiredTools.isEmpty || !draft.permissions.isEmpty {
                        PreviewSection(title: "能力与权限", symbol: "checkmark.shield") {
                            FlowTags(values: draft.requiredTools, tint: .indigo)
                            FlowTags(values: draft.permissions, tint: .orange)
                        }
                    }

                    PreviewSection(title: "AI 的解释", symbol: "text.bubble") {
                        Text(draft.explanation)
                            .foregroundStyle(.secondary)
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
