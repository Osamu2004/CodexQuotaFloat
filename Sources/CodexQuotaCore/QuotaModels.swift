import Foundation

public enum QuotaDataSource: String, Codable, Equatable {
    case liveAppServer
    case localSessionFallback

    public var displayName: String {
        switch self {
        case .liveAppServer:
            return "实时"
        case .localSessionFallback:
            return "本地记录"
        }
    }
}

public struct QuotaWindow: Codable, Equatable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowDurationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

public struct QuotaBucket: Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    public let planType: String?
    public let creditBalance: String?
    public let unlimitedCredits: Bool

    public init(
        id: String,
        displayName: String,
        primary: QuotaWindow?,
        secondary: QuotaWindow?,
        planType: String?,
        creditBalance: String?,
        unlimitedCredits: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.creditBalance = creditBalance
        self.unlimitedCredits = unlimitedCredits
    }
}

public struct QuotaReading: Codable, Equatable {
    public let active: QuotaBucket
    public let buckets: [QuotaBucket]
    public let capturedAt: Date
    public let source: QuotaDataSource
    public let diagnostic: String?

    public init(
        active: QuotaBucket,
        buckets: [QuotaBucket],
        capturedAt: Date,
        source: QuotaDataSource,
        diagnostic: String? = nil
    ) {
        self.active = active
        self.buckets = buckets
        self.capturedAt = capturedAt
        self.source = source
        self.diagnostic = diagnostic
    }
}

public enum CodexQuotaError: LocalizedError {
    case codexBinaryNotFound
    case appServerLaunchFailed(String)
    case appServerTimedOut
    case appServerReturnedError(String)
    case invalidResponse
    case noLocalQuotaRecord

    public var errorDescription: String? {
        switch self {
        case .codexBinaryNotFound:
            return "没有找到 Codex 可执行文件，请先安装 Codex for Mac。"
        case .appServerLaunchFailed(let detail):
            return "Codex 实时查询启动失败：\(detail)"
        case .appServerTimedOut:
            return "Codex 实时额度查询超时。"
        case .appServerReturnedError(let message):
            return "Codex 返回错误：\(message)"
        case .invalidResponse:
            return "Codex 返回了无法识别的额度数据。"
        case .noLocalQuotaRecord:
            return "没有找到可用的 Codex 额度记录。"
        }
    }
}
