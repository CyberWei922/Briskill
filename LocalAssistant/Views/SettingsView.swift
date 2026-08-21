import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("preferredAppearance") private var preferredAppearance = "system"
    @AppStorage("appAccent") private var appAccent = AppAccent.purple.rawValue
    @State private var selection: SettingsSection? = .general
    @State private var navigationHistory: [SettingsSection] = [.general]
    @State private var navigationIndex = 0
    @State private var isApplyingHistory = false
    @State private var isDetailScrolled = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 58)

                List(selection: $selection) {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 214)
            .settingsSidebarGlass()

            Divider()

            rightDetail
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 520)
        .tint(accentColor)
        .onAppear {
            AppAppearance.apply(preferredAppearance)
        }
        .onChange(of: preferredAppearance) { _, newValue in
            AppAppearance.apply(newValue)
        }
        .onChange(of: selection) {
            recordSelectionInHistory()
        }
    }

    private var currentSection: SettingsSection {
        selection ?? .general
    }

    private var accentColor: Color {
        AppAccent.resolve(appAccent).color
    }

    @ViewBuilder
    private var rightDetail: some View {
        if currentSection == .skills {
            SkillManagementView(
                canGoBack: navigationIndex > 0,
                canGoForward: navigationIndex + 1 < navigationHistory.count,
                goBack: { moveInHistory(by: -1) },
                goForward: { moveInHistory(by: 1) }
            )
        } else {
            VStack(spacing: 0) {
                SettingsPageHeader(
                    title: currentSection.title,
                    showsSeparator: isDetailScrolled,
                    canGoBack: navigationIndex > 0,
                    canGoForward: navigationIndex + 1 < navigationHistory.count,
                    goBack: { moveInHistory(by: -1) },
                    goForward: { moveInHistory(by: 1) }
                )

                settingsDetail
                    .trackSettingsScroll($isDetailScrolled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func recordSelectionInHistory() {
        isDetailScrolled = false
        guard !isApplyingHistory, let selection else { return }
        guard navigationHistory[navigationIndex] != selection else { return }
        if navigationIndex + 1 < navigationHistory.count {
            navigationHistory.removeSubrange((navigationIndex + 1)..<navigationHistory.count)
        }
        navigationHistory.append(selection)
        navigationIndex = navigationHistory.count - 1
    }

    private func moveInHistory(by offset: Int) {
        let target = navigationIndex + offset
        guard navigationHistory.indices.contains(target) else { return }
        isApplyingHistory = true
        navigationIndex = target
        selection = navigationHistory[target]
        DispatchQueue.main.async {
            isApplyingHistory = false
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch currentSection {
        case .general: generalSettings
        case .history: InvocationHistorySettingsView()
        case .aiServices: AIProviderSettingsView()
        case .localModel: modelSettings
        case .skills: EmptyView()
        case .privacy: privacySettings
        }
    }

    private var generalSettings: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
            }
            Section("快捷键") {
                LabeledContent("打开助手") {
                    HStack(spacing: 5) {
                        SettingsKeyCap("⌥")
                        SettingsKeyCap("Space")
                    }
                }
            }
            Section("外观") {
                Picker("外观", selection: $preferredAppearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)

                LabeledContent("主题色") {
                    HStack(spacing: 10) {
                        ForEach(AppAccent.allCases) { accent in
                            Button {
                                appAccent = accent.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(accent.color)
                                        .frame(width: 22, height: 22)
                                    if appAccent == accent.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(accent.displayName)
                        }
                    }
                }
            }
            Section("主面板") {
                LabeledContent("尺寸", value: "紧凑")
                LabeledContent("透明效果", value: "系统材质")
                LabeledContent("失去焦点", value: "自动隐藏")
            }
            Section {
                Text("全局快捷键已经生效；登录启动和菜单栏开关将在后续版本连接系统设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var modelSettings: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("本地模型将在下一阶段接入")
                .font(.headline)
            Text("当前版本已经可以使用 DeepSeek、GLM、Gemini 或 OpenAI 完成真实问答和技能草稿生成。本地模型管理仍保留为独立模块。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var privacySettings: some View {
        Form {
            Section("本地优先") {
                Label("API Key 保存在 macOS 钥匙串中", systemImage: "key.fill")
                Label("自定义技能保存在 Application Support", systemImage: "externaldrive.fill")
                Label("调用输入和结果历史保存在 Application Support，可单独删除或清空", systemImage: "clock.arrow.circlepath")
                Label("创建技能时不会上传真实文件、截图或剪贴板内容", systemImage: "checkmark.shield")
            }
            Section("未来权限") {
                LabeledContent("辅助功能", value: "未申请")
                LabeledContent("屏幕录制", value: "未申请")
                LabeledContent("文件访问", value: "未申请")
            }
        }
        .formStyle(.grouped)
    }
}

private extension View {
    @ViewBuilder
    func settingsSidebarGlass() -> some View {
        if #available(macOS 26.0, *) {
            background(.ultraThinMaterial)
                .glassEffect(.regular, in: Rectangle())
        } else {
            background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func settingsNavigationGlass() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
        }
    }

    func trackSettingsScroll(_ isScrolled: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 1
        } action: { _, newValue in
            if isScrolled.wrappedValue != newValue {
                isScrolled.wrappedValue = newValue
            }
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    var showsSeparator = false
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SettingsHistoryControl(
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                goBack: goBack,
                goForward: goForward
            )

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Spacer()
        }
        .offset(y: 3)
        .padding(.horizontal, 18)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Divider()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsSeparator)
    }
}

private struct SettingsHistoryControl: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canGoBack ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.24))
                    .frame(width: 33, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .help(canGoBack ? "后退" : "没有可后退的页面")

            Divider()
                .frame(height: 18)

            Button(action: goForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(canGoForward ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.24))
                    .frame(width: 33, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .help(canGoForward ? "前进" : "没有可前进的页面")
        }
        .padding(4)
        .settingsNavigationGlass()
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case history
    case aiServices
    case localModel
    case skills
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .history: "历史记录"
        case .aiServices: "AI 服务"
        case .localModel: "本地模型"
        case .skills: "技能管理"
        case .privacy: "隐私与权限"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .aiServices: "sparkles"
        case .localModel: "cpu"
        case .skills: "square.stack.3d.up"
        case .privacy: "hand.raised"
        }
    }
}

