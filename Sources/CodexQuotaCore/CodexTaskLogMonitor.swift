import Foundation

public final class CodexTaskLogMonitor {
    private let fileManager = FileManager.default
    private let sessionsRoot: URL
    private let activeStaleAfter: TimeInterval
    private let recentFileAge: TimeInterval
    private let maximumFiles: Int
    private let titleResolver: CodexThreadTitleResolver
    private var caches: [String: FileTaskCache] = [:]

    public init(
        sessionsRoot: URL? = nil,
        activeStaleAfter: TimeInterval = 30 * 60,
        recentFileAge: TimeInterval = 7 * 24 * 60 * 60,
        maximumFiles: Int = 100,
        threadDatabaseURL: URL? = nil
    ) {
        self.sessionsRoot = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.activeStaleAfter = activeStaleAfter
        self.recentFileAge = recentFileAge
        self.maximumFiles = maximumFiles
        self.titleResolver = CodexThreadTitleResolver(databaseURL: threadDatabaseURL)
    }

    public func scan(now: Date = Date()) throws -> CodexTaskSnapshot {
        let files = recentSessionFiles(now: now)
        let activePaths = Set(files.map { $0.url.path })

        for file in files {
            try updateCache(for: file)
        }

        caches = caches.filter { activePaths.contains($0.key) }

        var runningByThread: [String: CodexTaskRecord] = [:]
        var completedByThread: [String: CodexTaskRecord] = [:]

        for cache in caches.values {
            let threadID = cache.threadID ?? cache.fallbackThreadID
            guard let task = cache.tasks.values.max(by: { $0.startedAt < $1.startedAt }) else {
                continue
            }

            let record = CodexTaskRecord(
                id: task.id,
                threadID: threadID,
                title: titleResolver.title(for: threadID) ?? task.title,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            )

            if record.isRunning {
                if now.timeIntervalSince(cache.modifiedAt) <= activeStaleAfter {
                    runningByThread[threadID] = record
                }
            } else {
                completedByThread[threadID] = record
            }
        }

        let running = runningByThread.values.sorted { $0.startedAt > $1.startedAt }
        let completed = completedByThread.values.sorted {
            ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
        }
        return CodexTaskSnapshot(running: running, completed: completed, scannedAt: now)
    }

    private func recentSessionFiles(now: Date) -> [SessionFile] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [SessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) <= recentFileAge else {
                continue
            }

            result.append(SessionFile(
                url: url,
                modifiedAt: modifiedAt,
                size: UInt64(max(0, values.fileSize ?? 0))
            ))
        }

        return Array(result.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maximumFiles))
    }

    private func updateCache(for file: SessionFile) throws {
        var cache = caches[file.url.path] ?? FileTaskCache(url: file.url, modifiedAt: file.modifiedAt)
        cache.modifiedAt = file.modifiedAt

        if file.size < cache.offset {
            cache = FileTaskCache(url: file.url, modifiedAt: file.modifiedAt)
        }

        guard file.size > cache.offset else {
            caches[file.url.path] = cache
            return
        }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: cache.offset)
        let newData = try handle.readToEnd() ?? Data()
        cache.offset = file.size

        var combined = cache.trailingData
        combined.append(newData)

        guard let lastNewline = combined.lastIndex(of: 0x0A) else {
            cache.trailingData = combined
            caches[file.url.path] = cache
            return
        }

        let completeData = combined.prefix(through: lastNewline)
        cache.trailingData = Data(combined.suffix(from: combined.index(after: lastNewline)))

        for line in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            parseLine(Data(line), into: &cache)
        }

        caches[file.url.path] = cache
    }

    private func parseLine(_ data: Data, into cache: inout FileTaskCache) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else {
            return
        }

        if object["type"] as? String == "session_meta",
           let id = payload["id"] as? String {
            cache.threadID = id
            return
        }

        guard object["type"] as? String == "event_msg",
              let eventType = payload["type"] as? String else {
            return
        }

        let timestamp = date(from: object["timestamp"]) ?? Date()

        switch eventType {
        case "task_started":
            guard let turnID = payload["turn_id"] as? String else { return }
            let startedAt = unixDate(from: payload["started_at"]) ?? timestamp
            cache.activeTurnID = turnID
            cache.tasks[turnID] = MutableTask(
                id: turnID,
                title: "Codex 任务",
                startedAt: startedAt,
                completedAt: nil
            )

        case "user_message":
            guard let turnID = cache.activeTurnID,
                  var task = cache.tasks[turnID],
                  let message = payload["message"] as? String else {
                return
            }
            task.title = compactTitle(message)
            cache.tasks[turnID] = task

        case "task_complete":
            guard let turnID = payload["turn_id"] as? String else { return }
            let completedAt = unixDate(from: payload["completed_at"]) ?? timestamp
            var task = cache.tasks[turnID] ?? MutableTask(
                id: turnID,
                title: "Codex 任务",
                startedAt: completedAt,
                completedAt: nil
            )
            task.completedAt = completedAt
            cache.tasks[turnID] = task
            if cache.activeTurnID == turnID {
                cache.activeTurnID = nil
            }

        default:
            break
        }
    }

    private func compactTitle(_ message: String) -> String {
        let collapsed = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Codex 任务" }
        if collapsed.count <= 72 { return collapsed }
        return String(collapsed.prefix(72)) + "…"
    }

    private func unixDate(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String, let number = Double(string) {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }

    private func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

private struct SessionFile {
    let url: URL
    let modifiedAt: Date
    let size: UInt64
}

private struct FileTaskCache {
    let url: URL
    var modifiedAt: Date
    var offset: UInt64 = 0
    var trailingData = Data()
    var threadID: String?
    var activeTurnID: String?
    var tasks: [String: MutableTask] = [:]

    var fallbackThreadID: String {
        let filename = url.deletingPathExtension().lastPathComponent
        let components = filename.split(separator: "-")
        guard components.count >= 8 else { return filename }
        return components.suffix(5).joined(separator: "-")
    }
}

private struct MutableTask {
    let id: String
    var title: String
    let startedAt: Date
    var completedAt: Date?
}
