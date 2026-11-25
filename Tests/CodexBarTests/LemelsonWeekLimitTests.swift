import Foundation
@testable import LemelsonUsageKit
import Testing

// lemelson: a past week whose limit was last read early (Magomed, Nov 9–16 2026: 26% on Nov 11, then no
// readings) while this Mac's spend alone is worth more. Others are unknown there, not zero.
struct LemelsonWeekLimitTests {
    static func week(_ fields: [String: Any]) throws -> UsagePanelState.Week {
        var json: [String: Any] = ["start": 1_794_000_000, "end": 1_794_604_800, "current": false]
        json.merge(fields) { $1 }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(UsagePanelState.Week.self, from: data)
    }

    @Test
    func `an early last reading below this Mac's part says others are unknown`() throws {
        let week = try Self.week(["peakPct": 26.0, "peakFinal": false, "minePct": 33.0, "othersPct": 0.0])
        let limit = UsageWeekLimit(week: week, window: nil, capacity: nil, fableWeight: 1, now: Date())
        #expect(limit.reading == .atLeast)
        #expect(limit.headline == "At least 33% used")
        #expect(limit.tail == ": you ≈33%, others unknown")
    }

    @Test
    func `a final reading with no other use is still all yours`() throws {
        let week = try Self.week(["peakPct": 40.0, "peakFinal": true, "minePct": 40.0, "othersPct": 0.0])
        let limit = UsageWeekLimit(week: week, window: nil, capacity: nil, fableWeight: 1, now: Date())
        #expect(limit.tail.hasPrefix(", all yours"))
    }

    @Test
    func `an early reading above this Mac's part keeps others as a lower bound`() throws {
        let week = try Self.week(["peakPct": 60.0, "peakFinal": false, "minePct": 20.0, "othersPct": 40.0])
        let limit = UsageWeekLimit(week: week, window: nil, capacity: nil, fableWeight: 1, now: Date())
        #expect(limit.tail == ": you ≈20%, others ≥40%")
    }
}
