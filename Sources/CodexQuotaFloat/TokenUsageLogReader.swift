import Foundation

struct DailyTokenUsage: Codable, Identifiable {
    let day: Date
    var inputTokens: Int64
    var outputTokens: Int64
    var cachedInputTokens: Int64

    var id: Date { day }
}

struct SessionTokenUsage: Codable, Identifiable {
    let sessionID: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cachedInputTokens: Int64
    var updatedAt: Date

    var id: String { sessionID }
    var totalTokens: Int64 { inputTokens + outputTokens + cachedInputTokens }
}

struct TokenUsageScanResult {
    let history: [DailyTokenUsage]
    let cursors: [String: UInt64]
    let sessions: [String: SessionTokenUsage]
}

final class TokenUsageLogReader {
    private let fileManager = FileManager.default
    private let calendar = Calendar.current

    func scan(
        history: [DailyTokenUsage],
        cursors: [String: UInt64],
        sessions: [String: SessionTokenUsage] = [:]
    ) throws -> TokenUsageScanResult {
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TokenUsageScanResult(history: history, cursors: cursors, sessions: sessions)
        }

        var totals = Dictionary(uniqueKeysWithValues: history.map { (calendar.startOfDay(for: $0.day), $0) })
        var nextCursors = cursors
        var sessionTotals = sessions

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let fileSize = UInt64(values?.fileSize ?? 0)
            let previousOffset = min(cursors[url.path] ?? 0, fileSize)
            guard fileSize > previousOffset else { continue }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: previousOffset)
            let data = try handle.readToEnd() ?? Data()
            guard let finalNewline = data.lastIndex(of: 0x0A) else { continue }
            let completeData = data.prefix(through: finalNewline)
            nextCursors[url.path] = previousOffset + UInt64(completeData.count)

            for line in completeData.split(separator: 0x0A) {
                guard let event = try? JSONDecoder().decode(TokenCountEvent.self, from: Data(line)),
                      event.type == "event_msg", event.payload.type == "token_count",
                      let info = event.payload.info,
                      let timestamp = Self.parseTimestamp(event.timestamp) else { continue }

                let usage = info.lastTokenUsage
                let sessionID = Self.sessionID(for: url)
                let cumulative = info.totalTokenUsage ?? usage
                sessionTotals[sessionID] = SessionTokenUsage(
                    sessionID: sessionID,
                    inputTokens: max(0, cumulative.inputTokens - cumulative.cachedInputTokens),
                    outputTokens: max(0, cumulative.outputTokens),
                    cachedInputTokens: max(0, cumulative.cachedInputTokens),
                    updatedAt: timestamp
                )

                let day = calendar.startOfDay(for: timestamp)
                var total = totals[day] ?? DailyTokenUsage(day: day, inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)
                total.inputTokens += max(0, usage.inputTokens - usage.cachedInputTokens)
                total.cachedInputTokens += usage.cachedInputTokens
                total.outputTokens += usage.outputTokens
                totals[day] = total
            }
        }
        return TokenUsageScanResult(
            history: totals.values.sorted { $0.day < $1.day },
            cursors: nextCursors,
            sessions: sessionTotals
        )
    }

    func scanSessionUsage() throws -> [String: SessionTokenUsage] {
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [String: SessionTokenUsage] = [:]
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  (values?.contentModificationDate ?? .distantPast) >= cutoff,
                  (values?.fileSize ?? 0) <= 20 * 1024 * 1024,
                  let data = try? Data(contentsOf: url) else { continue }

            let sessionID = Self.sessionID(for: url)
            for line in data.split(separator: 0x0A) {
                guard let event = try? JSONDecoder().decode(TokenCountEvent.self, from: Data(line)),
                      event.type == "event_msg", event.payload.type == "token_count",
                      let info = event.payload.info,
                      let timestamp = Self.parseTimestamp(event.timestamp) else { continue }
                let cumulative = info.totalTokenUsage ?? info.lastTokenUsage
                result[sessionID] = SessionTokenUsage(
                    sessionID: sessionID,
                    inputTokens: max(0, cumulative.inputTokens - cumulative.cachedInputTokens),
                    outputTokens: max(0, cumulative.outputTokens),
                    cachedInputTokens: max(0, cumulative.cachedInputTokens),
                    updatedAt: timestamp
                )
            }
        }
        return result
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func sessionID(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        let components = filename.split(separator: "-")
        guard components.count >= 8 else { return filename }
        return components.suffix(5).joined(separator: "-")
    }
}

private struct TokenCountEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: TokenCountPayload
}

private struct TokenCountPayload: Decodable {
    let type: String
    let info: TokenCountInfo?
}

private struct TokenCountInfo: Decodable {
    let lastTokenUsage: TokenUsageDTO
    let totalTokenUsage: TokenUsageDTO?
    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
    }
}

private struct TokenUsageDTO: Decodable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
    }
}
