import CodexQuotaCore
import Foundation

@main
struct QuotaCoreSmokeTest {
    static func main() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":51,"windowDurationMins":300,"resetsAt":1783699438},"secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784250235},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":51,"windowDurationMins":300,"resetsAt":1783699438},"secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784250235},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"planType":"pro","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}"#
        let reading = try QuotaProtocolParser.parseRateLimitResponse(Data(json.utf8))

        precondition(reading.active.id == "codex")
        precondition(reading.active.primary?.usedPercent == 51)
        precondition(reading.active.secondary?.usedPercent == 17)
        precondition(reading.active.planType == "pro")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTaskMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = root.appendingPathComponent("rollout-test.jsonl")
        let started = """
        {"timestamp":"2026-07-11T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-1"}}
        {"timestamp":"2026-07-11T00:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":1783728001}}
        {"timestamp":"2026-07-11T00:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"测试正在运行的任务"}}

        """
        try Data(started.utf8).write(to: log)

        let monitor = CodexTaskLogMonitor(
            sessionsRoot: root,
            activeStaleAfter: 86_400,
            recentFileAge: 86_400,
            maximumFiles: 10
        )
        let first = try monitor.scan(now: Date(timeIntervalSince1970: 1783728005))
        precondition(first.running.count == 1)
        precondition(first.running.first?.title == "测试正在运行的任务")

        let completed = """
        {"timestamp":"2026-07-11T00:00:06.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","completed_at":1783728006}}

        """
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completed.utf8))
        try handle.close()

        let second = try monitor.scan(now: Date(timeIntervalSince1970: 1783728007))
        precondition(second.running.isEmpty)
        precondition(second.completed.count == 1)
        precondition(second.completed.first?.id == "turn-1")

        let nextTurn = """
        {"timestamp":"2026-07-11T00:00:08.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2","started_at":1783728008}}
        {"timestamp":"2026-07-11T00:00:09.000Z","type":"event_msg","payload":{"type":"user_message","message":"同一个对话的第二轮任务"}}

        """
        let nextHandle = try FileHandle(forWritingTo: log)
        try nextHandle.seekToEnd()
        try nextHandle.write(contentsOf: Data(nextTurn.utf8))
        try nextHandle.close()

        let third = try monitor.scan(now: Date(timeIntervalSince1970: 1783728010))
        precondition(third.running.count == 1)
        precondition(third.completed.isEmpty)
        precondition(third.running.first?.id == "turn-2")
        print("Quota parser and task monitor smoke tests passed")
    }
}
