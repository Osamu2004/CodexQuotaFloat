import AppKit
import CodexQuotaCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        Label(store.menuSummaryText, systemImage: "gauge.medium")
    }
}

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled

    var body: some View {
        if let reading = store.reading {
            Section("\(reading.active.displayName) · \(reading.active.planType?.uppercased() ?? "已连接")") {
                if let primary = reading.active.primary {
                    Text("\(menuWindowTitle(primary, fallback: "主额度"))：已用 \(percent(primary.usedPercent))")
                }
                if let secondary = reading.active.secondary {
                    Text("\(menuWindowTitle(secondary, fallback: "次额度"))：已用 \(percent(secondary.usedPercent))")
                }
                Text("数据来源：\(reading.source.displayName)")
            }

            if reading.buckets.count > 1 {
                Section("各额度桶") {
                    ForEach(reading.buckets) { bucket in
                        HStack {
                            Text(bucket.displayName)
                            Spacer()
                            if let primary = bucket.primary {
                                Text("主 \(percent(primary.usedPercent))")
                                    .foregroundStyle(.secondary)
                            }
                            if let secondary = bucket.secondary {
                                Text("周 \(percent(secondary.usedPercent))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let forecast = store.quotaForecast {
                Text("按近 \(forecast.sampleCount) 次采样：约 \(forecast.hoursUntilExhaustion < 24 ? String(format: "%.1f 小时", forecast.hoursUntilExhaustion) : String(format: "%.1f 天", forecast.hoursUntilExhaustion / 24)) 后耗尽")
                    .foregroundStyle(.orange)
            } else if reading.active.primary?.remainingPercent ?? 0 > 0 {
                Text("耗尽预测：采样不足")
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                Text("CLI：\(store.codexBinaryPath)")
                    .lineLimit(2)
                Text("最近额度记录：\(reading.capturedAt.formatted(.dateTime.hour().minute().second()))")
                    .foregroundStyle(.secondary)
                if let taskError = store.taskMonitorError {
                    Text("任务日志：\(taskError)")
                        .foregroundStyle(.orange)
                }
            }
        } else if store.isRefreshing {
            Text("正在读取 Codex 额度…")
        }

        if let error = store.lastError {
            Text(error)
        }

        if !store.recentDailyUsage.isEmpty {
            Section("每日历史用量") {
                ForEach(Array(store.recentDailyUsage.prefix(7))) { item in
                    HStack {
                        Text(dailyLabel(item.day))
                        Spacer()
                        Text(item.sampleCount > 1 ? "+\(formattedUsage(item.consumedPercent))%" : "记录中")
                    }
                }
            }
        }

        if !store.recentDailyTokenUsage.isEmpty {
            Section("每日 Token") {
                ForEach(Array(store.recentDailyTokenUsage.prefix(7))) { item in
                    Text("\(dailyLabel(item.day))：输入 \(TokenFormatter.compact(item.inputTokens)) · 输出 \(TokenFormatter.compact(item.outputTokens)) · 缓存 \(TokenFormatter.compact(item.cachedInputTokens))")
                }
            }
        }

        Section("Codex 活动") {
            Label("正在运行：\(store.runningTasks.count)", systemImage: "bolt.fill")
            ForEach(Array(store.runningTasks.prefix(3))) { task in
                Button {
                    openCodex(threadID: task.threadID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(task.title, systemImage: "arrow.up.right.square")
                        taskTokenLabel(task)
                    }
                }
            }

            Label("已完成，待查看：\(store.pendingReviewTasks.count)", systemImage: "checkmark.circle.fill")
            ForEach(Array(store.pendingReviewTasks.prefix(5))) { task in
                Button {
                    store.markTaskReviewed(task.threadID)
                    openCodex(threadID: task.threadID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("查看：\(task.title)", systemImage: "eye")
                        taskTokenLabel(task)
                    }
                }
            }

            if !store.pendingReviewTasks.isEmpty {
                Button("全部标记为已查看") {
                    store.markAllTasksReviewed()
                }
            }

            Button("打开 Codex") {
                openCodex()
            }
        }

        Divider()

        Toggle("显示浮窗", isOn: Binding(
            get: { store.isPanelVisible },
            set: { store.setPanelVisible($0) }
        ))

        Toggle("浮窗鼠标穿透", isOn: $store.mousePassthrough)

        Picker("自动刷新", selection: $store.refreshInterval) {
            Text("1 分钟").tag(60.0)
            Text("5 分钟").tag(300.0)
            Text("15 分钟").tag(900.0)
        }

        Menu("浮窗透明度") {
            Button("100%") { store.panelOpacity = 1.0 }
            Button("90%") { store.panelOpacity = 0.9 }
            Button("75%") { store.panelOpacity = 0.75 }
            Button("55%") { store.panelOpacity = 0.55 }
        }

        Toggle("登录时启动", isOn: Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try LaunchAtLoginManager.setEnabled(enabled)
                    launchAtLogin = LaunchAtLoginManager.isEnabled
                } catch {
                    launchAtLogin = LaunchAtLoginManager.isEnabled
                    store.report(error)
                }
            }
        ))

        Divider()

        Button {
            store.refreshAll()
        } label: {
            Label(store.isRefreshing ? "正在刷新…" : "立即刷新", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshing)

        Button("退出 CodexQuotaFloat") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func formattedUsage(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    private func dailyLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }

    private func menuWindowTitle(_ window: QuotaWindow, fallback: String) -> String {
        guard let minutes = window.windowDurationMinutes else { return fallback }
        if minutes == 300 { return "5 小时额度" }
        if minutes == 10_080 { return "每周额度" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }

    @ViewBuilder
    private func taskTokenLabel(_ task: CodexTaskRecord) -> some View {
        if let usage = store.sessionTokenUsage[task.threadID] {
            Text("线程累计 Token：输入 \(TokenFormatter.compact(usage.inputTokens)) · 输出 \(TokenFormatter.compact(usage.outputTokens)) · 缓存 \(TokenFormatter.compact(usage.cachedInputTokens))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func openCodex(threadID: String? = nil) {
        CodexLauncher.open(threadID: threadID) { error in
            store.report(error)
        }
    }
}

struct FloatingQuotaView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                header

                if let reading = store.reading {
                    quotaContent(reading, now: context.date)
                } else {
                    emptyContent
                }
                taskSummary

                footer(now: context.date)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .padding(.top, 8)
            .frame(width: 316, height: 378)
            .background {
                panelBackground
                    .overlay(WindowDragHandle())
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.16, green: 0.85, blue: 0.66), Color(red: 0.18, green: 0.55, blue: 0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 30, height: 30)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex 额度")
                        .font(.system(size: 14, weight: .semibold))
                    Text(store.reading?.active.displayName ?? "等待连接")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(WindowDragHandle())
            .help("拖动顶部区域移动浮窗")

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 25, height: 25)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("刷新额度")
            }

            Button {
                store.setPanelVisible(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("关闭浮窗")
        }
    }

    @ViewBuilder
    private func quotaContent(_ reading: QuotaReading, now: Date) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                if let primary = reading.active.primary {
                    QuotaNumberTile(title: windowTitle(primary, fallback: "5 小时"), window: primary, now: now)
                }
                if let secondary = reading.active.secondary {
                    QuotaNumberTile(title: windowTitle(secondary, fallback: "每周"), window: secondary, now: now)
                }
            }
            .overlay(WindowDragHandle())
            .help("拖动额度卡移动浮窗")
            UsageTrendView(
                points: store.todayUsageTrend,
                consumption: store.todayConsumptionEstimate,
                forecast: store.quotaForecast
            )
            .overlay(WindowDragHandle())
            .help("拖动消耗曲线移动浮窗")
            TodayTokenView(usage: store.todayTokenUsage)
                .overlay(WindowDragHandle())
                .help("拖动 Token 卡移动浮窗")
            Button {
                HistoryWindowController.shared.show(store: store)
            } label: {
                Label("查看全部历史", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
                    }
            )
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 8) {
            if store.isRefreshing {
                Text("正在读取实时额度…")
                    .font(.system(size: 13, weight: .medium))
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(store.lastError ?? "暂时没有额度数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .overlay(WindowDragHandle())
        .help("拖动浮窗")
    }

    private var taskSummary: some View {
        PetActivityTray(store: store)
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            if let reading = store.reading {
                Text("\(reading.source.displayName) · \(relativeAge(from: reading.capturedAt, now: now))")
                    .foregroundStyle(.secondary)
                if reading.source == .localSessionFallback {
                    Text("数据可能已过期")
                        .foregroundStyle(.orange)
                }
            } else {
                Text(store.isRefreshing ? "连接中" : "未连接")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let plan = store.reading?.active.planType {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .font(.system(size: 9.5))
        .overlay(WindowDragHandle())
        .help("拖动浮窗")
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            }
    }

    private var statusColor: Color {
        guard let reading = store.reading else { return store.isRefreshing ? .yellow : .red }
        return reading.source == .liveAppServer ? .green : .orange
    }

    private func windowTitle(_ window: QuotaWindow, fallback: String) -> String {
        guard let minutes = window.windowDurationMinutes else { return fallback }
        if minutes == 300 { return "5 小时" }
        if minutes == 10_080 { return "每周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    private func relativeAge(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3_600) 小时前"
    }
}

private struct PetActivityTray: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        Group {
            if let activity = latestActivity {
                Button {
                    if activity.kind == .pendingReview {
                        store.markTaskReviewed(activity.task.threadID)
                    }
                    CodexLauncher.open(threadID: activity.task.threadID) { store.report($0) }
                } label: {
                    compactContent(activity: activity)
                }
                .buttonStyle(.plain)
                .help(activity.kind == .running ? "在 Codex 中打开正在运行的对话" : "查看对话并标记为已查看")
            } else {
                compactContent(activity: nil)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.6)
                }
        )
        .overlay {
            if latestActivity == nil {
                WindowDragHandle()
            }
        }
    }

    private func compactContent(activity: (task: CodexTaskRecord, kind: PetActivityKind)?) -> some View {
        HStack(spacing: 9) {
            PetMascotView(isWorking: !store.runningTasks.isEmpty)

            VStack(alignment: .leading, spacing: 1) {
                Text(activity?.task.title ?? "宠物正在休息")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(activityCaption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(activity?.kind.tint ?? .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if totalCount > 0 {
                Text("\(totalCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var totalCount: Int {
        store.runningTasks.count + store.pendingReviewTasks.count
    }

    private var latestActivity: (task: CodexTaskRecord, kind: PetActivityKind)? {
        let running = store.runningTasks.first.map { (task: $0, kind: PetActivityKind.running) }
        let pending = store.pendingReviewTasks.first.map { (task: $0, kind: PetActivityKind.pendingReview) }
        switch (running, pending) {
        case let (running?, pending?):
            let pendingDate = pending.task.completedAt ?? pending.task.startedAt
            return running.task.startedAt >= pendingDate ? running : pending
        case let (running?, nil):
            return running
        case let (nil, pending?):
            return pending
        case (nil, nil):
            return nil
        }
    }

    private var activityCaption: String {
        if !store.runningTasks.isEmpty {
            return "\(store.runningTasks.count) 运行中 · \(store.pendingReviewTasks.count) 待查看"
        }
        if !store.pendingReviewTasks.isEmpty {
            return "\(store.pendingReviewTasks.count) 个完成待查看"
        }
        return "空闲"
    }
}

private struct PetMascotView: View {
    let isWorking: Bool
    @State private var isBobbing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: isWorking
                        ? [Color(red: 0.24, green: 0.82, blue: 0.72), Color(red: 0.26, green: 0.55, blue: 0.98)]
                        : [Color.secondary.opacity(0.34), Color.secondary.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 34, height: 34)
                .shadow(color: (isWorking ? Color.blue : Color.clear).opacity(0.18), radius: 7, y: 3)

            HStack(spacing: 7) {
                Circle().fill(.white).frame(width: 4.5, height: 5.5)
                Circle().fill(.white).frame(width: 4.5, height: 5.5)
            }
            .offset(y: -3)

            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: 9, height: 2.5)
                .offset(y: 7)

            if isWorking {
                WorkingDotsView()
                    .offset(x: 20, y: -15)
            }
        }
        .offset(y: isWorking && isBobbing ? -1.5 : 1.5)
        .onAppear {
            guard isWorking else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isBobbing = true
            }
        }
        .accessibilityLabel(isWorking ? "Codex 宠物正在工作" : "Codex 宠物正在休息")
    }
}

private struct WorkingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 3, height: 3)
                    .offset(y: animate ? -1.5 : 1.5)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: animate
                    )
            }
        }
        .padding(4)
        .background(Circle().fill(Color.blue.opacity(0.9)))
        .onAppear { animate = true }
    }
}

