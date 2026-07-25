import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 历史记录页

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索说过的话…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                Spacer()

                Text("\(store.records.count) 条 · \(compactNumber(store.allTime.totalChars)) 字")
                    .font(.caption).foregroundStyle(.secondary)

                Menu {
                    Button("导出为 Markdown…") { export(.markdown) }
                    Button("导出为 CSV…") { export(.csv) }
                    Divider()
                    Button("在访达中显示记录文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                    }
                    Divider()
                    Button("清空全部记录…", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            let groups = store.grouped(matching: query)

            if groups.isEmpty {
                EmptyState(
                    icon: query.isEmpty ? "waveform" : "magnifyingglass",
                    title: query.isEmpty ? "还没有识别记录" : "没有匹配的记录",
                    detail: query.isEmpty
                        ? "按住 \(HotkeyManager.describe(AppState.shared.config)) 说一句试试"
                        : "换个关键词看看")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.day) { group in
                            Section {
                                ForEach(group.items) { r in
                                    RecordRow(record: r, compact: false)
                                    Divider().padding(.leading, 16)
                                }
                            } header: {
                                DayHeader(day: group.day, items: group.items)
                            }
                        }
                    }
                }
            }
        }
        .alert("清空全部记录？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clearAll() }
        } message: {
            Text("会删除全部 \(store.records.count) 条记录，且无法撤销。统计数据也会一并归零。")
        }
    }

    private enum Format { case markdown, csv }

    private func export(_ f: Format) {
        let panel = NSSavePanel()
        switch f {
        case .markdown:
            panel.nameFieldStringValue = "语音输入记录.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        case .csv:
            panel.nameFieldStringValue = "语音输入记录.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (f == .markdown) ? store.exportMarkdown() : store.exportCSV()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 日期分组头

private struct DayHeader: View {
    let day: Date
    let items: [VoiceRecord]

    var body: some View {
        let chars = items.reduce(0) { $0 + $1.charCount }
        let secs = items.reduce(0.0) { $0 + $1.durationSec }
        HStack(spacing: 8) {
            Text(dayLabel)
                .font(.system(size: 12, weight: .semibold))
            Text("\(items.count) 次 · \(chars) 字 · \(formatDuration(secs))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInYesterday(day) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "M月d日 EEEE" : "yyyy年M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: day)
    }
}

// MARK: - 单条记录

struct RecordRow: View {
    let record: VoiceRecord
    let compact: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.text)
                    .font(.system(size: compact ? 13 : 14))
                    .lineSpacing(2)
                    .lineLimit(compact ? 2 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 9) {
                    Text(timeLabel).monospacedDigit()
                    if let app = record.appName {
                        Label(app, systemImage: "app").labelStyle(.titleAndIcon)
                    }
                    Text(String(format: "%.1fs", record.durationSec)).monospacedDigit()
                    Text("\(record.charCount) 字").monospacedDigit()
                    if let ms = record.firstCharMs {
                        Text("首字 \(ms)ms").monospacedDigit()
                    }
                    if !record.injected {
                        Label("仅复制", systemImage: "doc.on.clipboard")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            if hovering || copied {
                HStack(spacing: 4) {
                    Button {
                        TextInjector.copyToClipboard(record.text, transient: false)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("复制")

                    Button {
                        HistoryStore.shared.delete(record)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("删除")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 8 : 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .background(hovering ? Color.secondary.opacity(0.06) : .clear)
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = compact ? "MM-dd HH:mm" : "HH:mm:ss"
        return f.string(from: record.startedAt)
    }
}

// MARK: -

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(detail).font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
