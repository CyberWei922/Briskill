import SwiftUI

struct GenerationHistoryView: View {
    @ObservedObject private var history = GenerationHistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("生成历史")
                        .font(.system(size: 19, weight: .bold))
                    Text("过程与结果只保存在这台 Mac 上")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !history.records.isEmpty {
                    Button("清空历史", role: .destructive) {
                        confirmClear = true
                    }
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if history.records.isEmpty {
                ContentUnavailableView(
                    "还没有生成记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("完成、终止或失败的技能生成都会保存在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(history.records, selection: $selection) { record in
                        HistoryRow(record: record)
                            .tag(record.id)
                    }
                    .frame(minWidth: 230, idealWidth: 260)

                    if let selectedRecord {
                        GenerationRecordDetail(record: selectedRecord)
                    } else {
                        ContentUnavailableView("选择一条记录", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: 820, height: 560)
        .onAppear {
            selection = history.records.first?.id
        }
        .confirmationDialog("清空全部生成历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                history.clear()
                selection = nil
            }
        }
    }

    private var selectedRecord: GenerationRecord? {
        history.records.first { $0.id == selection }
    }
}

private struct HistoryRow: View {
    let record: GenerationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(record.draft?.name ?? String(record.requestDescription.prefix(20)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("\(record.executionMode?.displayName ?? "旧版技能") · \(record.status.displayName) · \(String(format: "%.1f", record.duration)) 秒 · \(record.usage?.totalTokens ?? record.estimatedTokens) tokens")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    private var statusSymbol: String {
        switch record.status {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }
}

private struct GenerationRecordDetail: View {
    let record: GenerationRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.draft?.name ?? record.status.displayName)
                            .font(.system(size: 19, weight: .bold))
                        Text("\(record.executionMode?.displayName ?? "旧版技能") · \(record.provider) · \(record.model)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(record.status.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }

                HistorySection(title: "原始需求") {
                    Text(record.requestDescription)
                }

                HistorySection(title: "生成过程") {
                    Text(record.reasoning.isEmpty ? "没有返回思考过程。" : record.reasoning)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let draft = record.draft {
                    HistorySection(title: "最终结果") {
                        Text(draft.summary)
                        ForEach(Array(draft.actions.enumerated()), id: \.offset) { index, action in
                            Text("\(index + 1). \(action)")
                        }
                    }
                } else if !record.rawOutput.isEmpty {
                    HistorySection(title: "未解析的输出") {
                        Text(record.rawOutput)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage = record.errorMessage {
                    HistorySection(title: "错误") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(22)
        }
    }
}

private struct HistorySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .font(.system(size: 12))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

#Preview {
    GenerationHistoryView()
}
