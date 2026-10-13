import Foundation

public enum QuotaProtocolParser {
    public static func parseRateLimitResponse(_ data: Data, capturedAt: Date = Date()) throws -> QuotaReading {
        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)

        if let error = envelope.error {
            throw CodexQuotaError.appServerReturnedError(error.message)
        }

        guard let result = envelope.result else {
            throw CodexQuotaError.invalidResponse
        }

        let mappedBuckets = (result.rateLimitsByLimitId ?? [:])
            .map { key, value in value.makeBucket(fallbackID: key) }
            .filter { $0.primary != nil || $0.secondary != nil }
            .sorted { lhs, rhs in
                if lhs.id == "codex" { return true }
                if rhs.id == "codex" { return false }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        let historical = result.rateLimits.makeBucket(fallbackID: "codex")
        let active = mappedBuckets.first(where: { $0.id == "codex" })
            ?? mappedBuckets.first
            ?? historical

        guard active.primary != nil || active.secondary != nil else {
            throw CodexQuotaError.invalidResponse
        }

        return QuotaReading(
            active: active,
            buckets: mappedBuckets.isEmpty ? [historical] : mappedBuckets,
            capturedAt: capturedAt,
            source: .liveAppServer
        )
    }
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let result: RateLimitResultDTO?
    let error: RPCErrorDTO?
}

private struct RPCErrorDTO: Decodable {
    let code: Int?
    let message: String
}

private struct RateLimitResultDTO: Decodable {
    let rateLimits: RateLimitSnapshotDTO
    let rateLimitsByLimitId: [String: RateLimitSnapshotDTO]?
}

private struct RateLimitSnapshotDTO: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindowDTO?
    let secondary: RateLimitWindowDTO?
    let credits: CreditsDTO?
    let planType: String?

    func makeBucket(fallbackID: String) -> QuotaBucket {
        let resolvedID = limitId ?? fallbackID
        let resolvedName: String
        if let limitName, !limitName.isEmpty {
            resolvedName = limitName
        } else if resolvedID == "codex" {
            resolvedName = "Codex"
        } else {
            resolvedName = resolvedID
        }

        return QuotaBucket(
            id: resolvedID,
            displayName: resolvedName,
            primary: primary?.makeWindow(),
            secondary: secondary?.makeWindow(),
            planType: planType,
            creditBalance: credits?.balance,
            unlimitedCredits: credits?.unlimited ?? false
        )
    }
}

private struct RateLimitWindowDTO: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?

    func makeWindow() -> QuotaWindow {
        QuotaWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMins,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct CreditsDTO: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}
