import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("preferredAppearance") private var preferredAppearance = "system"

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }

            appearanceSettings
                .tabItem { Label("外观", systemImage: "paintbrush") }

            AIProviderSettingsView()
                .tabItem { Label("AI 服务", systemImage: "sparkles") }

            modelSettings
                .tabItem { Label("本地模型", systemImage: "cpu") }

            privacySettings
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .padding(20)
        .frame(width: 720, height: 560)
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
            Section {
                Text("全局快捷键已经生效；登录启动和菜单栏开关将在后续版本连接系统设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            Section("主题") {
                Picker("外观", selection: $preferredAppearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("主面板") {
                LabeledContent("尺寸", value: "紧凑")
                LabeledContent("透明效果", value: "系统材质")
                LabeledContent("失去焦点", value: "自动隐藏")
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
