import CodexQuotaCore
import Foundation

@main
struct LiveTaskMonitorSmokeTest {
    static func main() throws {
        let snapshot = try CodexTaskLogMonitor().scan()
        print("Live task monitor passed: running=\(snapshot.running.count), recentCompleted=\(snapshot.completed.count)")
        for task in snapshot.running.prefix(5) {
            print("RUNNING \(task.id): \(task.title)")
        }
    }
}
