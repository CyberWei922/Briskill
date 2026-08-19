import SwiftUI

struct SettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("preferredAppearance") private var preferredAppearance = "system"

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            appearanceSettings
                .tabItem {
                    Label("外观", systemImage: "paintbrush")
                }

            modelSettings
                .tabItem {
                    Label("本地模型", systemImage: "cpu")
                }

            privacySettings
                .tabItem {
                    Label("隐私", systemImage: "hand.raised")
                }
        }
        .padding(20)
        .frame(width: 620, height: 460)
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
                Text("设置项目前仅用于展示，不会改变系统配置。")
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
            }
        }
        .formStyle(.grouped)
    }

    private var modelSettings: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("尚未连接本地模型")
                .font(.headline)
            Text("后续版本将在这里管理模型下载、内存占用和节能策略。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("选择模型…") {}
                .disabled(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var privacySettings: some View {
        Form {
            Section("本地优先") {
                Label("数据默认保留在这台 Mac 上", systemImage: "checkmark.shield")
                Label("尚未申请文件、剪贴板或屏幕权限", systemImage: "lock")
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

