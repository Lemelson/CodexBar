import AppKit
import Foundation
@testable import CodexBar
@testable import LemelsonUsageKit
import Testing

// lemelson: the zoom into a span of days (`UsageSpendRange`), the zoomed layers and day panels of Claude Spend and
// the provider pages, the menu bar's 24-hour figure (`spend24h`, `lemelsonFormatMenuBarSpend`) and Overview's
// prompt cache of all subscriptions together (`UsageCacheSummary.all`).

/// Shared fixtures: day keys relative to one fixed moment, summaries decoded from JSON as the collector writes them.
enum LemelsonRangeFixtures {
    static let now = LemelsonLimitCardTests.now

    /// The day key `ago` calendar days before `now`.
    static func key(_ ago: Int) -> String {
        UsageDayKey.string(Calendar.current.date(byAdding: .day, value: -ago, to: self.now) ?? self.now)
    }

    static func state(_ summary: [String: Any]) throws -> UsagePanelState {
        var json = summary
        json["generatedAt"] = json["generatedAt"] ?? self.now.timeIntervalSince1970
        json["accounts"] = json["accounts"] ?? []
        return try JSONDecoder().decode(UsagePanelState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A Claude account with Opus / Fable days: [(ago, opus $, fable $)], 100k tokens per dollar.
    static func account(_ uuid: String, _ name: String, days: [(Int, Double, Double)]) -> [String: Any] {
        [
            "uuid": uuid, "name": name, "short": name,
            "daily": days.map { ago, opus, fable -> [String: Any] in
                var models: [String: [Double]] = [:]
                if opus > 0 { models["opus"] = [opus, opus * 100_000] }
                if fable > 0 { models["fable"] = [fable, fable * 100_000] }
                return [
                    "day": self.key(ago), "opus": opus, "fable": fable, "other": 0,
                    "tokens": (opus + fable) * 100_000, "m": models,
                ]
            },
        ]
    }

    /// Two accounts: Alpha 10 yesterday, 4 + 2 three days ago, 100 forty days ago; Beta 6 three days ago.
    static func claudeState() throws -> UsagePanelState {
        try self.state(["accounts": [
            self.account("a", "Alpha", days: [(1, 10, 0), (3, 4, 2), (40, 100, 0)]),
            self.account("b", "Beta", days: [(3, 6, 0)]),
        ]])
    }

    static func close(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

// MARK: - The span

@Suite
struct LemelsonSpendRangeTests {
    @Test
    func `a span is normalized whichever end comes first`() throws {
        let range = try #require(UsageSpendRange(startDay: "2026-11-14", endDay: "2026-11-03"))
        #expect(range.startDay == "2026-11-03")
        #expect(range.endDay == "2026-11-14")
        #expect(range == UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-14"))
        #expect(range.startDate == UsageDayKey.date("2026-11-03"))
        #expect(range.endDate == UsageDayKey.date("2026-11-14"))
        let byDates = try #require(UsageSpendRange(startDate: range.endDate, endDate: range.startDate))
        #expect(byDates == range)
        #expect(UsageSpendRange(startDay: "not a day", endDay: "2026-11-03") == nil)
    }

    @Test
    func `day count and domain count both ends`() throws {
        let range = try #require(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-14"))
        #expect(range.dayCount == 12)
        #expect(range.domain.lowerBound == UsageDayKey.date("2026-11-03"))
        #expect(range.domain.upperBound == UsageDayKey.date("2026-11-15"))
        #expect(UsageSpendRange.dayCount(of: range.domain) == 12)
        #expect(UsageSpendRange.of(domain: range.domain) == range)
        let one = try #require(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-03"))
        #expect(one.dayCount == 1)
        #expect(one.domain.upperBound == UsageDayKey.date("2026-11-04"))
    }

    @Test
    func `short title names the year only across a new year`() throws {
        #expect(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-14")?.shortTitle == "Nov 3 – Nov 14")
        #expect(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-14")?.compactTitle == "Nov 3 – Nov 14")
        #expect(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-03")?.shortTitle == "Nov 3")
        let crossing = try #require(UsageSpendRange(startDay: "2025-12-28", endDay: "2026-01-04"))
        #expect(crossing.shortTitle == "Dec 28, 2025 – Jan 4, 2026")
        #expect(crossing.compactTitle == "Dec 28 '25–Jan 4 '26")
        #expect(crossing.dayCount == 8)
    }

    @Test
    func `contains takes both ends and nothing outside`() throws {
        let range = try #require(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-14"))
        #expect(range.contains("2026-11-03"))
        #expect(range.contains("2026-11-10"))
        #expect(range.contains("2026-11-14"))
        #expect(!range.contains("2026-11-02"))
        #expect(!range.contains("2026-11-15"))
        #expect(!range.contains("2027-11-10"))
    }

    @Test
    func `covering period is the smallest preset that holds the span`() throws {
        #expect(UsageSpendRange(startDay: "2026-11-03", endDay: "2026-11-14")?.coveringPeriod == .d30)
        #expect(UsageSpendRange(startDay: "2026-09-01", endDay: "2026-10-15")?.coveringPeriod == .d60)
        #expect(UsageSpendRange(startDay: "2026-01-01", endDay: "2026-11-01")?.coveringPeriod == .d180)
    }
}

// MARK: - Claude Spend zoomed

@Suite
@MainActor
struct LemelsonSpendDigestRangeTests {
    typealias F = LemelsonRangeFixtures

    static func range() throws -> UsageSpendRange {
        try #require(UsageSpendRange(startDay: F.key(5), endDay: F.key(1)))
    }

    @Test
    func `a zoomed layer keeps only the span's days`() throws {
        let digest = try UsageSpendDigest(state: F.claudeState(), now: F.now)
        let range = try Self.range()
        let layer = digest.period(range: range)
        #expect(layer.range == range)
        #expect(layer.period == .d30)
        #expect(F.close(layer.whole.total.usd, 22))
        #expect(layer.chart.domain == range.domain)
        #expect(layer.chart.bars.allSatisfy { range.contains($0.key) })
        // Alpha yesterday, Alpha and Beta three days ago; the day forty days back is outside.
        #expect(layer.chart.bars.count == 3)
        #expect(F.close(layer.chart.bars.reduce(0) { $0 + $1.usd }, 22))
    }

    @Test
    func `the zoomed header adds up the span`() throws {
        let digest = try UsageSpendDigest(state: F.claudeState(), now: F.now)
        let range = try Self.range()
        let summary = digest.customSummary(for: range)
        #expect(summary.range == range)
        #expect(F.close(summary.total.usd, 22))
        #expect(F.close(summary.dailyAverage.usd, 22.0 / 5))
        let busiest = try #require(summary.busiestDay)
        #expect(busiest.date == UsageDayKey.date(F.key(3)))
        #expect(F.close(busiest.usd, 12))
    }

    @Test
    func `day panel ranks a day against the zoom and against a preset period`() throws {
        let digest = try UsageSpendDigest(state: F.claudeState(), now: F.now)
        let range = try Self.range()
        let catalog = digest.dayDetailCatalog(now: F.now)
        #expect(catalog.chartID == UsageSpendDigest.defaultChartID)
        #expect(catalog.panelKey == UsageSpendDigest.defaultChartID + ":day")
        #expect(catalog.defaultDayKey == F.key(0))
        #expect(catalog.fixedSection1Rows == 2)

        let busiest = catalog.dayDetail(F.key(3), .d30, range)
        #expect(F.close(busiest.totalUsd, 12))
        #expect(busiest.isCustomRange)
        #expect(busiest.periodDays == 5)
        #expect(busiest.periodLabel == "selected 5-day")
        #expect(F.close(busiest.periodDailyAverageUsd, 22.0 / 5))
        #expect(busiest.rankInPeriod == 1)
        #expect(busiest.rankLine == "Busiest of the 5 selected days")
        #expect(busiest.section1Title == "By account")
        #expect(busiest.section1Rows.map(\.label) == ["Alpha", "Beta"])
        #expect(busiest.section1Rows.map(\.usd) == [6, 6])

        let second = catalog.dayDetail(F.key(1), .d30, range)
        #expect(second.rankInPeriod == 2)
        #expect(second.rankLine == "2nd busiest of the 5 selected days")

        // Without a zoom the menu-wide period is the context: 90 days, the old day is the busiest.
        let old = catalog.dayDetail(F.key(40), .d90, nil)
        #expect(!old.isCustomRange)
        #expect(old.periodDays == 90)
        #expect(old.periodLabel == "90-day")
        #expect(F.close(old.periodDailyAverageUsd, 122.0 / 90))
        #expect(old.rankInPeriod == 1)
        #expect(old.rankLine == "Busiest day of the last 90")
    }

    @Test
    func `a day without calls has no rank and keeps every row`() throws {
        let digest = try UsageSpendDigest(state: F.claudeState(), now: F.now)
        let catalog = digest.dayDetailCatalog(now: F.now)
        let empty = try catalog.dayDetail(F.key(2), .d30, Self.range())
        #expect(empty.isEmpty)
        #expect(empty.rankInPeriod == nil)
        #expect(empty.subtitle == "No calls recorded this day")
        #expect(empty.comparisonLine.hasPrefix("Selected 5-day daily average:"))
        #expect(empty.rankLine == " ")
        #expect(empty.section1Rows.count == 2)
        #expect(empty.section1Rows.allSatisfy { $0.usd == 0 })

        // Today so far does not compare partial progress as a multiplier or rank against finished days.
        let withToday = try F.state(["accounts": [F.account("a", "Alpha", days: [(0, 5, 0), (1, 10, 0)])]])
        let todayDetail = UsageSpendDigest(state: withToday, now: F.now).dayDetailCatalog(now: F.now)
            .dayDetail(F.key(0), .d30, nil)
        #expect(todayDetail.isToday)
        #expect(todayDetail.comparisonLine.hasPrefix("So far today"))
        #expect(todayDetail.rankLine == "Day in progress")
    }

    @Test
    func `the dragged span preview adds up accounts and models`() throws {
        let digest = try UsageSpendDigest(state: F.claudeState(), now: F.now)
        let range = try Self.range()
        let preview = digest.dayDetailCatalog(now: F.now).rangePreview(range)
        #expect(preview.range == range)
        #expect(F.close(preview.totalUsd, 22))
        #expect(F.close(preview.totalTokens, 2_200_000))
        #expect(F.close(preview.dailyAverageUsd, 22.0 / 5))
        #expect(preview.busiestDay?.date == UsageDayKey.date(F.key(3)))
        #expect(preview.section1Rows.map(\.usd) == [16, 6])
        #expect(F.close(preview.section2Rows.reduce(0) { $0 + $1.usd }, 22))
    }
}

// MARK: - A provider page zoomed

@Suite
@MainActor
struct LemelsonProviderSpendRangeTests {
    typealias F = LemelsonRangeFixtures

    /// The Codex history of `LemelsonProviderSpendTests`, with yesterday's unpriced Auto Review tokens.
    static func spend() throws -> UsageProviderSpend {
        var block = LemelsonProviderSpendTests.block()
        var daily = try #require(block["daily"] as? [[String: Any]])
        daily[0]["unpriced"] = ["codex-auto-review": 20_000_000.0]
        block["daily"] = daily
        return try LemelsonProviderSpendTests.spend(block).0
    }

    static func range() throws -> UsageSpendRange {
        try #require(UsageSpendRange(startDay: F.key(7), endDay: F.key(1)))
    }

    @Test
    func `a zoomed layer and header keep only the span's days`() throws {
        let spend = try Self.spend()
        let range = try Self.range()
        let layer = spend.period(range: range)
        #expect(layer.range == range)
        #expect(layer.period == .d30)
        #expect(layer.chart.domain == range.domain)
        #expect(layer.chart.bars.allSatisfy { range.contains($0.key) })
        // Yesterday (20 + 10 + 0.003) and five days ago (5); the 60- and 80-day-old leaders are outside.
        #expect(F.close(layer.whole.usd, 35.003, 1e-6))
        #expect(layer.rows.count == spend[.d30].rows.count)

        let summary = spend.customSummary(for: range)
        #expect(F.close(summary.total.usd, 35.003, 1e-6))
        #expect(F.close(summary.dailyAverage.usd, 35.003 / 7, 1e-6))
        #expect(summary.busiestDay?.date == UsageDayKey.date(F.key(1)))
    }

    @Test
    func `day panel by model with the unpriced note`() throws {
        let spend = try Self.spend()
        let range = try Self.range()
        let catalog = spend.dayDetailCatalog(spec: .codex, now: F.now)
        #expect(catalog.chartID == UsageProviderSpec.codex.spendChartID)
        #expect(catalog.panelKey == UsageProviderSpec.codex.spendChartID + ":day")
        #expect(catalog.fixedSection1Rows == 0)
        #expect(catalog.reservesNoteLine)

        let yesterday = catalog.dayDetail(F.key(1), .d30, range)
        #expect(yesterday.isCustomRange)
        #expect(yesterday.periodDays == 7)
        #expect(yesterday.rankInPeriod == 1)
        #expect(yesterday.section1Title == nil)
        #expect(yesterday.section1Rows.isEmpty)
        #expect(yesterday.section2Rows.count == catalog.fixedSection2Rows)
        let note = try #require(yesterday.unpricedNote)
        #expect(note.hasPrefix("No price: Auto Review ("))
        #expect(note.hasSuffix(" tokens)."))

        let earlier = catalog.dayDetail(F.key(5), .d30, range)
        #expect(earlier.rankInPeriod == 2)
        #expect(earlier.unpricedNote == nil)

        let empty = catalog.dayDetail(F.key(3), .d30, range)
        #expect(empty.isEmpty)
        #expect(empty.rankInPeriod == nil)
        #expect(empty.section2Rows.count == catalog.fixedSection2Rows)
    }

    @Test
    func `the dragged span preview lists the models of the span`() throws {
        let spend = try Self.spend()
        let range = try Self.range()
        let preview = spend.dayDetailCatalog(spec: .codex, now: F.now).rangePreview(range)
        #expect(F.close(preview.totalUsd, 35.003, 1e-6))
        #expect(preview.section1Title == nil)
        #expect(preview.section1Rows.isEmpty)
        #expect(F.close(preview.section2Rows.reduce(0) { $0 + $1.usd }, 35.003, 1e-6))
    }
}

// MARK: - The menu bar's 24 hours

@Suite
struct LemelsonSpend24hTests {
    typealias F = LemelsonRangeFixtures

    static var claudeAccounts: [[String: Any]] {
        [
            ["uuid": "a", "name": "Alpha", "short": "A", "usd24h": 3.0],
            ["uuid": "b", "name": "Beta", "short": "B", "usd24h": 1.5],
        ]
    }

    @Test
    func `a full spend24h block decodes provider by provider`() throws {
        let state = try F.state([
            "accounts": Self.claudeAccounts,
            "spend24h": [
                "usd": 12.5, "tokens": 4_000_000, "asOf": F.now.timeIntervalSince1970,
                "byProvider": [
                    "claude": ["usd": 10.0, "tokens": 3_000_000, "accounts": [
                        ["uuid": "a", "name": "Alpha", "short": "A", "usd": 7.0],
                        ["uuid": "b", "name": "Beta", "usd": 3.0, "tokens": 1000],
                    ]],
                    "codex": ["usd": 2.5],
                    "antigravity": ["usd": 0, "error": "quota step failed"],
                ],
            ],
        ])
        let spend = try #require(state.spend24h)
        #expect(spend.usd == 12.5)
        #expect(spend.tokens == 4_000_000)
        #expect(spend.asOf == F.now.timeIntervalSince1970)
        let claude = try #require(spend.byProvider?.claude)
        #expect(claude.usd == 10)
        #expect(claude.accounts?.map(\.id) == ["a", "b"])
        #expect(claude.accounts?[1].short == nil)
        #expect(spend.byProvider?.codex == UsagePanelState.Spend24h.Provider(usd: 2.5))
        #expect(spend.byProvider?.antigravity?.error == "quota step failed")
        // The block's own total wins over the accounts' figures.
        #expect(state.rolling24hUsd == 12.5)
        #expect(state.rolling24hTokens == 4_000_000)
    }

    @Test
    func `a malformed or missing provider drops only itself`() throws {
        let state = try F.state([
            "accounts": Self.claudeAccounts,
            "spend24h": [
                "usd": 2.5,
                "byProvider": ["claude": "not an object", "codex": ["usd": 2.5]],
            ],
        ])
        let spend = try #require(state.spend24h)
        #expect(spend.byProvider?.claude == nil)
        #expect(spend.byProvider?.antigravity == nil)
        #expect(spend.byProvider?.codex?.usd == 2.5)
        #expect(state.rolling24hUsd == 2.5)
        #expect(state.accounts.count == 2)
    }

    @Test
    func `a malformed block costs nothing and falls back to usd24h`() throws {
        var codex = LemelsonProviderBlockTests.codexBlock()
        codex["usd24h"] = 2.0
        var antigravity = LemelsonProviderBlockTests.codexBlock(name: "Antigravity")
        antigravity["usd24h"] = 9.0
        antigravity["error"] = "error: made up"
        let state = try F.state([
            "accounts": Self.claudeAccounts,
            "spend24h": "oops",
            "codex": codex,
            "antigravity": antigravity,
        ])
        #expect(state.spend24h == nil)
        #expect(state.accounts.count == 2)
        // Both Claude accounts and Codex; the failed Antigravity block is left out.
        #expect(state.rolling24hUsd == 6.5)
    }

    @Test
    func `an older summary without any 24-hour figure has none`() throws {
        let state = try F.state(["accounts": [["uuid": "a", "name": "Alpha", "short": "A"]]])
        #expect(state.spend24h == nil)
        #expect(state.rolling24hUsd == nil)
        #expect(state.rolling24hTokens == nil)
        let legacy = try F.state(["accounts": Self.claudeAccounts])
        #expect(legacy.spend24h == nil)
        #expect(legacy.rolling24hUsd == 4.5)
    }
}

// MARK: - The menu bar's number

@Suite
struct LemelsonMenuBarSpendFormatTests {
    static func format(_ usd: Double, cents: Bool = false) -> String {
        StatusItemController.lemelsonFormatMenuBarSpend(usd, alwaysCents: cents)
    }

    @Test
    func `cents under ten dollars, whole dollars with grouping above`() {
        #expect(Self.format(0) == "$0.00")
        #expect(Self.format(0.004) == "$0.00")
        #expect(Self.format(4.2) == "$4.20")
        #expect(Self.format(9.99) == "$9.99")
        #expect(Self.format(10) == "$10")
        #expect(Self.format(182.4) == "$182")
        #expect(Self.format(182.5) == "$183")
        #expect(Self.format(1240) == "$1,240")
        #expect(Self.format(1_234_567) == "$1,234,567")
    }

    @Test
    func `always cents keeps two decimals at any size`() {
        #expect(Self.format(10, cents: true) == "$10.00")
        #expect(Self.format(182.456, cents: true) == "$182.46")
        #expect(Self.format(1240.5, cents: true) == "$1,240.50")
        #expect(Self.format(4.2, cents: true) == "$4.20")
    }

    @Test
    func `negative and non-finite amounts read as zero`() {
        #expect(Self.format(-5) == "$0.00")
        #expect(Self.format(.nan) == "$0.00")
        #expect(Self.format(.infinity) == "$0.00")
        #expect(Self.format(-.infinity, cents: true) == "$0.00")
    }
}

// MARK: - Overview's prompt cache

@Suite
struct LemelsonOverviewCacheTests {
    typealias F = LemelsonRangeFixtures

    static func block(name: String, cache: [String: Any], error: String? = nil) -> [String: Any] {
        var block = LemelsonProviderBlockTests.codexBlock(name: name)
        block["cache"] = cache
        if let error {
            block["error"] = error
        }
        return block
    }

    /// Claude 80 % of 10k cacheable tokens ($12 saved), Codex 95 % of 1k ($3 saved), Antigravity failed.
    static func state(antigravityError: String? = "error: made up") throws -> UsagePanelState {
        try F.state([
            "accounts": [["uuid": "a", "name": "Alpha", "short": "A"]],
            "cache": ["7d": ["readPct": 80.0, "readTokens": 8000.0, "calls": 10, "savedUsd": 12.0]],
            "codex": self.block(
                name: "Codex",
                cache: ["7d": ["readPct": 95.0, "readTokens": 950.0, "calls": 14, "savedUsd": 3.0]]),
            "antigravity": self.block(
                name: "Antigravity",
                cache: ["7d": ["readPct": 10.0, "readTokens": 100.0, "calls": 3, "savedUsd": 0.5]],
                error: antigravityError),
        ])
    }

    @Test
    func `all subscriptions are weighted by cacheable tokens and a failed provider is left out`() throws {
        let summary = try #require(UsageCacheSummary.all(Self.state()))
        #expect(summary.product == .all)
        #expect(summary.rowID == "lemelsonOverview-cache")
        #expect(summary.main.id == "7d")
        // (80 × 10,000 + 95 × 1,000) / 11,000
        #expect(F.close(summary.main.reusedPct, 895_000.0 / 11000, 1e-9))
        #expect(F.close(summary.main.savedUsd ?? -1, 15))
        #expect(summary.parts.map(\.id) == ["claude", "codex"])
        #expect(summary.parts.map(\.reusedPct) == [80, 95])
        #expect(summary.parts.map(\.savedUsd) == [12, 3])
        #expect(summary.partsTitle == "By provider · 7 days")
    }

    @Test
    func `every healthy provider gets a part`() throws {
        let summary = try #require(UsageCacheSummary.all(Self.state(antigravityError: nil)))
        #expect(summary.parts.map(\.id) == ["claude", "codex", "antigravity"])
        #expect(F.close(summary.main.savedUsd ?? -1, 15.5))
        // (80 × 10,000 + 95 × 1,000 + 10 × 1,000) / 12,000
        #expect(F.close(summary.main.reusedPct, 905_000.0 / 12000, 1e-9))
    }

    @Test
    func `one provider alone has no parts and none at all has no row`() throws {
        let alone = try F.state([
            "accounts": [["uuid": "a", "name": "Alpha", "short": "A"]],
            "cache": ["7d": ["readPct": 80.0, "readTokens": 8000.0, "savedUsd": 12.0]],
        ])
        let summary = try #require(UsageCacheSummary.all(alone))
        #expect(summary.parts.isEmpty)
        #expect(summary.main.reusedPct == 80)

        let none = try F.state([
            "accounts": [["uuid": "a", "name": "Alpha", "short": "A"]],
            "cacheError": "error: cache step failed",
            "cache": ["7d": ["readPct": 80.0]],
        ])
        #expect(UsageCacheSummary.all(none) == nil)
    }

    @Test
    func `zero-reuse provider weights by miss tokens and parts stay strictly on main span`() throws {
        // Claude: 90% of 10k tokens (9000 read, 1000 miss) on 7d.
        // Codex: 0% reuse on 7d with 10k missTokens (0 readTokens), so weighted average is 45%.
        // Antigravity: only has 30d data (no 7d) -> must NOT appear under "By provider · 7 days".
        let state = try F.state([
            "accounts": [["uuid": "a", "name": "Alpha", "short": "A"]],
            "cache": ["7d": ["readPct": 90.0, "readTokens": 9000.0, "missTokens": 1000.0, "savedUsd": 10.0]],
            "codex": Self.block(
                name: "Codex",
                cache: ["7d": ["readPct": 0.0, "readTokens": 0.0, "missTokens": 10_000.0, "savedUsd": 0.0]]),
            "antigravity": Self.block(
                name: "Antigravity",
                cache: ["30d": ["readPct": 50.0, "readTokens": 500.0, "missTokens": 500.0, "savedUsd": 1.0]]),
        ])
        let summary = try #require(UsageCacheSummary.all(state))
        #expect(summary.main.id == "7d")
        #expect(F.close(summary.main.reusedPct, 45.0, 1e-9))
        #expect(summary.parts.map(\.id) == ["claude", "codex"])
        #expect(summary.includedProviders == ["Claude", "Codex", "Antigravity"])
    }
}

// MARK: - Overview spend, colors, status severity & partial 24h

@Suite
@MainActor
struct LemelsonOverviewSpendTests {
    typealias F = LemelsonRangeFixtures

    static func overviewState() throws -> UsagePanelState {
        var codex = LemelsonProviderBlockTests.codexBlock(name: "Codex")
        codex["usd24h"] = 12.0
        codex["tokens24h"] = 500_000.0
        codex["daily"] = [
            ["day": F.key(1), "m": ["gpt-6.2-sol": [15.0, 200_000], "codex-auto-review": [0.0, 50_000]],
             "unpriced": ["codex-auto-review": 50_000]],
            ["day": F.key(40), "m": ["gpt-6.1-sol": [50.0, 400_000]]],
        ]
        var antigravity = LemelsonProviderBlockTests.codexBlock(name: "Antigravity")
        antigravity["usd24h"] = 0.0
        antigravity["tokens24h"] = 0.0
        antigravity["daily"] = [
            ["day": F.key(1), "m": ["gemini-neon": [25.0, 300_000]]],
            ["day": F.key(40), "m": ["gemini-neon": [100.0, 900_000]]],
        ]
        return try F.state([
            "accounts": [
                F.account("a", "Alpha", days: [(1, 30, 10), (40, 200, 20)]),
                ["uuid": "b", "name": "Beta", "short": "Beta", "error": "error: timeout"],
            ],
            "codex": codex,
            "antigravity": antigravity,
            "spend24h": [
                "usd": 42.0,
                "tokens": 1_000_000,
                "partial": true,
                "byProvider": [
                    "claude": [
                        "usd": 30.0, "failedAccounts": 1,
                        "accounts": [["uuid": "a", "name": "Alpha", "short": "Alpha", "usd": 20.0]],
                    ],
                    "codex": ["usd": 12.0],
                    "antigravity": ["usd": 0.0],
                ],
            ],
        ])
    }

    @Test
    func `overview aggregates all providers, preserves model colors across periods, and flags partial 24h`() throws {
        let state = try Self.overviewState()
        #expect(state.isRolling24hPartial)
        let spend = UsageOverviewSpend(state: state, now: F.now)
        #expect(spend.usesRolling24h)
        #expect(F.close(spend.last24hOrToday.usd, 42.0))
        // Yesterday: Claude 40 (30 Opus + 10 Fable) + Codex 15 + Antigravity 25 = 80.
        #expect(F.close(spend.week.usd, 80.0))

        // Claude row reports "1 of 2 accounts" when one failed.
        let claude = try #require(spend.provider(.claude))
        #expect(claude.subtitle == "1 of 2 accounts")

        // Model color stability: Neon keeps the same color in 30d and 90d and day detail.
        let neon30 = spend[.d30].rows.first { $0.label == "Neon" }?.color
        let neon90 = spend[.d90].rows.first { $0.label == "Neon" }?.color
        #expect(neon30 != nil)
        #expect(neon30 == neon90)

        // Day detail sorts active models above inactive ones.
        let day = spend.dayDetailCatalog(now: F.now).dayDetail(F.key(1), .d90, nil)
        #expect(F.close(day.totalUsd, 80.0))
        let topLabels = day.section2Rows.prefix(4).map(\.label)
        #expect(topLabels.first == "Opus")
        #expect(topLabels.contains("Neon"))
        #expect(topLabels.contains("Fable"))
        // None of the top active rows has $0 when 4 models were active that day.
        #expect(day.section2Rows.prefix(4).allSatisfy { $0.usd > 0 })
    }

    @Test
    func `weekly status distinguishes outage, multi-day warning, and healthy reserve`() throws {
        let now = F.now
        let nowSec = now.timeIntervalSince1970
        let outWindow = try JSONDecoder().decode(
            UsagePanelState.Window.self,
            from: JSONSerialization.data(withJSONObject: [
                "pct": 100.0, "measuredAt": nowSec - 60, "resetsAt": nowSec + 3600 * 5 + 600,
            ]))
        let outStatus = try #require(UsageOverviewSpend.weeklyStatus(outWindow, now: now))
        #expect(outStatus.tone == .bad)
        #expect(outStatus.text.hasPrefix("Out · back in "))

        let warnWindow = try JSONDecoder().decode(
            UsagePanelState.Window.self,
            from: JSONSerialization.data(withJSONObject: [
                "pct": 30.0, "measuredAt": nowSec - 60, "resetsAt": nowSec + 86400 * 5,
                "forecast": [
                    "at": nowSec - 60, "endPct": 140.0, "endLo": 120.0, "endHi": 160.0,
                    "hitAt": nowSec + 86400 * 3,
                ],
            ]))
        let warnStatus = try #require(UsageOverviewSpend.weeklyStatus(warnWindow, now: now))
        #expect(warnStatus.tone == .warning)
        #expect(warnStatus.text.hasPrefix("Out in ≈"))

        let goodWindow = try JSONDecoder().decode(
            UsagePanelState.Window.self,
            from: JSONSerialization.data(withJSONObject: [
                "pct": 25.0, "measuredAt": nowSec - 60, "resetsAt": nowSec + 86400 * 4,
                "forecast": [
                    "at": nowSec - 60, "endPct": 60.0, "endLo": 50.0, "endHi": 70.0,
                ],
            ]))
        let goodStatus = try #require(UsageOverviewSpend.weeklyStatus(goodWindow, now: now))
        #expect(goodStatus.tone == .good)
        #expect(goodStatus.text == "75% left")
    }

    @Test
    func `chart pointer ignores plain click, swallows double-click release, and unregisters detached view`() throws {
        let pointer = UsageChartPointer()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        var zoomed: UsageSpendRange?
        var doubleClicks = 0
        let days = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"]
        pointer.register(
            chartID: "test-chart",
            view: view,
            handlers: UsageChartPointer.Handlers(
                panelKey: "test-chart:day",
                plotBoundsInView: { NSRect(x: 0, y: 0, width: 300, height: 200) },
                dayKey: { x in
                    let idx = min(max(Int(x / 60), 0), days.count - 1)
                    return days[idx]
                },
                onDragEnded: { zoomed = $0 },
                onDoubleClick: { doubleClicks += 1 }))

        func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 100), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
        }

        // Plain single-day click does not zoom.
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseDown, x: 30)))
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseUp, x: 31)))
        #expect(zoomed == nil)

        // Multi-day drag zooms cleanly.
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseDown, x: 30)))
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseDragged, x: 150)))
        #expect(pointer.isDragging)
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseUp, x: 210)))
        #expect(zoomed == UsageSpendRange(startDay: "2026-11-01", endDay: "2026-11-04"))

        // Double-click invokes callback AND swallows its paired mouseUp so NSMenu never closes.
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseDown, x: 120, clicks: 2)))
        #expect(doubleClicks == 1)
        #expect(try pointer.routeTrackedEvent(mouse(.leftMouseUp, x: 120, clicks: 2)))
        // Subsequent stray mouseUp is not swallowed.
        #expect(try !pointer.routeTrackedEvent(mouse(.leftMouseUp, x: 120, clicks: 1)))

        // Unregister removes the chart cleanly.
        pointer.unregister(view: view)
        #expect(pointer.registeredChartIDs.isEmpty)
        #expect(pointer.activeChartPlotScreenRect() == nil)
    }
}

