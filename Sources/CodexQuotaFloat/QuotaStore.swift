import AppKit
import CodexQuotaCore
import Foundation

struct QuotaUsageSample: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let primaryUsedPercent: Double
    let primaryResetsAt: Date?
    let secondaryUsedPercent: Double?
}

struct QuotaUsageTrendPoint: Identifiable {
    let timestamp: Date
    let consumedPercent: Double

    var id: Date { timestamp }
}

struct QuotaForecast {
    let percentPerHour: Double
    let hoursUntilExhaustion: Double
    let sampleCount: Int

    var exhaustionDate: Date {
        Date().addingTimeInterval(hoursUntilExhaustion * 3_600)
    }
}

struct DailyQuotaUsage: Codable, Identifiable {
    let day: Date
    var consumedPercent: Double
    var sampleCount: Int

    var id: Date { day }
}

final class QuotaStore: ObservableObject {
    @Published private(set) var reading: QuotaReading?
    @Published private(set) var usageSamples: [QuotaUsageSample]
    @Published private(set) var dailyUsageHistory: [DailyQuotaUsage]
    @Published private(set) var dailyTokenHistory: [DailyTokenUsage]
    @Published private(set) var sessionTokenUsage: [String: SessionTokenUsage]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var runningTasks: [CodexTaskRecord]
    @Published private(set) var pendingReviewTasks: [CodexTaskRecord]
    @Published private(set) var isRefreshingTasks = false
    @Published private(set) var taskMonitorError: String?
    @Published var isPanelVisible: Bool {
        didSet {
            defaults.set(isPanelVisible, forKey: Keys.panelVisible)
            visibilityHandler?(isPanelVisible)
        }
    }
    @Published var mousePassthrough: Bool {
        didSet {
            defaults.set(mousePassthrough, forKey: Keys.mousePassthrough)
            passthroughHandler?(mousePassthrough)
        }
    }
    @Published var panelOpacity: Double {
        didSet {
            panelOpacity = min(max(panelOpacity, 0.45), 1.0)
            defaults.set(panelOpacity, forKey: Keys.panelOpacity)
            opacityHandler?(panelOpacity)
        }
    }
    @Published var refreshInterval: Double {
        didSet {
            defaults.set(refreshInterval, forKey: Keys.refreshInterval)
            scheduleTimer()
        }
    }

    var visibilityHandler: ((Bool) -> Void)?
    var passthroughHandler: ((Bool) -> Void)?
    var opacityHandler: ((Double) -> Void)?

    private let defaults = UserDefaults.standard
    private let service: CodexQuotaService
    private let taskMonitor: CodexTaskLogMonitor
    private let tokenUsageReader = TokenUsageLogReader()
    private var tokenLogCursors: [String: UInt64]
    private var timer: Timer?
    private var taskTimer: Timer?
    private var previousRunningTasks: [String: CodexTaskRecord]
    private var lastTaskScanAt: Date?

    init(
        service: CodexQuotaService = CodexQuotaService(),
        taskMonitor: CodexTaskLogMonitor = CodexTaskLogMonitor()
    ) {
        self.service = service
        self.taskMonitor = taskMonitor
        self.runningTasks = []
        self.usageSamples = Self.decodeUsageSamples(
            UserDefaults.standard.data(forKey: Keys.usageSamples)
        )
        self.dailyUsageHistory = Self.decodeDailyUsage(
            UserDefaults.standard.data(forKey: Keys.dailyUsageHistory)
        )
        self.dailyTokenHistory = Self.decodeDailyTokenUsage(
            UserDefaults.standard.data(forKey: Keys.dailyTokenHistory)
        )
        self.sessionTokenUsage = Self.decodeSessionTokenUsage(
            UserDefaults.standard.data(forKey: Keys.sessionTokenUsage)
        )
        self.tokenLogCursors = Self.decodeTokenCursors(
            UserDefaults.standard.data(forKey: Keys.tokenLogCursors)
        )
        self.pendingReviewTasks = Self.decodeTasks(UserDefaults.standard.data(forKey: Keys.pendingReviewTasks))
        self.previousRunningTasks = Self.tasksByThread(
            Self.decodeTasks(UserDefaults.standard.data(forKey: Keys.previousRunningTasks))
        )
        self.lastTaskScanAt = UserDefaults.standard.object(forKey: Keys.lastTaskScanAt) as? Date
        self.isPanelVisible = defaults.object(forKey: Keys.panelVisible) as? Bool ?? true
        self.mousePassthrough = defaults.bool(forKey: Keys.mousePassthrough)
        self.panelOpacity = defaults.object(forKey: Keys.panelOpacity) as? Double ?? 0.94
        self.refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 300
    }

