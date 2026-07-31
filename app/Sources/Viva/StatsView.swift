import SwiftUI

// MARK: - 数据统计页

struct StatsView: View {
    @ObservedObject var store: HistoryStore
    @State private var range = 2      // 0=今天 1=本周 2=全部

    private var stats: VoiceStats {
        switch range {
        case 0: return store.today
        case 1: return store.thisWeek
        default: return store.allTime
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                Picker("", selection: $range) {
                    Text("今天").tag(0)
                    Text("本周").tag(1)
                    Text("全部").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                // ── 核心四项 ──
                HStack(spacing: 12) {
                    StatTile(icon: "text.bubble", tint: .blue, title: "说话次数",
                             value: "\(stats.count)", sub: "连续使用 \(store.streak) 天")
                    StatTile(icon: "clock", tint: .purple, title: "说话时长",
                             value: formatDuration(stats.totalSeconds),
                             sub: stats.count > 0
                                ? String(format: "平均每次 %.1fs", stats.totalSeconds / Double(stats.count))
                                : "—")
                    StatTile(icon: "character.cursor.ibeam", tint: .teal, title: "累计字数",
                             value: compactNumber(stats.totalChars),
                             sub: stats.count > 0 ? "平均每次 \(stats.totalChars / max(stats.count,1)) 字" : "—")
                    StatTile(icon: "bolt.fill", tint: .pink, title: "平均首字",
                             value: stats.avgFirstCharMs.map { "\($0) ms" } ?? "—",
                             sub: "客户端到托管服务端到端")
                }

                HStack(alignment: .top, spacing: 16) {

                    // ── 语速仪表 ──
                    GroupBox {
                        VStack(spacing: 10) {
                            Text("语速").font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            SpeedGauge(value: stats.charsPerMinute)
                                .frame(height: 132)
                            Text(speedComment(stats.charsPerMinute))
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                    }
                    .frame(width: 260)

                    // ── 节省时间 ──
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("省下了多少时间").font(.headline)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(formatMinutes(stats.savedMinutes))
                                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.orange)
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                CompareBar(label: "用说的",
                                           seconds: stats.totalSeconds,
                                           maxSeconds: maxCompare(stats),
                                           tint: .green)
                                CompareBar(label: "用打的",
                                           seconds: Double(stats.totalChars)
                                                / VoiceStats.typingCharsPerMinute * 60,
                                           maxSeconds: maxCompare(stats),
                                           tint: .secondary)
                            }

                            Text("按键盘输入 \(Int(VoiceStats.typingCharsPerMinute)) 字/分钟估算。个人输入速度不同，节省时间仅供参考。")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let ms = stats.avgFirstCharMs {
                                Divider()
                                HStack {
                                    Text("平均首字延迟").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(ms) ms")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // ── App 分布 ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("都在哪些应用里说").font(.headline)
                        let rows = store.appBreakdown()
                        if rows.isEmpty {
                            Text("还没有数据").font(.callout).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 16)
                        } else {
                            let total = rows.reduce(0) { $0 + $1.count }
                            ForEach(rows, id: \.name) { row in
                                AppBar(name: row.name, count: row.count,
                                       chars: row.chars, total: total)
                            }
                        }
                    }
                    .padding(6)
                }

                // ── 活跃热力图 ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最近 12 周活跃度").font(.headline)
                            Spacer()
                            Text("连续 \(store.streak) 天")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Heatmap(days: store.dailyChars(days: 84))
                            .frame(height: 92)
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
    }

    private func maxCompare(_ s: VoiceStats) -> Double {
        max(s.totalSeconds,
            Double(s.totalChars) / VoiceStats.typingCharsPerMinute * 60, 1)
    }

    private func speedComment(_ cpm: Double) -> String {
        guard cpm > 0 else { return "说几句就能看到你的语速" }
        let x = cpm / VoiceStats.typingCharsPerMinute
        return String(format: "%.0f 字/分钟，约为键盘输入的 %.1f 倍", cpm, x)
    }
}

// MARK: - 半圆语速仪表

private struct SpeedGauge: View {
    let value: Double
    private let maxValue: Double = 400

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let r = min(w / 2, geo.size.height) - 12
            let pct = min(1, max(0, value / maxValue))

            ZStack {
                Path { p in
                    p.addArc(center: CGPoint(x: w / 2, y: r + 10), radius: r,
                             startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                .stroke(Color.secondary.opacity(0.18), style: .init(lineWidth: 13, lineCap: .round))

                Path { p in
                    p.addArc(center: CGPoint(x: w / 2, y: r + 10), radius: r,
                             startAngle: .degrees(180),
                             endAngle: .degrees(180 + 180 * pct), clockwise: false)
                }
                .stroke(
                    LinearGradient(colors: [.blue, .teal, .green],
                                   startPoint: .leading, endPoint: .trailing),
                    style: .init(lineWidth: 13, lineCap: .round))

                VStack(spacing: 0) {
                    Text("\(Int(value))")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("字/分钟").font(.caption2).foregroundStyle(.secondary)
                }
                .offset(y: r / 2.6)
            }
        }
    }
}

// MARK: - 对比条

private struct CompareBar: View {
    let label: String
    let seconds: Double
    let maxSeconds: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(0.75))
                    .frame(width: max(3, geo.size.width * CGFloat(seconds / maxSeconds)))
            }
            .frame(height: 14)
            Text(formatDuration(seconds))
                .font(.caption).monospacedDigit()
                .frame(width: 66, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - App 分布条

private struct AppBar: View {
    let name: String
    let count: Int
    let chars: Int
    let total: Int

    var body: some View {
        let pct = total > 0 ? Double(count) / Double(total) : 0
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12))
                .frame(width: 130, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(4, geo.size.width * pct))
                    Text(String(format: "%.0f%%", pct * 100))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 7)
                }
            }
            .frame(height: 18)
            Text("\(count) 次 · \(compactNumber(chars)) 字")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .trailing)
        }
    }
}

// MARK: - 活跃热力图

private struct Heatmap: View {
    let days: [(date: Date, chars: Int, count: Int)]

    var body: some View {
        let maxChars = max(days.map(\.chars).max() ?? 1, 1)
        let weeks = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        HStack(alignment: .top, spacing: 3) {
            ForEach(weeks.indices, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(weeks[w].indices, id: \.self) { d in
                        let item = weeks[w][d]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(item.chars, maxChars))
                            .frame(width: 10, height: 10)
                            .help(tooltip(item))
                    }
                }
            }
            Spacer()
        }
    }

    private func color(_ chars: Int, _ maxChars: Int) -> Color {
        guard chars > 0 else { return Color.secondary.opacity(0.12) }
        let t = Double(chars) / Double(maxChars)
        return Color.accentColor.opacity(0.25 + 0.75 * min(1, t))
    }

    private func tooltip(_ item: (date: Date, chars: Int, count: Int)) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return item.count == 0
            ? "\(f.string(from: item.date))：没有使用"
            : "\(f.string(from: item.date))：\(item.count) 次 · \(item.chars) 字"
    }
}
