import SwiftUI

struct ConsoleView: View {
    @ObservedObject private var console = AppConsole.shared

    @State private var searchText = ""
    @State private var selectedLevel: ConsoleLevel?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            logContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("清空全部 Console 历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                console.clear()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)

            TextField("搜索日志…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Picker("级别", selection: $selectedLevel) {
                Text("全部").tag(nil as ConsoleLevel?)
                ForEach(ConsoleLevel.allCases) { level in
                    Text(level.displayName).tag(level as ConsoleLevel?)
                }
            }
            .tint(.primary)
            .frame(width: 110)

            Text("\(filteredEntries.count) 条")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                console.copyAll()
            } label: {
                Label("复制全部", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("清空", systemImage: "trash")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredEntries.isEmpty {
                        ContentUnavailableView(
                            "没有匹配的日志",
                            systemImage: "terminal",
                            description: Text("应用操作、API 请求和错误会显示在这里。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 380)
                    } else {
                        ForEach(filteredEntries) { entry in
                            ConsoleEntryRow(entry: entry)
                                .id(entry.id)
                            Divider()
                                .opacity(0.35)
                        }
                    }
                }
            }
            .onChange(of: console.entries.count) {
                guard searchText.isEmpty, selectedLevel == nil,
                      let last = filteredEntries.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var filteredEntries: [ConsoleEntry] {
        console.entries.filter { entry in
            let matchesLevel = selectedLevel == nil || entry.level == selectedLevel
            let matchesSearch = searchText.isEmpty
                || entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
    }
}

private struct ConsoleEntryRow: View {
    let entry: ConsoleEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(levelColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 82, alignment: .leading)

            Text(entry.category)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 94, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    ConsoleView()
        .frame(width: 880, height: 560)
}
