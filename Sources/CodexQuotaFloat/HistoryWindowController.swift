import AppKit
import SwiftUI

final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show(store: QuotaStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex 使用历史"
            window.minSize = NSSize(width: 560, height: 360)
            window.contentView = NSHostingView(rootView: UsageHistoryView(store: store))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UsageHistoryView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("使用历史")
                    .font(.system(size: 22, weight: .bold))
                Text("每日记录永久保存在本机")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("暂无历史记录")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header
                        Divider()
                        ForEach(rows) { row in
                            historyRow(row)
                            Divider()
                        }
                    }
                }
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            column("日期", width: 100, alignment: .leading)
            column("额度消耗", width: 90)
            column("输入", width: 100)
            column("输出", width: 100)
            column("缓存", width: 100)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func historyRow(_ row: HistoryRow) -> some View {
        HStack(spacing: 8) {
            column(row.day.formatted(.dateTime.year().month().day()), width: 100, alignment: .leading)
            column(row.quota.map(formatPercent) ?? "—", width: 90)
            column(row.tokens.map { TokenFormatter.compact($0.inputTokens) } ?? "—", width: 100)
            column(row.tokens.map { TokenFormatter.compact($0.outputTokens) } ?? "—", width: 100)
            column(row.tokens.map { TokenFormatter.compact($0.cachedInputTokens) } ?? "—", width: 100)
        }
        .font(.system(size: 12, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func column(_ text: String, width: CGFloat, alignment: Alignment = .trailing) -> some View {
        Text(text).frame(width: width, alignment: alignment)
    }

    private func formatPercent(_ value: Double) -> String {
        value < 10 ? String(format: "+%.1f%%", value) : "+\(Int(value.rounded()))%"
    }

    private var rows: [HistoryRow] {
        let calendar = Calendar.current
        var byDay: [Date: HistoryRow] = [:]
        for item in store.dailyUsageHistory {
            let day = calendar.startOfDay(for: item.day)
            byDay[day] = HistoryRow(day: day, quota: item.consumedPercent, tokens: nil)
        }
        for item in store.dailyTokenHistory {
            let day = calendar.startOfDay(for: item.day)
            let existing = byDay[day]
            byDay[day] = HistoryRow(day: day, quota: existing?.quota, tokens: item)
        }
        return byDay.values.sorted { $0.day > $1.day }
    }
}

private struct HistoryRow: Identifiable {
    let day: Date
    let quota: Double?
    let tokens: DailyTokenUsage?
    var id: Date { day }
}
