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
    func `an older model without a price says no price in the longer periods`() throws {
        var block = Self.block()
        var daily = try #require(block["daily"] as? [[String: Any]])
        // 70 days back, outside the 30-day model list: a model without a price, named by the day itself.
        var old = Self.day(70, ["gpt-legacy-review": (0, 4e6)])
        old["unpriced"] = ["gpt-legacy-review": 4e6]
        daily.append(old)
        block["daily"] = daily
        let (spend, _) = try Self.spend(block)
        let quarter = spend[.d90]
        #expect(quarter.otherMembers.contains { $0.hasSuffix(" no price") && !$0.hasPrefix("Auto Review") })
        #expect(!quarter.otherMembers.contains { $0.contains("<$0.01") && $0.lowercased().contains("legacy") })
        // A shape the app does not know drops the key, not the summary.
        old["unpriced"] = "?"
        daily[daily.count - 1] = old
        block["daily"] = daily
        #expect(throws: Never.self) { try Self.spend(block) }
    }

    @Test
    func `weekly windows read the approximate and early-reset flags`() throws {
        let stamp = Self.now.timeIntervalSince1970
        let block = Self.block(extra: ["weeks": [
            ["start": stamp - 14 * 86400, "end": stamp - 7 * 86400, "approx": true, "peakPct": NSNull(),
             "usd": ["other": 4.2], "tokens": 1.8e7],
            ["start": stamp - 7 * 86400, "end": stamp - 5 * 86400, "scheduledEnd": stamp, "peakPct": 58,
             "usd": ["other": 8.6], "tokens": 3.6e7, "approx": false],
        ]])
        let state = try LemelsonProviderBlockTests.state(key: "codex", block: block)
        let weeks = try #require(state.codex?.account.weeks)
        #expect(weeks.count == 2)
        #expect(weeks[0].approx == true && weeks[0].peakPct == nil)
        #expect(weeks[1].approx == false && weeks[1].scheduledEnd == stamp && weeks[1].peakPct == 58)
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
        // The collector's own name: "account", the first 12 hex characters of the key's SHA-256
        // (usage/quota_provider.py account_hash). The same account passes, another one gets the notice.
        let real = "codex:v1:provider-account:16f67a35-0ccf-4275-b37e-2a012624a6d6"
        let hashed = try LemelsonProviderBlockTests.state(
            key: "codex", block: Self.block(extra: ["quotaSource": ["account": "b77c53f4e468"]]))
        let parsed = try #require(hashed.codex)
        #expect(parsed.quotaSource?.accountKey == "b77c53f4e468")
        #expect(!UsageProviderPage.limitsOfAnotherAccount(parsed, shown: real))
        #expect(UsageProviderPage.limitsOfAnotherAccount(parsed, shown: "codex:v1:provider-account:other"))
        // Antigravity: its block filed under "antigravity", read by the Antigravity page. CodexBar's key there
        // is a 64-hex digest; the collector names it by the first 12 hex of the digest's own SHA-256.
        let digest = "4b32437a24c18ef0a8c42f256f2a7309e0bc788adea89b2efea7ccb1c9896dcf"
        let antigravity = try LemelsonProviderBlockTests.state(
            key: "antigravity", block: Self.block(extra: ["quotaSource": ["account": "f69e38e798ab"]]))
        #expect(antigravity.codex == nil)
        let gemini = try #require(antigravity.antigravity)
        #expect(!UsageProviderPage.limitsOfAnotherAccount(gemini, shown: digest))
        let page = try #require(UsageProviderPage(
            spec: .antigravity, state: antigravity, now: Self.now, width: 310, accountKey: digest))
        #expect(page.rows.contains { $0.part == .limit(.week) })
        let stranger = try #require(UsageProviderPage(
            spec: .antigravity, state: antigravity, now: Self.now, width: 310, accountKey: String(digest.reversed())))
        #expect(stranger.rows.contains { $0.part == .notice })
        // A name too short to be the hash is compared as a key only.
        let short = try LemelsonProviderBlockTests.state(
            key: "codex", block: Self.block(extra: ["quotaSource": ["account": "b77c"]]))
        #expect(try UsageProviderPage.limitsOfAnotherAccount(#require(short.codex), shown: real))
    }

    @Test @MainActor
    func `another account's numbers hide the plan, the reading age and plan worth, not the spend`() throws {
        let block = Self.block(extra: [
            "quotaSource": ["account": "b77c53f4e468"],
            "value": ["confident": true, "planName": "Plus", "planPriceUsd": 20, "monthUsd": 289, "timesPrice": 14.5,
                      "byModel": []],
        ])
        let state = try LemelsonProviderBlockTests.state(key: "codex", block: block)
        let mine = try #require(UsageProviderPage(
            spec: .codex, state: state, now: Self.now, width: 310,
            accountKey: "codex:v1:provider-account:16f67a35-0ccf-4275-b37e-2a012624a6d6"))
        #expect(mine.valueRow != nil)
        let header = try #require(mine.rows.first { $0.part == .header })
        #expect(!header.heightFingerprint.contains(":other"))

        let other = try #require(UsageProviderPage(
            spec: .codex, state: state, now: Self.now, width: 310, accountKey: "codex:v1:provider-account:B"))
        #expect(other.valueRow == nil)
        #expect(other.lineRows.allSatisfy { $0.part != .value })
        #expect(other.rows.contains { $0.part == .spend })
        let otherHeader = try #require(other.rows.first { $0.part == .header })
        #expect(otherHeader.heightFingerprint.contains(":other"))
    }

    @Test
    func `one freshness check for the row and the panel`() throws {
        let stamp = Self.now.timeIntervalSince1970
        let stale = UsageLimitReading.freshness + 60
        // A forecast made 6 minutes ago from a reading that is now too old: neither the row nor the panel use it.
        let oldReading = try LemelsonLimitCardTests.window(
            pct: 40, resetIn: 86400, age: stale, forecast: ["at": stamp - 360, "endPct": 60])
        #expect(oldReading.liveForecast(now: Self.now) == nil)
        #expect(UsageLimitVerdict(window: oldReading, now: Self.now) == .unknown)
        // A fresh reading with an old forecast: no forecast either.
        let oldForecast = try LemelsonLimitCardTests.window(
            pct: 40, resetIn: 86400, forecast: ["at": stamp - stale, "endPct": 60])
        #expect(oldForecast.liveForecast(now: Self.now) == nil)
        #expect(UsageLimitVerdict(window: oldForecast, now: Self.now) == .unknown)
        // Both fresh: the panel and the row see the same forecast.
        let fresh = try LemelsonLimitCardTests.window(
            pct: 40, resetIn: 86400, forecast: ["at": stamp - 60, "endPct": 60, "endHi": 70])
        #expect(fresh.liveForecast(now: Self.now) != nil)
        #expect(UsageLimitVerdict(window: fresh, now: Self.now) == .enough)
        // Out now by the forecast (its run-out time passed) and by the reading (100 %): the same verdict, the
        // panel tells them apart by the reading.
        let passed = try LemelsonLimitCardTests.window(
            pct: 97, resetIn: 86400, forecast: ["at": stamp - 600, "endPct": 130, "hitAt": stamp - 60])
        #expect(UsageLimitVerdict(window: passed, now: Self.now) == .outNow)
        #expect((passed.pct ?? 0) < 100)
        let full = try LemelsonLimitCardTests.window(pct: 100, resetIn: 86400)
        #expect(UsageLimitVerdict(window: full, now: Self.now) == .outNow)
    }

    @Test
    func `sessions that fit start after the current 5-hour window`() throws {
        let state = try LemelsonProviderBlockTests.state(key: "codex", block: LemelsonProviderBlockTests.codexBlock())
        let block = try #require(state.codex)
        let left = try #require(block.sessionsLeft(for: .week, now: Self.now))
        // The 5-hour window is 11 % used and resets in 3 h; the week resets in 48 h.
        let current = try #require(left.current)
        #expect(abs(current.left - 0.89) < 1e-9)
        #expect(current.resetsAt == Self.now.timeIntervalSince1970 + 3 * 3600)
        #expect(abs(left.spans - 9) < 1e-9) // (48 h − 3 h) / 5 h
        #expect(left.fit == 9)
        #expect(abs(left.available - 9.89) < 1e-9)
        #expect(left.fitText == "9 more fit before reset")
        #expect(left.explanation.contains("The current session has 89% left until "))
        #expect(left.explanation.contains("9 full sessions fit after it before the reset"))

        // No running 5-hour window: full sessions count from now.
        var bare = LemelsonProviderBlockTests.codexBlock()
        var windows = try #require(bare["windows"] as? [String: Any])
        var five = try #require(windows["5h"] as? [String: Any])
        five["rolled"] = true
        windows["5h"] = five
        bare["windows"] = windows
        let rolled = try #require(try LemelsonProviderBlockTests.state(key: "codex", block: bare).codex)
        let fresh = try #require(rolled.sessionsLeft(for: .week, now: Self.now))
        #expect(fresh.current == nil)
        #expect(abs(fresh.spans - 48.0 / 5) < 1e-9)
        #expect(fresh.fitText == "9 fit before reset")
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