private struct SkillManagementView: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    @ObservedObject private var skillStore = SkillStore.shared
    @State private var editingSkillID: UUID?
    @State private var searchText = ""
    @State private var message: SkillManagementMessage?
    @State private var skillPendingDeletion: UserSkill?
    @State private var isLibraryScrolled = false
    @State private var forwardEditingSkillID: UUID?

    var body: some View {
        Group {
            if let skill = skillBeingEdited {
                SkillEditorView(
                    skill: skill,
                    message: message,
                    onBack: closeEditorForBack,
                    canGoForward: canGoForward,
                    goForward: goForward,
                    onSave: save,
                    onExport: export,
                    onDelete: { skillPendingDeletion = $0 }
                )
                .id(skill.id)
            } else {
                VStack(spacing: 0) {
                    SettingsPageHeader(
                        title: SettingsSection.skills.title,
                        showsSeparator: isLibraryScrolled,
                        canGoBack: canGoBack,
                        canGoForward: forwardEditingSkillID != nil || canGoForward,
                        goBack: goBack,
                        goForward: moveForwardFromLibrary
                    )
                    skillLibrary
                }
            }
        }
        .onChange(of: skillStore.skills.map(\.id)) {
            if let editingSkillID,
               !skillStore.skills.contains(where: { $0.id == editingSkillID }) {
                self.editingSkillID = nil
            }
            if let forwardEditingSkillID,
               !skillStore.skills.contains(where: { $0.id == forwardEditingSkillID }) {
                self.forwardEditingSkillID = nil
            }
        }
        .alert(
            "删除技能？",
            isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
            ),
            presenting: skillPendingDeletion
        ) { skill in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { delete(skill) }
        } message: { skill in
            Text("“\(skill.name)”会从本机永久删除。你可以先导出备份。")
        }
    }

    private var skillLibrary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索技能", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if filteredSkills.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "还没有技能" : "没有匹配的技能",
                    systemImage: searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "创建第一个技能后，它会出现在这里。" : "尝试搜索名称、关键词或说明。")
                )
            } else {
                List(filteredSkills) { skill in
                    Button {
                        openEditor(for: skill)
                    } label: {
                        SkillManagementRow(skill: skill)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("编辑") { openEditor(for: skill) }
                        Button("导出…") { export(skill) }
                        Divider()
                        Button("删除", role: .destructive) { skillPendingDeletion = skill }
                    }
                }
                .listStyle(.inset)
                .trackSettingsScroll($isLibraryScrolled)
            }

            Divider()

            HStack {
                Button {
                    SkillCreatorWindowController.shared.show()
                } label: {
                    Label("创建技能", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                if let message {
                    Text(message.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(message.isError ? Color.red : Color.green)
                }

                Text("\(skillStore.skills.count) 项技能")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
        }
    }

    private var filteredSkills: [UserSkill] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skillStore.skills }
        return skillStore.skills.filter { skill in
            skill.searchTerms.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var skillBeingEdited: UserSkill? {
        guard let editingSkillID else { return nil }
        return skillStore.skills.first(where: { $0.id == editingSkillID })
    }

    private func openEditor(for skill: UserSkill) {
        editingSkillID = skill.id
        forwardEditingSkillID = nil
        message = nil
    }

    private func closeEditorForBack() {
        forwardEditingSkillID = editingSkillID
        editingSkillID = nil
        message = nil
    }

    private func moveForwardFromLibrary() {
        if let forwardEditingSkillID,
           skillStore.skills.contains(where: { $0.id == forwardEditingSkillID }) {
            editingSkillID = forwardEditingSkillID
            self.forwardEditingSkillID = nil
            message = nil
        } else {
            goForward()
        }
    }

    private func save(_ editedSkill: UserSkill) {
        var skill = editedSkill
        skill.name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skill.name.isEmpty else {
            message = SkillManagementMessage(text: "技能名称不能为空", isError: true)
            return
        }
        let parameterNames = skill.resolvedParameters.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parameterNames.allSatisfy({ !$0.isEmpty }) else {
            message = SkillManagementMessage(text: "参数名称不能为空", isError: true)
            return
        }
        guard Set(parameterNames).count == parameterNames.count else {
            message = SkillManagementMessage(text: "参数名称不能重复", isError: true)
            return
        }
        if skill.resolvedExecutionMode == .cloudAssisted {
            guard let prompt = skill.modelTask?.promptTemplate,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                message = SkillManagementMessage(text: "云端 AI 技能必须填写运行时提示词", isError: true)
                return
            }
            var inputVariables = parameterNames
            if prompt.contains("{{userInput}}") {
                inputVariables.append("userInput")
            }
            skill.modelTask?.inputVariables = Array(Set(inputVariables)).sorted()
            if !skill.requiredTools.contains("model.generateText") {
                skill.requiredTools.append("model.generateText")
            }
            if !skill.permissions.contains("cloud_api") {
                skill.permissions.append("cloud_api")
            }
        }
        skill.updatedAt = Date()
        do {
            try skillStore.save(skill)
            message = SkillManagementMessage(text: "已保存", isError: false)
        } catch {
            message = SkillManagementMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func delete(_ skill: UserSkill) {
        do {
            try skillStore.delete(skill)
            skillPendingDeletion = nil
            if editingSkillID == skill.id { editingSkillID = nil }
            if forwardEditingSkillID == skill.id { forwardEditingSkillID = nil }
            message = SkillManagementMessage(text: "已删除 \(skill.name)", isError: false)
        } catch {
            message = SkillManagementMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func export(_ skill: UserSkill) {
        let panel = NSSavePanel()
        panel.title = "导出技能"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(safeFilename(skill.name)).laskill"
        panel.allowedContentTypes = [UTType(filenameExtension: "laskill") ?? .json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try skillStore.exportPackageData(for: skill)
                try data.write(to: url, options: .atomic)
                message = SkillManagementMessage(text: "已导出 \(url.lastPathComponent)", isError: false)
                AppConsole.shared.success("技能已导出：\(url.path)", category: "SkillStore")
            } catch {
                message = SkillManagementMessage(text: "导出失败：\(error.localizedDescription)", isError: true)
                AppConsole.shared.error("技能导出失败：\(error.localizedDescription)", category: "SkillStore")
            }
        }
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "-").isEmpty ? "LocalAssistant-Skill" : components.joined(separator: "-")
    }
}

private struct SkillManagementRow: View {
    let skill: UserSkill

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: skill.resolvedExecutionMode == .localOnly ? "desktopcomputer" : "cloud")
                .foregroundStyle(skill.isEnabled ? Color.indigo : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .lineLimit(1)
                        .font(.system(size: 12, weight: .semibold))
                    if skill.isBuiltIn {
                        Text("内置技能")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.10), in: Capsule())
                    }
                }
                Text(skill.aliases.first ?? skill.summary)
                    .lineLimit(1)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(skill.isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SkillEditorView: View {
    @State private var skill: UserSkill
    @State private var isFormScrolled = false
    let message: SkillManagementMessage?
    let onBack: () -> Void
    let canGoForward: Bool
    let goForward: () -> Void
    let onSave: (UserSkill) -> Void
    let onExport: (UserSkill) -> Void
    let onDelete: (UserSkill) -> Void

    init(
        skill: UserSkill,
        message: SkillManagementMessage?,
        onBack: @escaping () -> Void,
        canGoForward: Bool,
        goForward: @escaping () -> Void,
        onSave: @escaping (UserSkill) -> Void,
        onExport: @escaping (UserSkill) -> Void,
        onDelete: @escaping (UserSkill) -> Void
    ) {
        _skill = State(initialValue: skill)
        self.message = message
        self.onBack = onBack
        self.canGoForward = canGoForward
        self.goForward = goForward
        self.onSave = onSave
        self.onExport = onExport
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SettingsHistoryControl(
                    canGoBack: true,
                    canGoForward: canGoForward,
                    goBack: onBack,
                    goForward: goForward
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        TextField("技能名称", text: $skill.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        if skill.isBuiltIn {
                            Text("内置技能")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.indigo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.10), in: Capsule())
                        }
                    }
                    Text("更新于 \(skill.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("启用", isOn: $skill.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .offset(y: 3)
            .padding(.horizontal, 18)
            .frame(height: 50)
            .overlay(alignment: .bottom) {
                if isFormScrolled {
                    Divider()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isFormScrolled)

            Form {
                Section("调用") {
                    TextField("关键词和别名，用逗号分隔", text: aliasesBinding)
                    Picker("执行模式", selection: executionModeBinding) {
                        ForEach(SkillExecutionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    TextField("触发说明", text: $skill.trigger)
                }

                Section("说明") {
                    TextField("技能摘要", text: $skill.summary, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("输出形式和内容", text: $skill.output, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("执行步骤") {
                    TextEditor(text: actionsBinding)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(minHeight: 82)
                    Text("每行代表一个步骤。底层工作流仍保留在技能文件中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("传入参数") {
                    if parametersBinding.wrappedValue.isEmpty {
                        Text("这个技能不需要运行时参数")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(parametersBinding) { $parameter in
                            SkillParameterEditorRow(parameter: $parameter) {
                                skill.parameters?.removeAll { $0.id == parameter.id }
                            }
                        }
                    }
                    Button {
                        var values = parametersBinding.wrappedValue
                        values.append(.blank(index: values.count + 1))
                        parametersBinding.wrappedValue = values
                    } label: {
                        Label("添加参数", systemImage: "plus")
                    }
                }

                if skill.resolvedExecutionMode == .cloudAssisted {
                    Section("运行时 AI 提示词") {
                        TextEditor(text: modelPromptBinding)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(minHeight: 100)
                        Text("参数使用 {{参数名称}} 引用。修改后请确认变量与上方参数一致。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("能力与权限") {
                    LabeledContent("工具", value: skill.requiredTools.isEmpty ? "无" : skill.requiredTools.joined(separator: "、"))
                    LabeledContent("权限", value: skill.permissions.isEmpty ? "无" : skill.permissions.joined(separator: "、"))
                    if !skill.resolvedParameters.isEmpty {
                        Text("导出文件会包含技能定义和提示词，但不会包含 API Key、生成历史或运行时传入的文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .trackSettingsScroll($isFormScrolled)

            Divider()

            HStack {
                Button("删除", role: .destructive) { onDelete(skill) }
                Button("导出…") { onExport(skill) }
                Spacer()
                if let message {
                    Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(message.isError ? Color.red : Color.green)
                        .lineLimit(1)
                }
                Button("保存修改") {
                    skill.updatedAt = Date()
                    onSave(skill)
                }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
        }
    }

    private var aliasesBinding: Binding<String> {
        Binding(
            get: { skill.aliases.joined(separator: ", ") },
            set: { value in
                skill.aliases = value
                    .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var executionModeBinding: Binding<SkillExecutionMode> {
        Binding(
            get: { skill.resolvedExecutionMode },
            set: { mode in
                skill.executionMode = mode
                switch mode {
                case .localOnly:
                    skill.modelTask = nil
                    skill.workflow?.removeAll { $0.tool.lowercased().hasPrefix("model.") }
                    skill.requiredTools.removeAll { $0.lowercased().hasPrefix("model.") }
                    skill.permissions.removeAll { $0 == "cloud_api" }
                    skill.dataDisclosure = []
                case .cloudAssisted:
                    if skill.modelTask == nil {
                        skill.modelTask = SkillModelTask(
                            tool: "model.generateText",
                            promptTemplate: skill.originalRequest + "\n\n用户本次输入：{{userInput}}",
                            inputVariables: skill.resolvedParameters.map(\.name),
                            providerPolicy: "userDefault"
                        )
                    }
                }
            }
        )
    }

    private var actionsBinding: Binding<String> {
        Binding(
            get: { skill.actions.joined(separator: "\n") },
            set: { value in
                skill.actions = value
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var parametersBinding: Binding<[SkillParameterDefinition]> {
        Binding(
            get: { skill.parameters ?? [] },
            set: { skill.parameters = $0 }
        )
    }

    private var modelPromptBinding: Binding<String> {
        Binding(
            get: { skill.modelTask?.promptTemplate ?? "" },
            set: { value in
                if skill.modelTask == nil {
                    skill.modelTask = SkillModelTask(
                        tool: "model.generateText",
                        promptTemplate: value,
                        inputVariables: skill.resolvedParameters.map(\.name),
                        providerPolicy: "userDefault"
                    )
                } else {
                    skill.modelTask?.promptTemplate = value
                }
            }
        )
    }
}

private struct SkillParameterEditorRow: View {
    @Binding var parameter: SkillParameterDefinition
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                TextField("参数名称", text: $parameter.name)
                Picker("类型", selection: $parameter.type) {
                    ForEach(SkillParameterType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Toggle("必填", isOn: $parameter.required)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            TextField("用途或格式说明", text: $parameter.description)
                .font(.system(size: 11))
        }
        .padding(.vertical, 4)
    }
}

private struct SkillManagementMessage {
    let text: String
    let isError: Bool
}

private struct AIProviderSettingsView: View {
    @ObservedObject private var settings = AISettingsStore.shared

    @State private var endpoint = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var isTesting = false
    @State private var status: ConnectionStatus?

    var body: some View {
        Form {
            Section("默认服务") {
                Picker("服务商", selection: $settings.selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Label(provider.displayName, systemImage: provider.symbol)
                            .tag(provider)
                    }
                }
                Text("普通问答和新技能生成会使用这里选择的服务。模型名称和地址都可以修改，不依赖写死的版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接配置") {
                SecureField("API Key", text: $apiKey)
                TextField("模型名称", text: $model)
                TextField("API 地址", text: $endpoint)
                    .font(.system(.body, design: .monospaced))

                if settings.selectedProvider == .gemini {
                    Link(
                        "在 Google AI Studio 获取 API Key",
                        destination: URL(string: "https://aistudio.google.com/apikey")!
                    )
                    Text("Google AI Pro 订阅与 Gemini API 项目、额度分别管理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    if let status {
                        Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(status.isError ? Color.red : Color.green)
                            .lineLimit(2)
                    } else {
                        Text("密钥只保存在这台 Mac 的钥匙串，不会写进工程或配置文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("恢复默认") {
                        let defaults = AIProviderConfiguration.defaults(for: settings.selectedProvider)
                        endpoint = defaults.endpoint
                        model = defaults.model
                        status = nil
                    }

                    Button {
                        testConnection()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 70)
                        } else {
                            Text("保存并测试")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSelectedProvider)
        .onChange(of: settings.selectedProvider) {
            loadSelectedProvider()
        }
    }

    private func loadSelectedProvider() {
        let configuration = settings.configuration(for: settings.selectedProvider)
        endpoint = configuration.endpoint
        model = configuration.model
        apiKey = settings.apiKey(for: settings.selectedProvider)
        status = nil
    }

    private func testConnection() {
        let provider = settings.selectedProvider
        let configuration = AIProviderConfiguration(
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            settings.update(configuration, for: provider)
            try settings.saveAPIKey(apiKey, for: provider)
        } catch {
            status = ConnectionStatus(text: error.localizedDescription, isError: true)
            return
        }

        isTesting = true
        status = nil
        Task {
            do {
                let reply = try await AIService.shared.testConnection(provider: provider)
                status = ConnectionStatus(text: "连接成功 · \(reply.prefix(40))", isError: false)
            } catch {
                status = ConnectionStatus(text: error.localizedDescription, isError: true)
            }
            isTesting = false
        }
    }
}

private struct ConnectionStatus {
    let text: String
    let isError: Bool
}

private struct SettingsKeyCap: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

#Preview {
    SettingsView()
}
