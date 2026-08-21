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
                SettingsWindowDragRegion()
                    .frame(height: 58)

                ScrollView {
                    LazyVStack(spacing: 3) {
                    ForEach(SettingsSection.allCases) { section in
                            SettingsSidebarRow(
                                section: section,
                                isSelected: selection == section,
                                accentColor: accentColor
                            ) {
                                selection = section
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 214)
            .settingsSidebarGlass()

            SettingsSplitSeam()

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
        case .privacy: PrivacySettingsView()
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
                                        .overlay {
                                            if accent == .system {
                                                Circle()
                                                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
                                            }
                                        }
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

}

private struct PrivacySettingsView: View {
    @ObservedObject private var permissions = PrivacyPermissionCenter.shared
    @ObservedObject private var locations = AuthorizedLocationStore.shared
    @ObservedObject private var aiSettings = AISettingsStore.shared

    @State private var message: String?
    @State private var messageIsError = false
    @State private var permissionMessage: String?
    @State private var permissionMessageIsError = false
    @State private var confirmsLocalStorage = false

    var body: some View {
        Form {
            Section("系统权限") {
                PermissionSettingsRow(
                    title: "辅助功能",
                    detail: "读取和替换其他应用中由你主动选中的文字",
                    symbol: "accessibility",
                    granted: permissions.accessibilityGranted,
                    actionTitle: permissions.accessibilityGranted ? "管理…" : "请求授权"
                ) {
                    if permissions.accessibilityGranted {
                        permissions.openAccessibilitySettings()
                    } else {
                        permissions.requestAccessibility()
                    }
                }

                PermissionSettingsRow(
                    title: "屏幕录制",
                    detail: "仅在运行区域截图技能时读取你框选的屏幕范围",
                    symbol: "rectangle.dashed",
                    granted: permissions.screenRecordingGranted,
                    actionTitle: permissions.screenRecordingGranted ? "管理…" : "请求授权"
                ) {
                    if permissions.screenRecordingGranted {
                        permissions.openScreenRecordingSettings()
                    } else {
                        permissions.requestScreenRecording()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("文件与文件夹")
                            Text("通过原生选择器逐个保存可访问位置；不会获得整个磁盘权限")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(locations.locations.isEmpty ? "按需选择" : "已保存 \(locations.locations.count) 个位置")
                            .font(.caption)
                            .foregroundStyle(locations.locations.isEmpty ? Color.secondary : Color.green)
                        Button("添加位置…", action: chooseAuthorizedLocations)
                    }

                    ForEach(locations.locations) { location in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(location.displayName)
                                Text(location.originalPath)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                locations.remove(location)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("移除这个持久访问位置")
                        }
                        .padding(.leading, 32)
                    }
                }
                .padding(.vertical, 3)

                Text("授权状态由 macOS 管理并通常会跨重启保留；你可以随时在系统设置中撤销。应用更新、签名或安装位置变化时，系统可能要求重新授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let permissionMessage {
                    Label(
                        permissionMessage,
                        systemImage: permissionMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(permissionMessageIsError ? Color.red : Color.green)
                }
            }

            Section("API Key 保存位置") {
                Picker("保存方式", selection: storageModeBinding) {
                    ForEach(APIKeyStorageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(aiSettings.apiKeyStorageMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if aiSettings.apiKeyStorageMode == .localFile {
                    LabeledContent("本地文件") {
                        Text(aiSettings.localAPIKeyFileURL?.path ?? "保存第一个密钥后创建")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("在 Finder 中显示") {
                        revealLocalAPIKeyFile()
                    }
                    .disabled(!localAPIKeyFileExists)
                    Text("本地模式使用 0600 文件权限，仅允许当前 macOS 用户读取，但密钥仍是可查看的明文；不要把该文件同步、分享或加入 Git。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(messageIsError ? Color.red : Color.green)
                }
            }

            Section("无需单独授权") {
                LabeledContent("剪贴板", value: "只在运行对应技能时访问")
                LabeledContent("Apple Vision OCR", value: "图片识别完全在本机运行")
                LabeledContent("系统状态", value: "仅读取本机公开诊断信息")
                LabeledContent("网络请求", value: "仅云端 AI 技能使用")
            }

            Section("本地数据") {
                Label("自定义技能、生成记录和调用历史保存在 Application Support", systemImage: "externaldrive.fill")
                Label("创建技能时不会自动上传真实文件、截图或剪贴板内容", systemImage: "checkmark.shield")
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .confirmationDialog(
            "改用本地可查看文件？",
            isPresented: $confirmsLocalStorage,
            titleVisibility: .visible
        ) {
            Button("迁移并使用本地文件") {
                changeStorageMode(to: .localFile)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现有 API Key 会从钥匙串迁移到仅当前用户可读的 JSON 文件。该方式便于再次查看，但安全性低于钥匙串。")
        }
    }

    private var storageModeBinding: Binding<APIKeyStorageMode> {
        Binding(
            get: { aiSettings.apiKeyStorageMode },
            set: { newMode in
                if newMode == .localFile {
                    confirmsLocalStorage = true
                } else {
                    changeStorageMode(to: newMode)
                }
            }
        )
    }

    private func changeStorageMode(to mode: APIKeyStorageMode) {
        do {
            try aiSettings.changeAPIKeyStorageMode(to: mode)
            message = "API Key 已迁移到\(mode.displayName)"
            messageIsError = false
        } catch {
            message = "迁移失败：\(error.localizedDescription)"
            messageIsError = true
        }
    }

    private func chooseAuthorizedLocations() {
        let panel = NSOpenPanel()
        panel.title = "添加 Local Assistant 可访问的位置"
        panel.message = "选择的文件夹会通过系统安全书签保存，供文件搜索和整理技能在以后继续使用。"
        panel.prompt = "授权此位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            do {
                for url in panel.urls {
                    try locations.add(url)
                }
                permissionMessage = "已保存 \(panel.urls.count) 个文件访问位置"
                permissionMessageIsError = false
            } catch {
                permissionMessage = "文件授权保存失败：\(error.localizedDescription)"
                permissionMessageIsError = true
            }
        }
    }

    private func revealLocalAPIKeyFile() {
        guard let url = aiSettings.localAPIKeyFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private var localAPIKeyFileExists: Bool {
        guard let url = aiSettings.localAPIKeyFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(granted ? "已授权" : "未授权", systemImage: granted ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Button(actionTitle, action: action)
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsSplitSeam: View {
    var body: some View {
        ZStack {
            // The settings window itself is transparent so Liquid Glass can sample
            // the desktop. Give the split gutter an opaque backing; otherwise the
            // translucent system Divider exposes a one-pixel strip behind the app.
            Color(nsColor: .windowBackgroundColor)

            Color.primary.opacity(0.12)
                .frame(width: 0.5)
        }
        .frame(width: 1)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

private struct SettingsWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
                .background(
                    isSelected ? accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        skill.registeredKeyword = skill.registeredKeyword?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard skill.registeredKeyword?.isEmpty == false else {
            message = SkillManagementMessage(text: "唯一索引不能为空", isError: true)
            return
        }
        if let keyword = skill.registeredKeyword {
            skill.aliases.removeAll { $0.compare(keyword, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if let originalSkill = skillStore.skills.first(where: { $0.id == skill.id }) {
            skill = migratingParameterReferences(from: originalSkill, to: skill)
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
        skill.trigger = "用户输入 \(skill.executionExample)"
        skill.updatedAt = Date()
        do {
            try skillStore.save(skill)
            message = SkillManagementMessage(text: "已保存", isError: false)
        } catch {
            message = SkillManagementMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func migratingParameterReferences(from original: UserSkill, to edited: UserSkill) -> UserSkill {
        let originalNames = Dictionary(uniqueKeysWithValues: original.resolvedParameters.map { ($0.id, $0.name) })
        let replacements = edited.resolvedParameters.reduce(into: [String: String]()) { result, parameter in
            guard let oldName = originalNames[parameter.id], oldName != parameter.name else { return }
            result[oldName] = parameter.name
        }
        guard !replacements.isEmpty else { return edited }

        var migrated = edited
        if var modelTask = migrated.modelTask {
            modelTask.promptTemplate = modelTask.promptTemplate
                .replacingSkillParameterPlaceholders(replacements)
            modelTask.inputVariables = modelTask.inputVariables.map { replacements[$0] ?? $0 }
            migrated.modelTask = modelTask
        }
        migrated.workflow = migrated.workflow?.map { step in
            var migratedStep = step
            migratedStep.arguments = step.arguments.mapValues {
                $0.replacingParameterReferences(replacements)
            }
            return migratedStep
        }
        return migrated
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
                Text(skill.executionExample)
                    .lineLimit(1)
                    .font(.system(size: 9.5, design: .monospaced))
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
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                if isFormScrolled {
                    Divider()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isFormScrolled)

            Form {
                Section("调用") {
                    LabeledContent("调用方式") {
                        Text(skill.executionExample)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    TextField("唯一索引", text: registeredKeywordBinding)
                        .textFieldStyle(.plain)
                    TextField("搜索别名，用逗号分隔", text: aliasesBinding)
                        .textFieldStyle(.plain)
                    Picker("执行模式", selection: executionModeBinding) {
                        ForEach(SkillExecutionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    TextField("触发说明", text: $skill.trigger)
                        .textFieldStyle(.plain)
                }

                Section("说明") {
                    TextField("技能摘要", text: $skill.summary, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                    TextField("输出形式和内容", text: $skill.output, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                }

                Section("执行步骤") {
                    TextEditor(text: actionsBinding)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(minHeight: 82)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
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
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
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
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
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
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var aliasesBinding: Binding<String> {
        Binding(
            get: {
                skill.aliases
                    .filter { alias in
                        guard let keyword = skill.registeredKeyword else { return true }
                        return alias.compare(keyword, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
                    }
                    .joined(separator: ", ")
            },
            set: { value in
                skill.aliases = value
                    .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var registeredKeywordBinding: Binding<String> {
        Binding(
            get: { skill.registeredKeyword ?? "" },
            set: { skill.registeredKeyword = $0 }
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
                    .textFieldStyle(.plain)
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
                .textFieldStyle(.plain)
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
    @State private var revealsAPIKey = false
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
                HStack {
                    if settings.apiKeyStorageMode == .localFile, revealsAPIKey {
                        TextField("API Key", text: $apiKey)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKey)
                    }
                    if settings.apiKeyStorageMode == .localFile {
                        Button {
                            revealsAPIKey.toggle()
                        } label: {
                            Image(systemName: revealsAPIKey ? "eye.slash" : "eye")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(revealsAPIKey ? "隐藏 API Key" : "显示 API Key")
                    }
                }
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
                        Text(settings.apiKeyStorageMode == .keychain
                             ? "密钥保存在这台 Mac 的钥匙串，不会写进工程或配置文件。"
                             : "密钥保存在本机 Application Support，可点击眼睛再次查看；不会写进工程目录。")
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
        revealsAPIKey = false
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