/// The per-day chart's y axis follows the shown days: a zoom whose busiest day is $600 tops out at $600.
struct LemelsonDayChartAxisTests {
    @Test
    func `rounds the busiest day up to a close round top`() throws {
        let cases: [(Double, Double, [Double])] = [
            (600, 600, [0, 200, 400, 600]),
            (364, 400, [0, 200, 400]),
            (700, 750, [0, 250, 500, 750]),
            (1001, 1200, [0, 400, 800, 1200]),
            (95, 100, [0, 50, 100]),
            (3.6, 4, [0, 2, 4]),
        ]
        for (max, top, ticks) in cases {
            let axis = try #require(UsageChartAxis(max: max))
            #expect(axis.top == top, "max \(max)")
            #expect(axis.ticks == ticks, "max \(max)")
        }
        #expect(UsageChartAxis(max: 0) == nil)
    }

    @Test
    func `stacks a day's bars before picking the top`() {
        let date = LemelsonRangeFixtures.now
        let bars = [
            UsageDayChartData.Bar(key: "a", date: date, series: "Claude", color: .other, usd: 503),
            UsageDayChartData.Bar(key: "a", date: date, series: "Antigravity", color: .other, usd: 97),
            UsageDayChartData.Bar(key: "b", date: date, series: "Claude", color: .other, usd: 300),
        ]
        let data = UsageDayChartData(
            period: .d30, domain: date...date, bars: bars, hint: "", legend: [], dayNotes: [:],
            emptyText: "", chipLimit: nil, centsInChips: false)
        #expect(data.yAxis?.top == 600)
    }
}
