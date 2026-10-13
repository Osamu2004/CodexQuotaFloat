import CodexQuotaCore
import Foundation

@main
struct LiveQuotaSmokeTest {
    static func main() throws {
        let reading = try CodexQuotaService(timeout: 15).fetchLive()
        let primary = reading.active.primary.map { Int($0.usedPercent.rounded()) }
        let secondary = reading.active.secondary.map { Int($0.usedPercent.rounded()) }
        print("Live quota query passed: bucket=\(reading.active.id), primary=\(primary.map(String.init) ?? "n/a")%, secondary=\(secondary.map(String.init) ?? "n/a")%")
    }
}