private enum PetActivityKind: Equatable {
    case running
    case pendingReview

    var tint: Color {
        switch self {
        case .running: return Color(red: 0.18, green: 0.55, blue: 0.96)
        case .pendingReview: return .orange
        }
    }

    var subtitle: String {
        switch self {
        case .running: return "正在工作"
        case .pendingReview: return "已完成 · 待查看"
        }
    }
}

private struct QuotaNumberTile: View {
    let title: String
    let window: QuotaWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text("剩余")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(title)
                .font(.system(size: 10.5, weight: .semibold))

            Group {
                if let reset = window.resetsAt {
                    Text("\(countdown(to: reset)) 后重置")
                } else {
                    Text("重置时间未知")
                }
            }
            .font(.system(size: 8.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var tint: Color {
        switch window.remainingPercent {
        case 0..<10: return .red
        case 10..<25: return .orange
        default: return Color(red: 0.14, green: 0.72, blue: 0.56)
        }
    }

    private func countdown(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)天 \(hours)小时" }
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        return "\(minutes)分"
    }
}

private struct UsageTrendView: View {
    let points: [QuotaUsageTrendPoint]
    let consumption: Double
    let forecast: QuotaForecast?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("今日消耗")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(points.count >= 2 ? "+\(formattedConsumption)%，本机记录" : "开始记录")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let forecast {
                    Text("约 \(forecastText(forecast)) 后耗尽")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text("耗尽预测：采样不足")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Sparkline(points: points.map(\.consumedPercent))
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.78, blue: 0.63), Color(red: 0.18, green: 0.55, blue: 0.96)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 104, height: 23)
                .background(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)
                }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private var formattedConsumption: String {
        if consumption < 10 {
            return String(format: "%.1f", consumption)
        }
        return "\(Int(consumption.rounded()))"
    }

    private func forecastText(_ forecast: QuotaForecast) -> String {
        if forecast.hoursUntilExhaustion < 24 {
            return String(format: "%.1f 小时", forecast.hoursUntilExhaustion)
        }
        return String(format: "%.1f 天", forecast.hoursUntilExhaustion / 24)
    }
}

private struct TodayTokenView: View {
    let usage: DailyTokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("今日 Token")
                .font(.system(size: 10.5, weight: .semibold))
            HStack(spacing: 0) {
                tokenColumn("输入", usage.inputTokens)
                tokenColumn("输出", usage.outputTokens)
                tokenColumn("缓存", usage.cachedInputTokens)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func tokenColumn(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(TokenFormatter.compact(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum TokenFormatter {
    static func compact(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

private struct Sparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }

        let maximum = max(points.max() ?? 0, 1)
        let denominator = max(points.count - 1, 1)
        for (index, value) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(denominator)
            let normalized = CGFloat(value / maximum)
            let y = rect.maxY - max(1, rect.height * normalized)
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        if points.count == 1 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
        }
        return path
    }
}
