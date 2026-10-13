import XCTest
@testable import CodexQuotaCore

final class QuotaParsingTests: XCTestCase {
    func testParsesLiveRateLimitResponseAndPrefersCodexBucket() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":51,"windowDurationMins":300,"resetsAt":1783699438},"secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784250235},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1783710384},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1784297184},"credits":null,"individualLimit":null,"planType":"pro","rateLimitReachedType":null},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":51,"windowDurationMins":300,"resetsAt":1783699438},"secondary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784250235},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"planType":"pro","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}"#

        let reading = try QuotaProtocolParser.parseRateLimitResponse(Data(json.utf8))

        XCTAssertEqual(reading.active.id, "codex")
        XCTAssertEqual(reading.active.displayName, "Codex")
        XCTAssertEqual(reading.active.primary?.usedPercent, 51)
        XCTAssertEqual(reading.active.secondary?.usedPercent, 17)
        XCTAssertEqual(reading.active.planType, "pro")
        XCTAssertEqual(reading.buckets.count, 2)
        XCTAssertEqual(reading.source, .liveAppServer)
    }

    func testRejectsResponseWithoutUsableWindows() {
        let json = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":null,"secondary":null},"rateLimitsByLimitId":null}}"#
        XCTAssertThrowsError(try QuotaProtocolParser.parseRateLimitResponse(Data(json.utf8)))
    }
}
