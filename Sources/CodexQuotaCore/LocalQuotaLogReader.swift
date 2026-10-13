import Foundation

final class LocalQuotaLogReader {
    private let fileManager = FileManager.default
    private let maximumFilesToInspect = 50
    private let maximumBytesPerFile: UInt64 = 2 * 1024 * 1024

    func latestReading(liveError: Error?) throws -> QuotaReading {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]

        let files = roots
            .flatMap(recentJSONLFiles(in:))
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumFilesToInspect)

        var best: QuotaReading?
        for file in files {
            guard let reading = readLatestQuota(from: file.url) else { continue }
            if best == nil || reading.capturedAt > best!.capturedAt {
                best = reading
            }
        }

        guard let reading = best else {
            throw CodexQuotaError.noLocalQuotaRecord
        }

        return QuotaReading(
            active: reading.active,
            buckets: reading.buckets,
            capturedAt: reading.capturedAt,
            source: .localSessionFallback,
            diagnostic: liveError?.localizedDescription
        )
    }

    private func recentJSONLFiles(in root: URL) -> [DatedFile] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [DatedFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            result.append(DatedFile(url: url, modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    private func readLatestQuota(from url: URL) -> QuotaReading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maximumBytesPerFile ? size - maximumBytesPerFile : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        for (reverseIndex, line) in lines.reversed().enumerated() {
            let originalIndex = lines.count - 1 - reverseIndex
            if offset > 0 && originalIndex == 0 { continue }
            guard let reading = parseLogLine(Data(line.utf8)) else { continue }
            return reading
        }
        return nil
    }

    private func parseLogLine(_ data: Data) -> QuotaReading? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              let bucket = makeBucket(from: limits),
              bucket.primary != nil || bucket.secondary != nil else {
            return nil
        }

        let timestamp = (object["timestamp"] as? String).flatMap(Self.parseTimestamp) ?? Date.distantPast
        return QuotaReading(
            active: bucket,
            buckets: [bucket],
            capturedAt: timestamp,
            source: .localSessionFallback
        )
    }

    private func makeBucket(from dictionary: [String: Any]) -> QuotaBucket? {
        let id = dictionary["limit_id"] as? String ?? "codex"
        let suppliedName = dictionary["limit_name"] as? String
        let displayName = (suppliedName?.isEmpty == false) ? suppliedName! : (id == "codex" ? "Codex" : id)

        let credits = dictionary["credits"] as? [String: Any]
        let balance: String?
        if let value = credits?["balance"] as? String {
            balance = value
        } else if let value = credits?["balance"] as? NSNumber {
            balance = value.stringValue
        } else {
            balance = nil
        }

        return QuotaBucket(
            id: id,
            displayName: displayName,
            primary: makeWindow(from: dictionary["primary"]),
            secondary: makeWindow(from: dictionary["secondary"]),
            planType: dictionary["plan_type"] as? String,
            creditBalance: balance,
            unlimitedCredits: credits?["unlimited"] as? Bool ?? false
        )
    }

    private func makeWindow(from value: Any?) -> QuotaWindow? {
        guard let dictionary = value as? [String: Any],
              let used = number(dictionary["used_percent"]) else {
            return nil
        }

        let duration = number(dictionary["window_minutes"]).map(Int.init)
        let reset = number(dictionary["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return QuotaWindow(usedPercent: used, windowDurationMinutes: duration, resetsAt: reset)
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct DatedFile {
    let url: URL
    let modifiedAt: Date
}
