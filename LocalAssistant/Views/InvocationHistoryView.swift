import SwiftUI

struct InvocationHistorySettingsView: View {
    @ObservedObject private var history = InvocationHistoryStore.shared
    @State private var searchText = ""
    @State private var selectedRecord: InvocationRecord?
    @State private var recordPendingDeletion: InvocationRecord?
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索调用、技能或结果", text: $searchText)
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

            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "还没有调用记录" : "没有匹配的记录",
                    systemImage: searchText.isEmpty ? "clock.badge.questionmark" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "在悬浮窗运行问答或技能后，输入、结果和真实工具步骤会保存在这里。" : "尝试搜索输入内容、技能名称或执行结果。")
                )
            } else {
                List(filteredRecords) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        InvocationHistoryRow(record: record)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("查看详情") { selectedRecord = record }
                        Divider()
                        Button("删除", role: .destructive) { recordPendingDeletion = record }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("记录仅保存在这台 Mac 的 Application Support 中。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(history.records.count) 条记录")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Button("全部清空", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(history.records.isEmpty)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
        }
        .sheet(item: $selectedRecord) { record in
            InvocationHistoryDetail(record: record) {
                history.delete(record)
                selectedRecord = nil
            }
        }
        .alert(
            "删除这条调用记录？",
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            ),
            presenting: recordPendingDeletion
        ) { record in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                history.delete(record)
                recordPendingDeletion = nil
            }
        } message: { record in
            Text("“\(record.title)”的输入和结果会从本机历史中删除。")
        }
        .alert("清空全部调用历史？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) {}
            Button("全部清空", role: .destructive) { history.clear() }
        } message: {
            Text("这会永久删除全部 \(history.records.count) 条本地调用记录，技能和生成历史不会受影响。")
        }
    }

    private var filteredRecords: [InvocationRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.records }
        return history.records.filter { record in
            [record.input, record.title, record.source, record.result]
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || record.tools.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

private struct InvocationHistoryRow: View {
    let record: InvocationRecord

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(record.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(record.status.displayName)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                Text(record.input.isEmpty ? record.source : record.input)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.1f 秒", record.duration))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private var statusSymbol: String {
        switch record.status {
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }
}

private struct InvocationHistoryDetail: View {
    let record: InvocationRecord
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.system(size: 18, weight: .bold))
                    Text("\(record.source) · \(record.startedAt.formatted(date: .long, time: .standard))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.status.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    historySection("输入", symbol: "text.cursor") {
                        Text(record.input.isEmpty ? "无文字输入" : record.input)
                            .textSelection(.enabled)
                    }

                    if !record.tools.isEmpty {
                        historySection("实际执行工具", symbol: "wrench.and.screwdriver") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(record.tools.enumerated()), id: \.offset) { index, tool in
                                    Text("\(index + 1). \(tool)")
                                        .font(.system(size: 11, design: .monospaced))
                                }
                            }
                        }
                    }

                    historySection("结果", symbol: "text.alignleft") {
                        MarkdownContentView(markdown: record.result, baseFontSize: 12.5)
                    }

                    HStack(spacing: 18) {
                        LabeledContent("耗时", value: String(format: "%.1f 秒", record.duration))
                        LabeledContent("写入剪贴板", value: record.didWriteClipboard ? "是" : "否")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
                .padding(22)
            }

            Divider()

            HStack {
                Button("删除记录", role: .destructive, action: delete)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
        }
        .frame(width: 620, height: 540)
    }

    private func historySection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}
