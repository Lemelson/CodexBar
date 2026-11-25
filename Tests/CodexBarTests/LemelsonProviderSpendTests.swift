import Foundation
@testable import LemelsonUsageKit
import Testing

// lemelson: the fixes after the review of the provider pages: models ranked per period, one naming rule, the
// "Plan worth" row, cache shares that add up to 100, the account check, one run-out logic.
struct LemelsonProviderSpendTests {
    static let now = LemelsonLimitCardTests.now

    /// A day `ago` days before `now` with spend per model id: [id: (usd, tokens)].
    static func day(_ ago: Int, _ models: [String: (Double, Double)]) -> [String: Any] {
        let date = Calendar.current.date(byAdding: .day, value: -ago, to: self.now) ?? self.now
        let total = models.values.reduce(0) { $0 + $1.0 }
        return [
            "day": UsageDayKey.string(date), "opus": 0, "fable": 0, "other": total,
            "tokens": models.values.reduce(0) { $0 + $1.1 },
            "m": models.mapValues { [$0.0, $0.1] },
        ]
    }

    /// Recent days led by "gpt-6.2-sol", older ones (60–80 days back) by "gpt-6-astra" and "gpt-5.6-sol".
    static func block(extra: [String: Any] = [:]) -> [String: Any] {
        var block = LemelsonProviderBlockTests.codexBlock()
        block["daily"] = [
            self.day(1, ["gpt-6.2-sol": (20, 1e8), "gpt-6.1-terra": (10, 1e8), "gpt-6-luna": (0.003, 3e4),
                         "codex-auto-review": (0, 2e7)]),
            self.day(5, ["gpt-6.1-sol": (5, 2e7)]),
            self.day(60, ["gpt-6-astra": (4700, 3e9), "gpt-5.6-sol": (1900, 2e9)]),
            self.day(80, ["gpt-6-sol": (200, 6e8)]),
        ]
        block["trackedSince"] = self.now.timeIntervalSince1970 - 170 * 86400
        block["models"] = [
            "gpt-6.2-sol": ["calls": 10, "usd": 20, "priced": true, "missPct": 3],
            "gpt-6-luna": ["calls": 1, "usd": 0, "priced": true, "missPct": 50],
            "codex-auto-review": ["calls": 5, "usd": 0, "priced": false, "missPct": 10],
        ]
        block.merge(extra) { _, new in new }
        return block
    }

    static func spend(_ block: [String: Any] = Self.block()) throws -> (UsageProviderSpend, UsageProviderBlock) {
        let state = try LemelsonProviderBlockTests.state(key: "codex", block: block)
        let parsed = try #require(state.codex)
        return (UsageProviderSpend(block: parsed, spec: .codex, now: Self.now), parsed)
    }

    @Test
    func `each period names its own leading models with the same number of rows`() throws {
        let (spend, _) = try Self.spend()
        let month = spend[.d30]
        let quarter = spend[.d90]
        #expect(month.rows.map(\.id) == ["gpt-6.2-sol", "gpt-6.1-terra", "gpt-6.1-sol", "other"])
        // 90 days: the older leaders take the named rows; "Other" is not the largest row.
        #expect(quarter.rows.map(\.id) == ["gpt-6-astra", "gpt-5.6-sol", "gpt-6-sol", "other"])
        #expect(quarter.rows.last.map(\.use.usd) ?? 0 < quarter.rows[0].use.usd)
        // The legend and the colors follow the period: its leader gets the first color.
        #expect(quarter.chart.legend.map(\.id) == ["gpt-6-astra", "gpt-5.6-sol", "gpt-6-sol", "other"])
        #expect(quarter.rows[0].color == .model(0))
        // Every layer has the same number of rows.
        #expect(Set(UsageSpendPeriod.allCases.map { spend[$0].rows.count }) == [4])
    }

    @Test
    func `the other note says no price only for an unpriced model and fits one line by naming fewer`() throws {
        let (spend, _) = try Self.spend()
        let month = spend[.d30]
        // Luna is priced (under half a cent), Auto Review has no price.
        #expect(month.otherMembers.contains("Luna <$0.01"))
        #expect(month.otherMembers.contains("Auto Review no price"))
        let all = try #require(month.otherNote(naming: month.otherMembers.count))
        #expect(!all.contains("more"))
        let one = try #require(month.otherNote(naming: 1))
        #expect(one.hasSuffix(" and \(month.otherMembers.count - 1) more."))
        #expect(month.otherNote(naming: 0) == "Other: \(month.otherMembers.count) models.")
        #expect(UsageProviderSpend.cost(0, unpriced: true) == "no price")
        #expect(UsageProviderSpend.cost(0.003, unpriced: false) == "<$0.01")
        #expect(UsageProviderSpend.cost(0, unpriced: false) == "<$0.01")
    }

