import Foundation

public struct CodexTaskRecord: Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let threadID: String
    public let title: String
    public let startedAt: Date
    public let completedAt: Date?

    public init(
        id: String,
        threadID: String,
        title: String,
        startedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var isRunning: Bool {
        completedAt == nil
    }
}

public struct CodexTaskSnapshot: Equatable {
    public let running: [CodexTaskRecord]
    public let completed: [CodexTaskRecord]
    public let scannedAt: Date

    public init(running: [CodexTaskRecord], completed: [CodexTaskRecord], scannedAt: Date) {
        self.running = running
        self.completed = completed
        self.scannedAt = scannedAt
    }
}