    deinit {
        timer?.invalidate()
        taskTimer?.invalidate()
    }

    func start() {
        scheduleTimer()
        scheduleTaskTimer()
        refresh()
        refreshTasks()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil

        let service = self.service
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try service.fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .success(let reading):
                    self.reading = reading
                    self.recordUsageSample(reading)
                    self.refreshTokenUsage()
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
    }

    func refreshAll() {
        refresh()
        refreshTasks()
    }

    func refreshTasks() {
        guard !isRefreshingTasks else { return }
        isRefreshingTasks = true
        taskMonitorError = nil

        let monitor = taskMonitor
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try monitor.scan() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingTasks = false
                switch result {
                case .success(let snapshot):
                    self.applyTaskSnapshot(snapshot)
                case .failure(let error):
                    self.taskMonitorError = error.localizedDescription
                }
            }
        }
    }

    func markTaskReviewed(_ threadID: String) {
        pendingReviewTasks.removeAll { $0.threadID == threadID }
        persistTaskState()
    }

    func markAllTasksReviewed() {
        pendingReviewTasks.removeAll()
        persistTaskState()
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    var menuPercentText: String {
        guard let used = reading?.active.primary?.usedPercent else { return "--" }
        return "\(Int(used.rounded()))%"
    }

    var menuSummaryText: String {
        "\(menuPercentText) · \(runningTasks.count)/\(pendingReviewTasks.count)"
    }

    var codexBinaryPath: String {
        service.resolvedBinaryPath() ?? "未找到 ChatGPT/Codex CLI"
    }

    var todayUsageTrend: [QuotaUsageTrendPoint] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let samples = usageSamples
            .filter { $0.timestamp >= startOfToday }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = samples.first else { return [] }

        var cumulative = 0.0
        var points = [QuotaUsageTrendPoint(timestamp: first.timestamp, consumedPercent: 0)]
        var previous = first

        for sample in samples.dropFirst() {
            let delta = sample.primaryUsedPercent - previous.primaryUsedPercent
            if delta >= 0 {
                cumulative += delta
            } else if resetChanged(from: previous.primaryResetsAt, to: sample.primaryResetsAt) {
                cumulative += sample.primaryUsedPercent
            }
            points.append(QuotaUsageTrendPoint(timestamp: sample.timestamp, consumedPercent: cumulative))
            previous = sample
        }
        return points
    }

    var todayConsumptionEstimate: Double {
        let today = Calendar.current.startOfDay(for: Date())
        return dailyUsageHistory.first(where: { Calendar.current.isDate($0.day, inSameDayAs: today) })?.consumedPercent
            ?? todayUsageTrend.last?.consumedPercent
            ?? 0
    }

    var recentDailyUsage: [DailyQuotaUsage] {
        dailyUsageHistory.sorted { $0.day > $1.day }
    }

    var recentDailyTokenUsage: [DailyTokenUsage] {
        dailyTokenHistory.sorted { $0.day > $1.day }
    }

    var todayTokenUsage: DailyTokenUsage {
        let today = Calendar.current.startOfDay(for: Date())
        return dailyTokenHistory.first(where: { Calendar.current.isDate($0.day, inSameDayAs: today) })
            ?? DailyTokenUsage(day: today, inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)
    }

    var quotaForecast: QuotaForecast? {
        guard let primary = reading?.active.primary,
              primary.remainingPercent > 0 else { return nil }

        let cutoff = Date().addingTimeInterval(-12 * 3_600)
        let samples = usageSamples
            .filter {
                $0.timestamp >= cutoff
                    && sameResetWindow($0.primaryResetsAt, primary.resetsAt)
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else { return nil }

        var consumed = 0.0
        for pair in zip(samples, samples.dropFirst()) {
            let delta = pair.1.primaryUsedPercent - pair.0.primaryUsedPercent
            if delta >= 0 { consumed += delta }
        }
        let elapsedHours = last.timestamp.timeIntervalSince(first.timestamp) / 3_600
        guard consumed > 0.01, elapsedHours >= 0.05 else { return nil }
        let rate = consumed / elapsedHours
        guard rate > 0.01 else { return nil }
        return QuotaForecast(
            percentPerHour: rate,
            hoursUntilExhaustion: primary.remainingPercent / rate,
            sampleCount: samples.count
        )
    }

    private func refreshTokenUsage() {
        let history = dailyTokenHistory
        let cursors = tokenLogCursors
        let sessions = sessionTokenUsage
        let reader = tokenUsageReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let result = try? reader.scan(history: history, cursors: cursors, sessions: sessions) else { return }
            let sessionResult: [String: SessionTokenUsage]
            if sessions.isEmpty {
                sessionResult = (try? reader.scanSessionUsage()) ?? result.sessions
            } else {
                sessionResult = result.sessions
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.dailyTokenHistory = result.history
                self.tokenLogCursors = result.cursors
                self.sessionTokenUsage = sessionResult
                self.persistTokenUsage()
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = min(15, refreshInterval * 0.1)
    }

    private func scheduleTaskTimer() {
        taskTimer?.invalidate()
        taskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTasks()
        }
        taskTimer?.tolerance = 1
    }

    private func recordUsageSample(_ reading: QuotaReading) {
        guard reading.source == .liveAppServer, let primary = reading.active.primary else { return }
        let now = Date()
        let sample = QuotaUsageSample(
            id: UUID(),
            timestamp: now,
            primaryUsedPercent: primary.usedPercent,
            primaryResetsAt: primary.resetsAt,
            secondaryUsedPercent: reading.active.secondary?.usedPercent
        )

        updateDailyUsage(with: sample, previous: usageSamples.last)

        let retentionStart = now.addingTimeInterval(-3 * 86_400)
        usageSamples.removeAll { $0.timestamp < retentionStart }

        if let last = usageSamples.last,
           now.timeIntervalSince(last.timestamp) < 60,
           abs(last.primaryUsedPercent - sample.primaryUsedPercent) < 0.001,
           abs((last.secondaryUsedPercent ?? -1) - (sample.secondaryUsedPercent ?? -1)) < 0.001 {
            persistUsageSamples()
            return
        }

        usageSamples.append(sample)
        if usageSamples.count > 600 {
            usageSamples.removeFirst(usageSamples.count - 600)
        }
        persistUsageSamples()
    }

    private func updateDailyUsage(with sample: QuotaUsageSample, previous: QuotaUsageSample?) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: sample.timestamp)
        let delta: Double

        if let previous, calendar.isDate(previous.timestamp, inSameDayAs: sample.timestamp) {
            let rawDelta = sample.primaryUsedPercent - previous.primaryUsedPercent
            if rawDelta >= 0 {
                delta = rawDelta
            } else if resetChanged(from: previous.primaryResetsAt, to: sample.primaryResetsAt) {
                delta = sample.primaryUsedPercent
            } else {
                delta = 0
            }
        } else {
            // The first observation of a day establishes a baseline; it is not
            // counted as usage because it may have accumulated before midnight.
            delta = 0
        }

        if let index = dailyUsageHistory.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            dailyUsageHistory[index].consumedPercent += delta
            dailyUsageHistory[index].sampleCount += 1
        } else {
            dailyUsageHistory.append(DailyQuotaUsage(day: day, consumedPercent: delta, sampleCount: 1))
        }

        dailyUsageHistory.sort { $0.day < $1.day }
        persistDailyUsage()
    }

    private func persistUsageSamples() {
        defaults.set(try? JSONEncoder().encode(usageSamples), forKey: Keys.usageSamples)
    }

    private func persistDailyUsage() {
        defaults.set(try? JSONEncoder().encode(dailyUsageHistory), forKey: Keys.dailyUsageHistory)
    }

    private func persistTokenUsage() {
        defaults.set(try? JSONEncoder().encode(dailyTokenHistory), forKey: Keys.dailyTokenHistory)
        defaults.set(try? JSONEncoder().encode(tokenLogCursors), forKey: Keys.tokenLogCursors)
        defaults.set(try? JSONEncoder().encode(sessionTokenUsage), forKey: Keys.sessionTokenUsage)
    }

    private func resetChanged(from oldDate: Date?, to newDate: Date?) -> Bool {
        switch (oldDate, newDate) {
        case let (oldDate?, newDate?):
            return abs(newDate.timeIntervalSince(oldDate)) > 10 * 60
        case (nil, nil):
            return false
        default:
            return true
        }
    }

    private func sameResetWindow(_ oldDate: Date?, _ newDate: Date?) -> Bool {
        switch (oldDate, newDate) {
        case let (oldDate?, newDate?):
            return abs(newDate.timeIntervalSince(oldDate)) <= 10 * 60
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func applyTaskSnapshot(_ snapshot: CodexTaskSnapshot) {
        let previousRunningThreadIDs = Set(previousRunningTasks.keys)
        let runningThreadIDs = Set(snapshot.running.map(\.threadID))
        var pendingByThreadID = Self.tasksByThread(pendingReviewTasks)

        for threadID in runningThreadIDs {
            pendingByThreadID.removeValue(forKey: threadID)
        }

        for task in snapshot.completed {
            let completedSinceLastScan: Bool
            if let completedAt = task.completedAt, let lastTaskScanAt {
                completedSinceLastScan = completedAt > lastTaskScanAt
            } else {
                completedSinceLastScan = false
            }

            if previousRunningThreadIDs.contains(task.threadID) || completedSinceLastScan {
                pendingByThreadID[task.threadID] = task
            }
        }

        runningTasks = snapshot.running
        pendingReviewTasks = pendingByThreadID.values
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(50)
            .map { $0 }
        previousRunningTasks = Self.tasksByThread(snapshot.running)
        lastTaskScanAt = snapshot.scannedAt
        taskMonitorError = nil
        persistTaskState()
    }

    private func persistTaskState() {
        defaults.set(Self.encodeTasks(pendingReviewTasks), forKey: Keys.pendingReviewTasks)
        defaults.set(Self.encodeTasks(Array(previousRunningTasks.values)), forKey: Keys.previousRunningTasks)
        defaults.set(lastTaskScanAt, forKey: Keys.lastTaskScanAt)
    }

    private static func encodeTasks(_ tasks: [CodexTaskRecord]) -> Data? {
        try? JSONEncoder().encode(tasks)
    }

    private static func decodeTasks(_ data: Data?) -> [CodexTaskRecord] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([CodexTaskRecord].self, from: data)) ?? []
    }

    private static func decodeUsageSamples(_ data: Data?) -> [QuotaUsageSample] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([QuotaUsageSample].self, from: data)) ?? []
    }

    private static func decodeDailyUsage(_ data: Data?) -> [DailyQuotaUsage] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([DailyQuotaUsage].self, from: data)) ?? []
    }

    private static func decodeDailyTokenUsage(_ data: Data?) -> [DailyTokenUsage] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([DailyTokenUsage].self, from: data)) ?? []
    }

    private static func decodeSessionTokenUsage(_ data: Data?) -> [String: SessionTokenUsage] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: SessionTokenUsage].self, from: data)) ?? [:]
    }

    private static func decodeTokenCursors(_ data: Data?) -> [String: UInt64] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: UInt64].self, from: data)) ?? [:]
    }

    private static func tasksByThread(_ tasks: [CodexTaskRecord]) -> [String: CodexTaskRecord] {
        var result: [String: CodexTaskRecord] = [:]
        for task in tasks {
            if let existing = result[task.threadID], existing.startedAt > task.startedAt {
                continue
            }
            result[task.threadID] = task
        }
        return result
    }

    private enum Keys {
        static let panelVisible = "panelVisible"
        static let mousePassthrough = "mousePassthrough"
        static let panelOpacity = "panelOpacity"
        static let refreshInterval = "refreshInterval"
        static let pendingReviewTasks = "pendingReviewTasks.v3"
        static let previousRunningTasks = "previousRunningTasks.v3"
        static let lastTaskScanAt = "lastTaskScanAt.v3"
        static let usageSamples = "quotaUsageSamples.v1"
        static let dailyUsageHistory = "dailyQuotaUsage.v1"
        static let dailyTokenHistory = "dailyTokenUsage.v1"
        static let tokenLogCursors = "tokenLogCursors.v1"
        static let sessionTokenUsage = "sessionTokenUsage.v1"
    }
}