    @Test
    func `spend value and cache take one name per model`() throws {
        let (spend, block) = try Self.spend()
        let labels = block.modelLabels(spec: .codex)
        // Four Sol models keep their versions; a name only one model has goes without.
        #expect(labels["gpt-6.2-sol"] == "Sol 6.2")
        #expect(labels["gpt-6-astra"] == "Astra")
        #expect(labels["codex-auto-review"] == "Auto Review")
        #expect(spend.labels["gpt-6.2-sol"] == "Sol 6.2")
        let cache = try #require(UsageCacheSummary.provider(block, spec: .codex))
        #expect(cache.parts.first { $0.id == "gpt-6.2-sol" }?.name == "Sol 6.2")
    }

    @Test
    func `plan worth row reads measuring or the month and the multiple`() throws {
        let measuring = try Self.spend(Self.block(extra: [
            "value": ["confident": false, "reason": "Measured 1 of 4 times so far.", "pairs": 1, "byModel": []],
            "calibration": ["thresholds": ["confidentStretches": 4]],
        ]))
        let first = try #require(UsageProviderWorth(block: measuring.1, spec: .codex, spend: measuring.0))
        #expect(first.headline == "measuring, 1 of 4")

        let confident = try Self.spend(Self.block(extra: [
            "value": ["confident": true, "planName": "Plus", "planPriceUsd": 20, "monthUsd": 289, "timesPrice": 14.5,
                      "byModel": [["model": "gpt-6.2-sol", "label": "collector name", "monthUsd": 289]]],
        ]))
        let worth = try #require(UsageProviderWorth(block: confident.1, spec: .codex, spend: confident.0))
        #expect(worth.headline == "≈$289/mo · ×15")
        guard case let .numbers(numbers) = worth.content else {
            Issue.record("expected numbers")
            return
        }
        // The app's name, not the collector's label.
        #expect(numbers.models.first?.label == "Sol 6.2 only")
    }

    @Test
    func `cache shares are rounded together and add up to 100`() {
        #expect(UsageFormat.split(93.5) == ("94%", "6%"))
        #expect(UsageFormat.split(99.8) == (">99%", "<1%"))
        #expect(UsageFormat.split(0.2) == ("<1%", ">99%"))
        #expect(UsageFormat.split(100) == ("100%", "0%"))
        #expect(UsageFormat.split(0) == ("0%", "100%"))
    }

    @Test @MainActor
    func `limits of another account give one notice instead of the limit rows`() throws {
        let block = Self.block(extra: ["quotaSource": ["accountKey": "codex:v1:provider-account:A"]])
        let state = try LemelsonProviderBlockTests.state(key: "codex", block: block)
        let same = try #require(UsageProviderPage(
            spec: .codex, state: state, now: Self.now, width: 310, accountKey: "codex:v1:provider-account:A"))
        #expect(same.rows.contains { $0.part == .limit(.week) })
        let other = try #require(UsageProviderPage(
            spec: .codex, state: state, now: Self.now, width: 310, accountKey: "codex:v1:provider-account:B"))
        #expect(!other.rows.contains { if case .limit = $0.part { true } else { false } })
        #expect(other.rows.contains { $0.part == .notice })
        // Unknown on either side: no check.
        let unknown = try #require(UsageProviderPage(spec: .codex, state: state, now: Self.now, width: 310))
        #expect(unknown.rows.contains { $0.part == .limit(.week) })
        // The older name of the key decodes too.
        let legacy = try LemelsonProviderBlockTests.state(
            key: "codex", block: Self.block(extra: ["quotaSource": ["account": "k"]]))
        #expect(legacy.codex?.quotaSource?.accountKey == "k")
    }

    @Test
    func `pace follows the time mark and leaves run-out to the verdict`() throws {
        // A fresh reading with no forecast: the row says "No forecast", the panel's pace has no run-out.
        let window = try LemelsonLimitCardTests.window(pct: 70, resetIn: LemelsonLimitCardTests.week / 2)
        #expect(UsageLimitVerdict(window: window, now: Self.now) == .unknown)
        let pace = try #require(UsageLimitPace.make(window: window, kind: .week, now: Self.now))
        #expect(pace.headline == "20% in deficit")
        #expect(pace.mark.tone == .deficit)
        // A hair above even use: red mark, and the panel says deficit as well.
        let hair = try LemelsonLimitCardTests.window(pct: 50.2, resetIn: LemelsonLimitCardTests.week / 2)
        let close = try #require(UsageLimitPace.make(window: hair, kind: .week, now: Self.now))
        #expect(close.mark.tone == .deficit)
        #expect(close.headline == "<1% in deficit")
    }
}
