import AppKit
import Foundation
@testable import CodexBar
@testable import LemelsonUsageKit
import Testing

// lemelson: Codex and Antigravity limits told apart into You, Others and Not split yet (`Window.Split`,
// `UsageSegment.build` for `.local`, the limit weeks), the cumulative timeline of every account
// (`overviewTimeline`, `UsageOverviewRecent`) and Overview's two modes (`UsageOverviewPage`, `UsageOverviewMode`,
// `LemelsonModeTab.overview`).

/// Shared fixtures: windows, splits and a small timeline, decoded from JSON as the collector writes them.
enum LemelsonSplitFixtures {
    static let now = LemelsonRangeFixtures.now
    static let firstCodex = "11111111-1111-4111-8111-111111111111"
    static let secondCodex = "22222222-2222-4222-8222-222222222222"

    static var stamp: Double {
        self.now.timeIntervalSince1970 - 60
    }

    static func split(
        you: Double, others: Double, unknown: Double = 0, method: String, preliminary: Bool = false,
        reason: String? = nil) -> [String: Any]
    {
        ["youPct": you, "othersPct": others, "unknownPct": unknown, "method": method, "preliminary": preliminary,
         "reason": reason ?? NSNull()]
    }

    /// A weekly window read a minute ago that resets in three days.
    static func window(pct: Double, split: Any? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var window: [String: Any] = [
            "pct": pct, "measuredAt": self.stamp, "resetsAt": self.stamp + 3 * 86400,
            "start": self.stamp - 4 * 86400, "source": "live", "rolled": false,
        ]
        if let split {
            window["split"] = split
        }
        return window.merging(extra) { $1 }
    }

    static func decodeWindow(_ json: [String: Any]) throws -> UsagePanelState.Window {
        try JSONDecoder().decode(UsagePanelState.Window.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func decodeWeek(_ json: [String: Any]) throws -> UsagePanelState.Week {
        try JSONDecoder().decode(UsagePanelState.Week.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static let source = UsageLocalSource(app: "Codex", providerNote: "Codex cloud or another computer", stretchUsd: 10)

    static func segments(pct: Double, split: [String: Any]) throws -> [UsageSegment] {
        let window = try self.decodeWindow(self.window(pct: pct, split: split))
        return UsageSegment.build(for: window, kind: .week, sources: .local(self.source))
    }

    // MARK: - Overview

    static func claude(
        _ uuid: String, _ name: String, pct: Double, mine: Double?, active: Bool = false) -> [String: Any]
    {
        var window = self.window(pct: pct)
        window["mine"] = mine ?? NSNull()
        window["outside"] = mine.map { pct - $0 } ?? NSNull()
        return ["uuid": uuid, "name": name, "short": name, "active": active, "planName": "Max 5x",
                "windows": ["7d": window], "daily": []]
    }

    /// Codex with two accounts (one calibrated, one idle); the block's own window repeats the active account's.
    static func codex() -> [String: Any] {
        let first = self.window(pct: 12, split: self.split(you: 4, others: 8, method: "calibrated"))
        let second = self.window(pct: 1, split: self.split(you: 0, others: 1, method: "idle"))
        return [
            "uuid": "codex", "name": "Codex", "short": "Codex", "beta": true, "planName": "Plus",
            "windows": ["7d": first], "daily": [],
            "accounts": [
                ["uuid": self.firstCodex, "name": "alpha@example.com", "short": "Alpha", "active": true,
                 "planName": "Plus", "windows": ["7d": first], "daily": []],
                ["uuid": self.secondCodex, "name": "beta@example.com", "short": "Beta", "active": false,
                 "planName": "Pro 5x", "windows": ["7d": second], "daily": []],
            ],
        ]
    }

    /// Antigravity without a rate: a proven share of others and the rest not split.
    static func antigravity() -> [String: Any] {
        ["uuid": "antigravity", "name": "Antigravity", "short": "Antigravity", "beta": true,
         "planName": "Google AI Ultra 5x", "daily": [],
         "windows": ["7d": self.window(
             pct: 60, split: self.split(you: 0, others: 20, unknown: 40, method: "floor", reason: "uncovered"))]]
    }

    static let timelineKeys = [
        "claude:a", "claude:b", "codex:\(firstCodex)", "codex:\(secondCodex)", "antigravity:antigravity",
    ]

    /// Five grid points, cumulative: `you`, `others` and `unknown` are the values at the end of the range.
    static func series(
        you: Double, others: Double, unknown: Double = 0, flags: Int = 4, rate: Double? = 1000) -> [String: Any]
    {
        let steps = (0...4).map { Double($0) / 4 }
        var series: [String: Any] = [
            "quota": steps.map { [you * $0, others * $0, unknown * $0, Double(flags)] },
            "usdYou": steps.map { you * $0 * (rate ?? 200) / 100 },
            "tokensYou": you * 1_000_000,
        ]
        series["usdOthers"] = rate.map { rate in steps.map { others * $0 * rate / 100 } } ?? NSNull()
        return series
    }

    static func range(hours: Double, step: Double = 21600) -> [String: Any] {
        let to = self.now.timeIntervalSince1970
        let ends: [(Double, Double, Double, Double?)] = [
            (10, 5, 0, 1000), (2, 6, 0, 1000), (4, 8, 0, 100), (0, 1, 0, nil), (0, 20, 40, 500),
        ]
        var accounts: [String: Any] = [:]
        for (key, end) in zip(self.timelineKeys, ends) {
            accounts[key] = self.series(you: end.0, others: end.1, unknown: end.2, rate: end.3)
        }
        var combined = self.series(you: 0.16, others: 0.40, unknown: 0.40, flags: 13)
        combined["usdYou"] = [0.0, 30, 60, 90, 124]
        combined["usdOthers"] = [0.0, 50, 100, 150, 218]
        combined.merge([
            "unratedAccounts": [self.timelineKeys[3]], "totalYouUsd": 124.0, "totalYouTokens": 16_000_000.0,
            "totalOthersUsd": 218.0, "totalYouQuota": 0.16, "totalOthersQuota": 0.40, "totalUnknownQuota": 0.40,
        ]) { $1 }
        return ["from": to - hours * 3600, "to": to, "stepSec": step, "combined": combined, "accounts": accounts]
    }

    static func timeline() -> [String: Any] {
        let asOf = self.now.timeIntervalSince1970
        let plans = ["Max 5x", "Max 5x", "Plus", "Pro 5x", "Google AI Ultra 5x"]
        return [
            "version": 1, "asOf": asOf, "quotaWindow": "7d",
            "providers": ["claude": ["builtAt": asOf, "partial": false],
                          "codex": ["builtAt": asOf, "partial": true],
                          "antigravity": ["builtAt": asOf, "partial": false]],
            "accounts": zip(self.timelineKeys, plans).enumerated().map { index, item -> [String: Any] in
                let parts = item.0.split(separator: ":", maxSplits: 1).map(String.init)
                return ["key": item.0, "provider": parts[0], "uuid": parts[1], "short": "Account \(index)",
                        "planName": item.1, "active": index == 0, "rated": index != 3,
                        "usdPer100": index == 3 ? NSNull() : 1000.0, "quotaThrough": asOf - 30]
            },
            "ranges": ["24h": self.range(hours: 24), "72h": self.range(hours: 72, step: 64800),
                       "7d": self.range(hours: 168, step: 151_200)],
        ]
    }

    /// Two Claude accounts, Codex with two accounts, Antigravity; with the timeline unless told otherwise.
    static func overviewState(timeline: Any? = LemelsonSplitFixtures.timeline()) throws -> UsagePanelState {
        var summary: [String: Any] = [
            "accounts": [
                self.claude("a", "Alpha", pct: 49, mine: 44, active: true),
                self.claude("b", "Beta", pct: 30, mine: nil),
            ],
            "codex": self.codex(),
            "antigravity": self.antigravity(),
        ]
        if let timeline {
            summary["overviewTimeline"] = timeline
        }
        return try LemelsonRangeFixtures.state(summary)
    }

    static func defaults() -> UserDefaults {
        let name = "lemelson-overview-limits-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

// MARK: - Decoding

@Suite
struct LemelsonSplitDecodingTests {
    private typealias Fixtures = LemelsonSplitFixtures

    @Test
    func `a window decodes its split and five element series`() throws {
        let stamp = Fixtures.stamp
        let window = try Fixtures.decodeWindow(Fixtures.window(
            pct: 12,
            split: Fixtures.split(
                you: 8, others: 3, unknown: 1, method: "mixed", preliminary: true, reason: "rounding"),
            extra: ["mine": NSNull(), "outside": NSNull(),
                    "series": [[stamp - 3600, 6.0, 4.0, 2.0, 0.0], [stamp, 12.0, NSNull(), 3.0, 1.0],
                               [stamp + 1, 12.0, 8.0]]]))
        let split = try #require(window.split)
        #expect(split.youPct == 8)
        #expect(split.othersPct == 3)
        #expect(split.unknownPct == 1)
        #expect(split.method == .mixed)
        #expect(split.preliminary)
        #expect(split.reason == "rounding")
        #expect(split.total == 12)
        #expect(window.mine == nil)
        #expect(window.outside == nil)
        let points = window.points
        #expect(points.count == 3)
        #expect(points[0].mine == 4)
        #expect(points[0].others == 2)
        #expect(points[0].unknown == 0)
        // No rate at that reading: this Mac's part is null, the proven others and the unsplit part stay.
        #expect(points[1].mine == nil)
        #expect(points[1].others == 3)
        #expect(points[1].unknown == 1)
        // An older three-element reading.
        #expect(points[2].mine == 8)
        #expect(points[2].others == nil)
        #expect(points[2].unknown == nil)
    }

    @Test
    func `a malformed split costs neither the window nor its reading`() throws {
        let junk = try Fixtures.decodeWindow(Fixtures.window(pct: 12, split: "calibrated"))
        #expect(junk.split == nil)
        #expect(junk.pct == 12)

        let odd = try Fixtures.decodeWindow(Fixtures.window(
            pct: 12, split: ["youPct": -3.0, "othersPct": "many", "method": "astrology"]))
        let split = try #require(odd.split)
        #expect(split.youPct == 0)
        #expect(split.othersPct == 0)
        #expect(split.unknownPct == 0)
        #expect(split.method == .unknown)
        #expect(!split.preliminary)
        #expect(split.reason == nil)

        let none = try Fixtures.decodeWindow(Fixtures.window(pct: 12))
        #expect(none.split == nil)
    }

    @Test
    func `a week decodes its unsplit part and method leniently`() throws {
        let end = Fixtures.stamp
        let week = try Fixtures.decodeWeek([
            "start": end - 7 * 86400, "end": end, "peakPct": 50.0, "minePct": NSNull(), "othersPct": 10.0,
            "unknownPct": 40.0, "splitMethod": "floor",
        ])
        #expect(week.minePct == nil)
        #expect(week.othersPct == 10)
        #expect(week.unknownPct == 40)
        #expect(week.splitMethod == "floor")

        let odd = try Fixtures.decodeWeek([
            "start": end - 7 * 86400, "end": end, "peakPct": 50.0, "unknownPct": "a lot", "splitMethod": 7,
        ])
        #expect(odd.peakPct == 50)
        #expect(odd.unknownPct == nil)
        #expect(odd.splitMethod == nil)

        let negative = try Fixtures.decodeWeek(["start": end - 7 * 86400, "end": end, "unknownPct": -2.0])
        #expect(negative.unknownPct == nil)
    }

    @Test
    func `the timeline decodes its ranges accounts and flags`() throws {
        let timeline = try #require(Fixtures.overviewState().overviewTimeline)
        #expect(timeline.version == 1)
        #expect(timeline.quotaWindow == "7d")
        #expect(timeline.partialProviders == ["codex"])
        #expect(timeline.accounts.map(\.key) == Fixtures.timelineKeys)
        #expect(Set(timeline.ranges.keys) == ["24h", "72h", "7d"])

        let range = try #require(timeline.range("24h"))
        #expect(range.stepSec == 21600)
        #expect(range.count == 5)
        #expect(range.time(at: 4) == range.to)
        #expect(range.combined.quota.count == 5)
        #expect(range.combined.unratedAccounts == [Fixtures.timelineKeys[3]])
        #expect(range.combined.totalYouUsd == 124)
        #expect(range.combined.totalUnknownQuota == 0.40)
        let last = try #require(range.combined.sample(at: 4))
        #expect(last.you == 0.16)
        #expect(last.flags == [.gap, .calibrated, .boundary])
        #expect(!last.flags.contains(.incomplete))
        #expect(range.accounts.count == 5)

        // An account without a rate: no dollars for others' use, percent only.
        let unrated = try #require(timeline.entry(Fixtures.timelineKeys[3]))
        #expect(!unrated.rated)
        #expect(unrated.usdPer100 == nil)
        let series = try #require(range.accounts[unrated.key])
        #expect(series.usdOthers == nil)
        #expect(series.usdOthers(at: 4) == nil)
        #expect(series.sample(at: 4)?.others == 1)
        let rated = try #require(range.accounts[Fixtures.timelineKeys[0]])
        #expect(rated.usdYou(at: 4) == 100)
        #expect(rated.usdOthers(at: 4) == 50)
        #expect(rated.tokensYou == 10_000_000)
    }

    @Test
    func `a malformed part of the timeline drops only itself`() throws {
        var timeline = Fixtures.timeline()
        var ranges = try #require(timeline["ranges"] as? [String: Any])
        // A range without a step, and one whose samples are partly unusable.
        ranges["72h"] = ["from": 0, "to": 10, "stepSec": 0, "combined": [String: Any]()]
        var week = Fixtures.range(hours: 168, step: 151_200)
        var combined = try #require(week["combined"] as? [String: Any])
        combined["quota"] = [NSNull(), [1.0, 2.0], [0.1, 0.2, 0.0, 6.0], "soon", [0.3, 0.4, 0.1, NSNull()]] as [Any]
        combined["usdYou"] = [0.0, NSNull(), 40.0, "n/a", 90.0] as [Any]
        week["combined"] = combined
        var accounts = try #require(week["accounts"] as? [String: Any])
        accounts[Fixtures.timelineKeys[1]] = "broken"
        week["accounts"] = accounts
        ranges["7d"] = week
        timeline["ranges"] = ranges
        var entries = try #require(timeline["accounts"] as? [[String: Any]])
        entries.append(["provider": "codex", "short": "No key"])
        timeline["accounts"] = entries

        let decoded = try #require(Fixtures.overviewState(timeline: timeline).overviewTimeline)
        #expect(Set(decoded.ranges.keys) == ["24h", "7d"])
        #expect(decoded.accounts.count == 5)
        let range = try #require(decoded.range("7d"))
        #expect(range.accounts.count == 4)
        #expect(range.accounts[Fixtures.timelineKeys[1]] == nil)
        let quota = range.combined.quota
        #expect(quota.count == 5)
        #expect(quota[0] == nil)
        #expect(quota[1] == nil)
        #expect(quota[3] == nil)
        // Nothing before the first good sample; a gap after it reads as the last one.
        #expect(range.combined.sample(at: 1) == nil)
        #expect(range.combined.sample(at: 2)?.flags == [.incomplete, .calibrated])
        #expect(range.combined.sample(at: 3)?.others == 0.2)
        #expect(range.combined.sample(at: 4)?.flags == [])
        #expect(range.combined.usdYou(at: 1) == 0)
        #expect(range.combined.usdYou(at: 3) == 40)
    }

    @Test
    func `an error block or no block is no timeline and keeps the summary`() throws {
        let failed = try Fixtures.overviewState(timeline: ["error": "timeline-failed:KeyError"])
        #expect(failed.overviewTimeline == nil)
        #expect(failed.accounts.count == 2)
        #expect(failed.codex?.accounts.count == 2)

        let junk = try Fixtures.overviewState(timeline: "later")
        #expect(junk.overviewTimeline == nil)
        #expect(junk.accounts.count == 2)

        let missing = try Fixtures.overviewState(timeline: nil)
        #expect(missing.overviewTimeline == nil)
        #expect(!UsageOverviewRecent(state: missing).isAvailable)
    }
}

// MARK: - You, Others, Not split yet

@Suite
struct LemelsonLocalSegmentTests {
    private typealias Fixtures = LemelsonSplitFixtures

    @Test
    func `a calibrated reading is you and others`() throws {
        let segments = try Fixtures.segments(pct: 12, split: Fixtures.split(you: 8, others: 4, method: "calibrated"))
        #expect(segments.map(\.kind) == [.you, .others])
        #expect(segments.map(\.chipText) == ["You 8%", "Others 4%"])
        #expect(segments.map(\.barValue) == [8, 4])
        #expect(segments.allSatisfy { !$0.atLeast && !$0.approximate && !$0.isHatched })
        #expect(segments[0].longLabel == "You: Codex on this Mac")
        #expect(segments[0].local == Fixtures.source)
    }

    @Test
    func `a rate measured once marks you as approximate`() throws {
        let segments = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 8, others: 4, method: "calibrated", preliminary: true))
        #expect(segments.map(\.chipText) == ["You ≈8%", "Others 4%"])
        #expect(segments[0].approximate)
        #expect(!segments[1].approximate)
    }

    @Test
    func `an idle Mac reads you at zero and all of it others`() throws {
        let segments = try Fixtures.segments(pct: 12, split: Fixtures.split(you: 0, others: 12, method: "idle"))
        #expect(segments.map(\.kind) == [.you, .others])
        #expect(segments.map(\.chipText) == ["You 0%", "Others 12%"])
        #expect(segments.map(\.barValue) == [0, 12])
        #expect(!segments[1].atLeast)
    }

    @Test
    func `without a rate others is a floor and nothing is orange`() throws {
        let segments = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 0, others: 4, unknown: 8, method: "floor", reason: "uncovered"))
        #expect(segments.map(\.kind) == [.others, .unknown])
        #expect(segments.map(\.chipText) == ["Others 4%+", "Not split yet 8%"])
        #expect(segments[0].atLeast)
        #expect(segments[0].longValueText == "at least 4%")
        #expect(segments[1].isHatched)
        #expect(segments[1].longLabel == "Not split yet: you or others")

        // A part the collector called this Mac's without a rate is not split either.
        let stray = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 3, others: 4, unknown: 5, method: "floor"))
        #expect(stray.map(\.kind) == [.others, .unknown])
        #expect(stray.map(\.chipText) == ["Others 4%+", "Not split yet 8%"])
        #expect(stray[1].barValue == 8)
    }

    @Test
    func `an unknown reading is one hatched part`() throws {
        let segments = try Fixtures.segments(
            pct: 12,
            split: Fixtures.split(you: 0, others: 0, unknown: 12, method: "unknown", reason: "missing_baseline"))
        #expect(segments.map(\.kind) == [.unknown])
        #expect(segments[0].chipText == "Not split yet 12%")
        #expect(segments[0].barValue == 12)
        #expect(segments[0].isHatched)
    }

    @Test
    func `a mixed reading keeps three parts that add up to the reading`() throws {
        let segments = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 6.4, others: 2.6, unknown: 3, method: "mixed"))
        #expect(segments.map(\.kind) == [.you, .others, .unknown])
        #expect(segments.map(\.chipText) == ["You 6%", "Others 3%", "Not split yet 3%"])
        #expect(segments.map(\.value).reduce(0, +) == 12)
        #expect(LemelsonRangeFixtures.close(segments.map(\.barValue).reduce(0, +), 12))

        // Mixed with nothing of this Mac's: the same as a floor.
        let bare = try Fixtures.segments(pct: 12, split: Fixtures.split(you: 0, others: 5, unknown: 7, method: "mixed"))
        #expect(bare.map(\.kind) == [.others, .unknown])
        #expect(bare[0].atLeast)
    }

    @Test
    func `the parts follow the reading the row shows`() throws {
        // The collector split 12%; a newer reading says 15%.
        let segments = try Fixtures.segments(pct: 15, split: Fixtures.split(you: 8, others: 4, method: "calibrated"))
        #expect(segments.map(\.barValue) == [10, 5])
        #expect(segments.map(\.chipText) == ["You 10%", "Others 5%"])
        #expect(UsageSegment.rounded([7.5, 4.5, 0], to: 12) == [8, 4, 0])
        #expect(UsageSegment.rounded([6.4, 2.6, 3], to: 12) == [6, 3, 3])
    }

    @Test
    func `a window without a split stays one plain part`() throws {
        let window = try Fixtures.decodeWindow(Fixtures.window(pct: 12))
        let local = UsageSegment.build(for: window, kind: .week, sources: .local(Fixtures.source))
        #expect(local.map(\.kind) == [.all])
        #expect(UsageProviderSpec.codex.sources(for: window, block: nil) == .single)
        #expect(!UsageLimitSources.single.hasParts)

        let split = try Fixtures.decodeWindow(Fixtures.window(
            pct: 12, split: Fixtures.split(you: 8, others: 4, method: "calibrated")))
        let sources = UsageProviderSpec.codex.sources(for: split, block: nil)
        #expect(sources.local?.app == "Codex")
        #expect(sources.hasParts)
        #expect(UsageProviderPage.splitFingerprint(split) == ":calibrated:8/4/0")
        #expect(UsageProviderPage.splitFingerprint(window).isEmpty)
    }

    @Test
    func `every method has a sentence and a floor names the spend it waits for`() {
        let source = Fixtures.source
        typealias Split = UsagePanelState.Window.Split
        let floor = source.note(for: Split(youPct: 0, othersPct: 4, unknownPct: 8, method: .floor))
        #expect(floor.contains("$10+ of Codex use on this Mac"))
        let unknown = UsageLocalSource(app: "Codex", providerNote: "elsewhere")
            .note(for: Split(youPct: 0, othersPct: 0, unknownPct: 8, method: .unknown))
        #expect(unknown.contains("after more Codex use"))
        let once = source.note(for: Split(youPct: 8, othersPct: 4, method: .calibrated, preliminary: true))
        #expect(once.contains("measured once"))
        let mixed = source.note(for: Split(
            youPct: 6, othersPct: 3, unknownPct: 3, method: .mixed, reason: "possible_local_activity"))
        #expect(mixed.contains("this Mac was active at that time"))
        #expect(source.note(for: Split(youPct: 0, othersPct: 12, method: .idle)).contains("idle on this Mac"))
        #expect(UsageLocalSource.reasonText("no such reason") == UsageLocalSource.reasonText(nil))
    }
}

// MARK: - Weeks

@Suite
struct LemelsonLocalWeekTests {
    private typealias Fixtures = LemelsonSplitFixtures

    private func limit(_ fields: [String: Any], sources: UsageLimitSources? = nil) throws -> UsageWeekLimit {
        let end = Fixtures.stamp - 86400
        let week = try Fixtures.decodeWeek(
            ["start": end - 7 * 86400, "end": end, "peakFinal": true].merging(fields) { $1 })
        return UsageWeekLimit(
            week: week, window: nil, capacity: 500, fableWeight: 1, now: Fixtures.now,
            sources: sources ?? .local(Fixtures.source))
    }

    @Test
    func `a finished week keeps the collectors three parts`() throws {
        let week = try self.limit([
            "peakPct": 50.0, "minePct": 20.0, "othersPct": 25.0, "unknownPct": 5.0, "splitMethod": "mixed",
        ])
        #expect(week.used == 50)
        #expect(week.mine == 20)
        #expect(week.others == 25)
        #expect(week.unknown == 5)
        #expect(week.barParts.map(\.0) == [20, 25, 5])
        #expect(week.hatchedBarParts == [2])
    }

    @Test
    func `without a rate a week never invents you or others`() throws {
        let week = try self.limit([
            "peakPct": 50.0, "minePct": NSNull(), "othersPct": 10.0, "unknownPct": 30.0, "splitMethod": "floor",
            "usd": ["opus": 0, "fable": 0, "other": 120.0],
        ])
        // No orange from the week's dollars, and others stays what was proven: the rest is not split.
        #expect(week.mine == nil)
        #expect(week.others == 10)
        #expect(week.unknown == 40)
        #expect(week.barParts.map(\.0) == [0, 10, 40])

        // A number in `minePct` does not make a floor week's "you": without a rate it is no measurement.
        let stray = try self.limit([
            "peakPct": 50.0, "minePct": 3.0, "othersPct": 10.0, "unknownPct": 40.0, "splitMethod": "unknown",
        ])
        #expect(stray.mine == nil)
        #expect(stray.unknown == 40)

        // An explicit zero is the collector saying this Mac's part is known to be nothing: it is kept, and
        // shown as a plain "you 0%".
        let zero = try self.limit([
            "peakPct": 50.0, "minePct": 0.0, "othersPct": 10.0, "unknownPct": 40.0, "splitMethod": "unknown",
        ])
        #expect(zero.mine == 0)
        #expect(zero.others == 10)
        #expect(zero.unknown == 40)
        #expect(zero.barParts.map(\.0) == [0, 10, 40])
        #expect(zero.tail == ": you 0%, others ≈10%, 40% not split")
        let proven = try self.limit([
            "peakPct": 50.0, "minePct": 0.0, "othersPct": 50.0, "unknownPct": 0.0, "splitMethod": "floor",
        ])
        #expect(proven.mine == 0)
        #expect(proven.tail == ": you 0%, others ≈50% · 50% unused")

        // An older week without any parts: all of it is not split.
        let bare = try self.limit(["peakPct": 50.0])
        #expect(bare.mine == nil)
        #expect(bare.others == nil)
        #expect(bare.unknown == 50)
    }

    @Test
    func `a page without a split shows the week as one quota`() throws {
        let week = try self.limit(
            ["peakPct": 50.0, "minePct": 20.0, "othersPct": 25.0, "unknownPct": 5.0], sources: .single)
        #expect(week.mine == nil)
        #expect(week.others == nil)
        #expect(week.unknown == nil)
        #expect(week.barParts.count == 1)
        #expect(week.hatchedBarParts.isEmpty)
    }
}

// MARK: - Overview: Limits and Spend

@MainActor
@Suite(.serialized)
struct LemelsonOverviewLimitsTests {
    private typealias Fixtures = LemelsonSplitFixtures

    private static let accountIDs = [
        "claude-a", "claude-b", "codex-\(LemelsonSplitFixtures.firstCodex)",
        "codex-\(LemelsonSplitFixtures.secondCodex)", "antigravity-antigravity",
    ]

    private func page(_ state: UsagePanelState, mode: UsageOverviewMode?) -> UsageOverviewPage {
        UsageOverviewPage(state: state, now: Fixtures.now, width: 310, detailWidth: 340, mode: mode)
    }

    @Test
    func `limits lists the chart then every account once`() throws {
        let page = try self.page(Fixtures.overviewState(), mode: .limits)
        let prefix = UsageOverviewPage.idPrefix
        #expect(page.rows.map(\.id) == ["limits-recent", "limits-head"].map { prefix + $0 }
            + Self.accountIDs.map { prefix + "limits-acct-" + $0 } + [prefix + "limits-footer"])
        // Codex's accounts stand in for its block: no row for the block itself.
        #expect(!page.rows.contains { $0.id == prefix + "limits-acct-codex-codex" })
        #expect(page.limitAccounts.map(\.id) == Self.accountIDs)
        #expect(page.limitAccounts.map(\.timelineKey) == Fixtures.timelineKeys)
        #expect(page.limitAccounts.map(\.subtitle) == [
            "Claude Max 5x", "Claude Max 5x", "Codex Plus", "Codex Pro 5x", "Ultra 5x",
        ])
        #expect(page.mode == .limits)

        let recent = try #require(page.rows.first)
        #expect(recent.part == .recent)
        #expect(recent.hasControls)
        #expect(recent.detail == nil)
        #expect(page.chartRowID == UsageOverviewRecent.chartID)
        #expect(page.chartDayDetail?.key == UsageOverviewRecent.panelKey)
        _ = page.chartDayDetail?.build()

        // Every account row opens its weekly detail panel and leads to its provider's tab.
        let accounts = page.rows.filter { $0.id.contains("limits-acct-") }
        #expect(accounts.map(\.providerKind) == [.claude, .claude, .codex, .codex, .antigravity])
        #expect(Set(accounts.map(\.heightCacheScope)).count == 1)
        #expect(Set(accounts.map(\.heightFingerprint)).count == accounts.count)
        for row in accounts {
            let detail = try #require(row.detail)
            _ = detail()
        }
        for account in page.limitAccounts {
            #expect(account.detail(in: try Fixtures.overviewState(), now: Fixtures.now, width: 340) != nil)
        }
    }

    @Test
    func `every account's bar is you others and not split`() throws {
        let accounts = try UsageOverviewLimitAccount.all(in: Fixtures.overviewState(), now: Fixtures.now)
        let parts = accounts.map { $0.segments.map(\.kind) }
        // Claude with this Mac's part, Claude without one, Codex calibrated, Codex idle, Antigravity floor.
        #expect(parts == [[.you, .others], [.unknown], [.you, .others], [.you, .others], [.others, .unknown]])
        #expect(accounts[0].segments.map(\.barValue) == [44, 5])
        #expect(accounts[1].segments.map(\.barValue) == [30])
        #expect(accounts[2].segments.map(\.barValue) == [4, 8])
        #expect(accounts[4].segments.map(\.barValue) == [20, 40])
        #expect(accounts[4].segments[0].atLeast)
        #expect(accounts.map(\.isActive) == [true, false, true, false, false])
        #expect(accounts.allSatisfy { $0.unavailableNote == nil && $0.status != nil })
        #expect(accounts[2].sources.local?.app == "Codex")
        #expect(accounts[0].sources == .split)
    }

    @Test
    func `a provider without accounts or with an error still gets its row`() throws {
        var codex = Fixtures.codex()
        codex["accounts"] = nil
        let state = try LemelsonRangeFixtures.state([
            "accounts": [Fixtures.claude("a", "Alpha", pct: 49, mine: 44)],
            "codex": codex,
            "antigravity": ["uuid": "antigravity", "name": "Antigravity", "short": "Antigravity",
                            "error": "antigravity.py: database disk image is malformed"],
        ])
        let page = self.page(state, mode: .limits)
        #expect(page.limitAccounts.map(\.id) == ["claude-a", "codex-codex", "antigravity-antigravity"])
        let broken = try #require(page.limitAccounts.last)
        #expect(broken.unavailableNote == "Antigravity's data could not be read this time.")
        #expect(broken.window == nil)
        #expect(broken.segments.isEmpty)
        #expect(broken.statusText == "—")
        #expect(page.rows.last { $0.id.contains("limits-acct-") }?.detail == nil)

        // No timeline in this summary: the chart row is a note, with nothing to point at.
        let recent = try #require(page.rows.first)
        #expect(recent.part == .recent)
        #expect(!recent.hasControls)
        #expect(page.chartDayDetail == nil)
    }

    @Test
    func `spend is the page from before the modes`() throws {
        let state = try Fixtures.overviewState()
        let legacy = self.page(state, mode: nil)
        let spend = self.page(state, mode: .spend)
        let prefix = UsageOverviewPage.idPrefix
        #expect(legacy.rows.map(\.id) == spend.rows.map(\.id))
        #expect(spend.rows.map(\.id) == ["spend", "provider-claude", "provider-codex", "provider-antigravity", "footer"]
            .map { prefix + $0 })
        #expect(spend.limitAccounts.isEmpty)
        #expect(spend.chartRowID == UsageOverviewSpend.defaultChartID)
        #expect(legacy.mode == nil)
        #expect(spend.mode == .spend)
        // The two modes share no row, so a warm row of one is never shown in the other.
        let limits = self.page(state, mode: .limits)
        #expect(Set(limits.rows.map(\.id)).isDisjoint(with: spend.rows.map(\.id)))
        for row in spend.rows {
            _ = row.detail?()
        }
        // Codex is one provider row on Spend however many accounts it has.
        #expect(spend.rows.count(where: { $0.providerKind == .codex }) == 1)
    }

    @Test
    func `the chart has a layer per span and unit`() throws {
        let state = try Fixtures.overviewState()
        let recent = UsageOverviewRecent(
            state: state, accounts: UsageOverviewLimitAccount.all(in: state, now: Fixtures.now))
        #expect(recent.isAvailable)
        #expect(recent.layers.count == UsageOverviewRecentSpan.allCases.count * UsageOverviewRecentUnit.allCases.count)
        #expect(Set(recent.layers.map(\.id)).count == 6)

        let usd = try #require(recent.layer(.h24, .usd))
        #expect(usd.points.count == 5)
        #expect(usd.points.first?.total == 0)
        #expect(usd.points.last?.you == 124)
        #expect(usd.points.last?.others == 218)
        #expect(usd.top >= 342)
        #expect(usd.tiles.map(\.value) == ["$124", "≈$218", "≈$342"])
        #expect(usd.tiles[1].caption == "excl. 1 account")
        #expect(usd.hint(at: 4)?.hasSuffix("You $124 · Others ≈$218") == true)
        // Dollars as Spend's charts write them, never cut to "$1.2K".
        #expect(usd.axisLabel(1200) == "$1,200")
        #expect(usd.axisLabel(3000) == "$3,000")
        #expect(usd.axisLabel(600) == "$600")

        let quotas = try #require(recent.layer(.h24, .quotas))
        #expect(quotas.points.last?.unknown == 0.40)
        // Whole weekly limits, never "wk": 0.96 is no part of a calendar week.
        #expect(quotas.tiles.map(\.text) == ["0.16 limits", "0.40 limits", "0.96 limits"])
        #expect(quotas.tiles.map(\.value) == ["0.16", "0.40", "0.96"])
        #expect(quotas.tiles.allSatisfy { $0.unit == "limits" })
        #expect(usd.tiles.allSatisfy { $0.unit == nil })
        #expect(quotas.tiles[2].caption == "42% not split")
        #expect(quotas.tiles[1].caption == "at least")
        #expect(quotas.hint(at: 99)?.hasSuffix("You 0.16 · Others 0.40 · 0.40 not split · limits") == true)

        // The page's own names and plans, and which accounts have no dollar rate.
        #expect(recent.accounts.map(\.id) == Fixtures.timelineKeys)
        #expect(recent.accounts.map(\.name) == ["Alpha", "Beta", "Alpha", "Beta", "Antigravity"])
        #expect(recent.accounts.map(\.rated) == [true, true, true, false, true])
        #expect(UsageOverviewRecent.roundTop(569, floor: 1) == 600)
        #expect(UsageOverviewRecent.roundTop(0.61, floor: 0.1) == 0.8)
        #expect(UsageOverviewRecent.roundTop(0, floor: 0.1) == 0.1)
    }

    @Test
    func `a range the collector left out is an empty layer`() throws {
        var timeline = Fixtures.timeline()
        var ranges = try #require(timeline["ranges"] as? [String: Any])
        ranges["72h"] = nil
        timeline["ranges"] = ranges
        let recent = try UsageOverviewRecent(state: Fixtures.overviewState(timeline: timeline))
        #expect(recent.isAvailable)
        let missing = try #require(recent.layer(.h72, .usd))
        #expect(missing.points.isEmpty)
        #expect(missing.hint(at: 0) == nil)
        #expect(missing.tiles.map(\.value) == ["—", "—", "—"])
        // Accounts the page does not list are named by the timeline itself.
        #expect(recent.accounts.map(\.name).first == "Account 0")
        #expect(recent.accounts.map(\.subtitle).last == "Antigravity Ultra 5x")
        #expect(recent.accounts.last?.mention == "Account 4 (Antigravity)")
    }

    @Test
    func `the rollback flag and the stored choices`() {
        let defaults = Fixtures.defaults()
        #expect(UsageOverviewMode.isEnabled(in: defaults))
        #expect(UsageOverviewMode.stored(in: defaults) == .limits)
        for value in ["off", "OFF", " no ", "false", "0"] {
            defaults.set(value, forKey: UsageOverviewMode.enabledKey)
            #expect(!UsageOverviewMode.isEnabled(in: defaults))
        }
        defaults.set("on", forKey: UsageOverviewMode.enabledKey)
        #expect(UsageOverviewMode.isEnabled(in: defaults))
        defaults.set(false, forKey: UsageOverviewMode.enabledKey)
        #expect(!UsageOverviewMode.isEnabled(in: defaults))
        defaults.set("spend", forKey: UsageOverviewMode.defaultsKey)
        #expect(UsageOverviewMode.stored(in: defaults) == .spend)
        defaults.set("value", forKey: UsageOverviewMode.defaultsKey)
        #expect(UsageOverviewMode.stored(in: defaults) == .limits)
        #expect(UsageOverviewMode.allCases.map(\.title) == ["Limits", "Spend"])
        #expect(UsageOverviewRecentSpan.allCases.map(\.rawValue) == ["24h", "72h", "7d"])
        #expect(UsageOverviewRecentUnit.allCases.map(\.title) == ["API $", "Quotas"])
    }

    @Test
    func `overview has two modes in the app and never value`() {
        #expect(LemelsonModeTab.overview.modes == [.limits, .spend])
        #expect(LemelsonModeTab.overview.provider == nil)
        #expect(LemelsonModeTab.claude.modes == LemelsonPanelMode.allCases)
        #expect(LemelsonPanelMode.limits.overviewMode == .limits)
        #expect(LemelsonPanelMode.spend.overviewMode == .spend)
        #expect(LemelsonPanelMode.value.overviewMode == .limits)
        #expect(LemelsonModeStore.store(for: .overview) === LemelsonModeStore.overview)
        #expect(LemelsonModeStore.overview.lastModeKey == UsageOverviewMode.defaultsKey)

        let defaults = Fixtures.defaults()
        func store() -> LemelsonModeStore {
            LemelsonModeStore(tab: .overview, lastModeKey: "last", pinnedModeKey: "pinned", defaults: defaults)
        }
        #expect(store().mode == .limits)
        // A mode Overview does not have reads as Limits, shown last or pinned.
        defaults.set("value", forKey: "last")
        defaults.set("value", forKey: "pinned")
        #expect(store().mode == .limits)
        #expect(store().pinnedMode == nil)
        defaults.set("spend", forKey: "last")
        #expect(store().mode == .spend)
        defaults.set("limits", forKey: "pinned")
        #expect(store().mode == .limits)
        let shown = store()
        shown.mode = .spend
        #expect(defaults.string(forKey: "last") == "spend")

        #expect(StatusItemController.lemelsonPageKey(tab: .overview, mode: .limits) == "overview:limits")
        #expect(StatusItemController.lemelsonPageKey(tab: .overview, mode: .spend) == "overview:spend")
        #expect(StatusItemController.lemelsonLandingMode(.next, tab: .overview) == .limits)
        #expect(StatusItemController.lemelsonLandingMode(.previous, tab: .overview) == .spend)
        #expect(LemelsonOverviewPageState.isShown(onPage: "overview"))
        #expect(LemelsonOverviewPageState.isShown(onPage: "overview:limits"))
        #expect(LemelsonOverviewPageState.isShown(onPage: "overview:spend"))
        #expect(!LemelsonOverviewPageState.isShown(onPage: "claude:limits"))
        // Under tests Overview is the stock tab, so it has no modes and keeps its one page key.
        #expect(!LemelsonOverviewPageState.shared.usesModes)
        #expect(StatusItemController.lemelsonPageKey(selection: .overview) == "overview")
    }
}

// MARK: - Review fixes

/// Regression tests for the two adversarial reviews of Overview → Limits and the split panels: axis labels,
/// names that repeat, honest wording, lower bounds, malformed timelines and the Codex tab's live numbers.
@MainActor
@Suite(.serialized)
struct LemelsonOverviewReviewFixTests {
    private typealias Fixtures = LemelsonSplitFixtures
    private typealias Timeline = UsagePanelState.OverviewTimeline

    private func layer(_ unit: UsageOverviewRecentUnit, top: Double) -> UsageOverviewRecent.Layer {
        UsageOverviewRecent.Layer(span: .d7, unit: unit, points: [], top: top, from: 0, to: 0, tiles: [], ticks: [])
    }

    private func recent(_ state: UsagePanelState) -> UsageOverviewRecent {
        UsageOverviewRecent(state: state, accounts: UsageOverviewLimitAccount.all(in: state, now: Fixtures.now))
    }

    // MARK: Axis and units

    @Test
    func `the middle axis label is never rounded to another number`() {
        // The old format printed 2.5 as "2" and 0.25 as "0.2".
        let five = self.layer(.quotas, top: 5)
        #expect(five.axisMarks.map(five.axisLabel) == ["0", "2.5", "5"])
        let half = self.layer(.quotas, top: 0.5)
        #expect(half.axisMarks.map(half.axisLabel) == ["0", "0.25", "0.5"])
        let small = self.layer(.quotas, top: 0.1)
        #expect(small.axisMarks.map(small.axisLabel) == ["0", "0.05", "0.1"])
        let three = self.layer(.quotas, top: 3)
        #expect(three.axisMarks.map(three.axisLabel) == ["0", "1.5", "3"])
        #expect(UsageOverviewRecent.axisNumber(2.5) == "2.5")
        #expect(UsageOverviewRecent.axisNumber(0.25) == "0.25")
        #expect(UsageOverviewRecent.axisNumber(0.50) == "0.5")
        #expect(UsageOverviewRecent.axisNumber(0.6) == "0.6")
        #expect(UsageOverviewRecent.axisNumber(1.2) == "1.2")
        #expect(UsageOverviewRecent.axisNumber(12) == "12")
        #expect(UsageOverviewRecent.axisNumber(0) == "0")
        #expect(UsageOverviewRecent.axisNumber(-.infinity) == "0")
        // Every top `roundTop` can give has a half that reads in full.
        for magnitude in [0.1, 1.0, 10.0] {
            for multiple in [1, 1.2, 1.6, 2, 3, 4, 5, 6, 8, 10] {
                let top = magnitude * multiple
                let label = UsageOverviewRecent.axisNumber(top / 2)
                #expect(LemelsonRangeFixtures.close(Double(label) ?? -1, top / 2, 1e-9), "\(top) / 2 reads \(label)")
            }
        }
    }

    @Test
    func `dollar axis labels are whole and get the room they need`() {
        let usd = self.layer(.usd, top: 5000)
        #expect(usd.axisMarks.map(usd.axisLabel) == ["$0", "$2,500", "$5,000"])
        let small = self.layer(.usd, top: 1)
        #expect(small.axisMarks.map(small.axisLabel) == ["$0", "$0.5", "$1"])
        let large = self.layer(.usd, top: 12000)
        #expect(large.axisLabel(12000) == "$12,000")
        #expect(large.axisLabel(1500.5) == "$1,500.5")
        // "$600" keeps the usual gutter; "$12,000" gets a wider one instead of being cut.
        #expect(self.layer(.usd, top: 600).gutter == 30)
        #expect(large.gutter > 40)
        #expect(self.layer(.quotas, top: 0.5).gutter == 30)
    }

    @Test
    func `quotas read as limits never as weeks`() {
        #expect(UsageOverviewRecent.limits(2.22) == "2.22 limits")
        #expect(UsageOverviewRecent.limits(0.42) == "0.42 limits")
        #expect(UsageOverviewRecent.limits(1) == "1.00 limit")
        #expect(UsageOverviewRecent.limits(1.004) == "1.00 limit")
        #expect(UsageOverviewRecent.limits(5.17) == "5.17 limits")
        #expect(UsageOverviewRecent.limits(12.34) == "12.3 limits")
        #expect(UsageOverviewRecent.limits(9.996) == "10.0 limits")
        #expect(UsageOverviewRecentPanelView.quotaLine(Timeline.Sample(you: 0.21, others: 0.09, unknown: 0.01))
            == "Weekly limits: you 0.21 · others 0.09 · 0.01 not split")
        #expect(!UsageOverviewRecentPanelView.quotaLine(Timeline.Sample(you: 1, others: 2)).contains("wk"))
    }

    // MARK: Names

    @Test
    func `an account named after its provider does not say the provider twice`() throws {
        let state = try Fixtures.overviewState()
        let accounts = UsageOverviewLimitAccount.all(in: state, now: Fixtures.now)
        let antigravity = try #require(accounts.last)
        #expect(antigravity.name == "Antigravity")
        #expect(antigravity.subtitle == "Ultra 5x")
        #expect(antigravity.detailTitle == "Weekly limit")
        #expect(accounts[0].detailTitle == "Claude · Weekly limit")
        #expect(accounts[2].detailTitle == "Codex · Weekly limit")
        #expect(UsageOverviewRecent.subtitle(name: "antigravity ", providerTitle: "Antigravity", plan: nil).isEmpty)
        #expect(UsageOverviewRecent.subtitle(name: "Misha", providerTitle: "Codex", plan: nil) == "Codex")

        // A Codex block without accounts is the account "Codex": just its plan.
        var codex = Fixtures.codex()
        codex["accounts"] = nil
        let single = try LemelsonRangeFixtures.state(["accounts": [], "codex": codex])
        #expect(UsageOverviewLimitAccount.all(in: single, now: Fixtures.now).map(\.subtitle) == ["Plus"])

        // The hover panel: the same subtitle, and the footnote names the account without splitting words.
        let lines = self.recent(state).accounts
        #expect(lines.map(\.subtitle) == ["Claude Max 5x", "Claude Max 5x", "Codex Plus", "Codex Pro 5x", "Ultra 5x"])
        #expect(lines.map(\.providerTitle) == ["Claude", "Claude", "Codex", "Codex", "Antigravity"])
        #expect(lines.map(\.mention) == [
            "Alpha (Claude)", "Beta (Claude)", "Alpha (Codex)", "Beta (Codex)", "Antigravity",
        ])
        let range = try #require(state.overviewTimeline?.range("24h"))
        let notes = UsageOverviewRecentPanelView.notes(self.recent(state), range: range)
        #expect(notes.contains { $0.hasPrefix("* No dollar rate yet for Beta (Codex): ") })
        #expect(!notes.joined().contains("Antigravity Antigravity"))
    }

    // MARK: Wording

    @Test
    func `idle with dollars on this Mac does not claim the Mac was idle all along`() {
        typealias Split = UsagePanelState.Window.Split
        let source = Fixtures.source
        let idle = Split(youPct: 0, othersPct: 1, method: .idle)
        #expect(source.note(for: idle, usd: 2.4, used: 1)
            == "This Mac's $2.40 of Codex use did not move this limit yet; the 1% moved while Codex was idle "
            + "here, so it is others (Codex cloud or another computer).")
        // Without dollars (or with cents) the short sentence stays.
        #expect(source.note(for: idle, usd: 0.2, used: 1).contains("idle on this Mac"))
        #expect(source.note(for: idle).contains("idle on this Mac"))
    }

    @Test
    func `no rate yet is said only when that is the reason`() {
        typealias Split = UsagePanelState.Window.Split
        let source = Fixtures.source
        for reason in ["unpriced_calls", "bucket_boundary", "uncovered", "possible_local_activity"] {
            let note = source.note(for: Split(youPct: 0, othersPct: 0, unknownPct: 8, method: .unknown, reason: reason))
            #expect(!note.contains("No rate yet"), "\(reason): \(note)")
            #expect(note.hasPrefix("This reading cannot be split yet: "))
        }
        #expect(UsageLocalSource.reasonText("bucket_boundary") != UsageLocalSource.reasonText(nil))
        // The account has a rate: never "No rate yet", whatever the reason field holds.
        let rated = source.note(
            for: Split(youPct: 0, othersPct: 0, unknownPct: 8, method: .unknown), rated: true)
        #expect(!rated.contains("No rate yet"))
        let ratedFloor = source.note(
            for: Split(youPct: 0, othersPct: 4, unknownPct: 8, method: .floor, reason: "uncovered"), rated: true)
        #expect(!ratedFloor.contains("No rate yet"))
        // No rate and nothing else to blame: the sentence that names the spend the split waits for.
        let bare = source.note(
            for: Split(youPct: 0, othersPct: 0, unknownPct: 8, method: .unknown, reason: "rounding"), rated: false)
        #expect(bare.hasPrefix("No rate yet, so this reading cannot be split."))
        #expect(bare.contains("$10+ of Codex use on this Mac"))
    }

    // MARK: Lower bounds and "≈"

    @Test
    func `a lower bound is rounded down never up`() throws {
        #expect(UsageFormat.floorPercent(0.6) == "0%")
        #expect(UsageFormat.floorPercent(12.9) == "12%")
        #expect(UsageFormat.floorPercent(12) == "12%")
        #expect(UsageFormat.floorPercent(-3) == "0%")
        #expect(UsageFormat.floorPercent(.nan) == "0%")

        // 0.6% proven others under a 12% reading: the old label was "Others 1%+".
        let low = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 0, others: 0.6, unknown: 11.4, method: "floor"))
        #expect(low.map(\.chipText) == ["Others 0%+", "Not split yet 12%"])
        #expect(low[0].longValueText == "at least 0%")
        // 4.7% is "at least 4%", and the two labels still add up to the reading.
        let segments = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 0, others: 4.7, unknown: 7.3, method: "floor"))
        #expect(segments.map(\.chipText) == ["Others 4%+", "Not split yet 8%"])
        #expect(UsageWeekLimit.atLeast(12.9) == "≥12%")
        #expect(UsageWeekLimit.atLeast(0.6) == ">0%")
    }

    @Test
    func `approximately never stands before under one percent or zero`() throws {
        #expect(UsageFormat.approxPercent(0.2) == "<1%")
        #expect(UsageFormat.approxPercent(0) == "0%")
        #expect(UsageFormat.approxPercent(8) == "≈8%")
        // A rate measured once and a sliver of this Mac's: "You <1%", not "You ≈<1%".
        let segments = try Fixtures.segments(
            pct: 12, split: Fixtures.split(you: 0.3, others: 11.7, method: "calibrated", preliminary: true))
        #expect(segments[0].approximate)
        #expect(segments[0].chipText == "You <1%")

        // A Claude week after a reset inside it: one separator, the parts in brackets, no "≈<1%".
        let end = Fixtures.stamp - 86400
        let reset = end - 2 * 86400
        let week = try Fixtures.decodeWeek([
            "start": end - 7 * 86400, "end": end, "peakFinal": true, "peakPct": 60.0, "minePct": 0.2,
            "othersPct": 59.8, "resetAt": reset,
        ])
        let limit = UsageWeekLimit(week: week, window: nil, capacity: nil, fableWeight: 1, now: Fixtures.now)
        let line = limit.headline + limit.tail
        #expect(line == "After the \(UsageFormat.shortDay(reset)) reset · used 60% (you <1%, others ≈60%)")
        #expect(!line.contains(":"))
        #expect(!line.contains("≈<"))
        #expect(!line.contains("≈0%"))

        // The same week of a provider, and one with no "you": brackets too.
        let local = UsageWeekLimit(
            week: week, window: nil, capacity: nil, fableWeight: 1, now: Fixtures.now,
            sources: .local(Fixtures.source))
        #expect(local.headline + local.tail
            == "After the \(UsageFormat.shortDay(reset)) reset · used 60% (you <1%, others ≈60%)")
        let floor = try Fixtures.decodeWeek([
            "start": end - 7 * 86400, "end": end, "peakFinal": true, "peakPct": 60.0, "minePct": NSNull(),
            "othersPct": 12.9, "unknownPct": 47.1, "splitMethod": "floor", "resetAt": reset,
        ])
        let unrated = UsageWeekLimit(
            week: floor, window: nil, capacity: nil, fableWeight: 1, now: Fixtures.now,
            sources: .local(Fixtures.source))
        #expect(unrated.tail == " (others ≥12%, 48% not split)")
    }

    @Test
    func `the parts of a week add up to its reading`() throws {
        let end = Fixtures.stamp - 86400
        // Each rounded alone: 45% + 45% + 11% under "Limit hit".
        let week = try Fixtures.decodeWeek([
            "start": end - 7 * 86400, "end": end, "peakFinal": true, "peakPct": 100.0, "minePct": 44.6,
            "othersPct": 44.6, "unknownPct": 10.8, "splitMethod": "mixed",
        ])
        let limit = UsageWeekLimit(
            week: week, window: nil, capacity: nil, fableWeight: 1, now: Fixtures.now,
            sources: .local(Fixtures.source))
        #expect(limit.headline == "Limit hit")
        #expect(limit.tail == ": you ≈45%, others ≈44%, 11% not split")
        #expect(UsageWeekLimit.labels([44.6, 44.6, 10.8], of: 100).reduce(0, +) == 100)
        #expect(UsageWeekLimit.labels([33.5, 17.5], of: 51) == [34, 17])
        // A part under one percent keeps reading "<1%" and takes nothing from the others.
        #expect(UsageWeekLimit.labels([0.2, 59.8], of: 60) == [0.2, 60])
        #expect(UsageWeekLimit.labels([0, 60], of: 60) == [0, 60])
        // 0.4% is next in line for the leftover percent of a 61.58% reading: it is not "≈1%".
        #expect(UsageWeekLimit.labels([0.4, 61.2], of: 61.58) == [0.4, 61])
        #expect(UsageSegment.rounded([0.4, 61.2, 0], to: 62) == [0, 61, 0])
        #expect(UsageSegment.rounded([0.7, 61.0], to: 62) == [1, 61])
        #expect(UsageSegment.rounded([7.5, 4.5], to: 12) == [8, 4])
        #expect(UsageSegment.rounded([1, 2], to: .nan) == [1, 2])
        let sliver = try Fixtures.segments(
            pct: 61.58, split: Fixtures.split(you: 0.4, others: 61.2, method: "calibrated"))
        #expect(sliver.map(\.chipText) == ["You <1%", "Others 61%"])

        // Claude: you and others of a finished week.
        let claude = try Fixtures.decodeWeek([
            "start": end - 7 * 86400, "end": end, "peakFinal": true, "peakPct": 51.0, "minePct": 33.5,
            "othersPct": 17.5,
        ])
        let split = UsageWeekLimit(week: claude, window: nil, capacity: nil, fableWeight: 1, now: Fixtures.now)
        #expect(split.tail == ": you ≈34%, others ≈17% · 49% unused")
    }

    // MARK: The timeline

    @Test
    func `a range with an unusable grid is dropped and costs nothing else`() throws {
        var timeline = Fixtures.timeline()
        var ranges = try #require(timeline["ranges"] as? [String: Any])
        // A step so small the range would have billions of points, and one that runs backwards.
        var huge = Fixtures.range(hours: 72)
        huge["stepSec"] = 1e-6
        ranges["72h"] = huge
        var backwards = Fixtures.range(hours: 168)
        backwards["to"] = (backwards["from"] as? Double ?? 0) - 10
        ranges["7d"] = backwards
        timeline["ranges"] = ranges
        let decoded = try #require(Fixtures.overviewState(timeline: timeline).overviewTimeline)
        #expect(Set(decoded.ranges.keys) == ["24h"])
        #expect(decoded.accounts.count == 5)
        let recent = try self.recent(Fixtures.overviewState(timeline: timeline))
        #expect(recent.isAvailable)
        #expect(recent.layer(.h72, .usd)?.points.isEmpty == true)
        #expect(recent.layer(.h24, .usd)?.points.count == 5)

        // Just over the cap is dropped, exactly at it is kept; a range of one instant is one point.
        func count(from: Double, to: Double, step: Double) throws -> Int? {
            var range = Fixtures.range(hours: 24)
            range["from"] = from
            range["to"] = to
            range["stepSec"] = step
            let data = try JSONSerialization.data(withJSONObject: range)
            return (try? JSONDecoder().decode(Timeline.Range.self, from: data))?.count
        }
        let cap = Double(Timeline.Range.maxPoints)
        #expect(try count(from: 0, to: cap - 1, step: 1) == Timeline.Range.maxPoints)
        #expect(try count(from: 0, to: cap, step: 1) == nil)
        #expect(try count(from: 100, to: 100, step: 60) == 1)
        #expect(try count(from: 0, to: 1e300, step: 1) == nil)
        #expect(try count(from: 0, to: 10, step: 1e300) == 1)
        #expect(try count(from: 0, to: 10, step: -1) == nil)
    }

    @Test
    func `flags that are no small whole number are no flags`() throws {
        #expect(Timeline.Flags(number: 13) == [.gap, .calibrated, .boundary])
        #expect(Timeline.Flags(number: nil) == [])
        #expect(Timeline.Flags(number: 1e300) == [])
        #expect(Timeline.Flags(number: -1) == [])
        #expect(Timeline.Flags(number: .nan) == [])
        #expect(Timeline.Flags(number: .infinity) == [])
        // In a sample: the numbers stay, the flags read as none. `Int(1e300)` used to trap here.
        let data = try JSONSerialization.data(withJSONObject: [[1.0, 2.0, 3.0, 1e300], [1.0, 2.0, 3.0, -7.0]])
        let samples = try JSONDecoder().decode([Timeline.Sample].self, from: data)
        #expect(samples.map(\.flags) == [[], []])
        #expect(samples.map(\.total) == [6, 6])
    }

    @Test
    func `a timeline without a usable range is no chart`() throws {
        var timeline = Fixtures.timeline()
        timeline["ranges"] = ["24h": ["from": 0, "to": 10, "stepSec": 0, "combined": [String: Any]()]]
        let state = try Fixtures.overviewState(timeline: timeline)
        #expect(state.overviewTimeline != nil)
        let recent = self.recent(state)
        #expect(!recent.isAvailable)
        let page = UsageOverviewPage(state: state, now: Fixtures.now, width: 310, detailWidth: 340, mode: .limits)
        #expect(page.rows.first?.hasControls == false)
        #expect(page.chartDayDetail == nil)
    }

    @Test
    func `accounts with an unsplit share are named when the collector lists them`() throws {
        // An older collector writes no list: nothing is claimed.
        let plain = try #require(Fixtures.overviewState().overviewTimeline?.range("24h"))
        #expect(plain.combined.unknownAccounts == nil)

        var timeline = Fixtures.timeline()
        var ranges = try #require(timeline["ranges"] as? [String: Any])
        var day = Fixtures.range(hours: 24)
        var combined = try #require(day["combined"] as? [String: Any])
        // Antigravity has a rate and a share nobody can be given yet; the unrated Codex account has one too.
        combined["unknownAccounts"] = [Fixtures.timelineKeys[4], Fixtures.timelineKeys[3], 7] as [Any]
        day["combined"] = combined
        ranges["24h"] = day
        timeline["ranges"] = ranges
        let state = try Fixtures.overviewState(timeline: timeline)
        let range = try #require(state.overviewTimeline?.range("24h"))
        #expect(range.combined.unknownAccounts == [Fixtures.timelineKeys[4], Fixtures.timelineKeys[3]])

        let recent = self.recent(state)
        let usd = try #require(recent.layer(.h24, .usd))
        // One account has no rate at all, one has a rate and an unsplit share: Others leaves both out.
        #expect(usd.tiles[1].caption == "excl. 1 + unsplit")
        #expect(usd.tiles[2].caption == "what has a price")
        let quotas = try #require(recent.layer(.h24, .quotas))
        #expect(quotas.tiles[2].caption == "42% not split · 2 accts")
        let notes = UsageOverviewRecentPanelView.notes(recent, range: range)
        #expect(notes.contains { $0.hasPrefix("Not split yet on Antigravity: ") })
        // The other range has no list, so its captions stay as they were.
        #expect(recent.layer(.h72, .usd)?.tiles[1].caption == "excl. 1 account")
        #expect(recent.layer(.h72, .usd)?.tiles[2].caption == "what has a price")
    }

    // MARK: The hover panel

    @Test
    func `points drop a needless decimal and no reading is a dash`() {
        typealias Panel = UsageOverviewRecentPanelView
        #expect(Panel.points(2.0) == "2%")
        #expect(Panel.points(6.04) == "6%")
        #expect(Panel.points(7.6) == "7.6%")
        #expect(Panel.points(0.01) == "0%")
        #expect(Panel.points(27.3) == "27%")
        #expect(Panel.points(9.96) == "10%")

        let zero = Timeline.Sample(you: 0, others: 0)
        let carried = Timeline.Sample(you: 0, others: 0, flags: [.gap])
        let used = Timeline.Sample(you: 1, others: 2, flags: [.gap])
        // Read inside the range and did not move: a measured 0%.
        #expect(Panel.hasReading(zero, quotaThrough: 500, from: 100))
        // Never read, read only before the range, or only carried over a gap: no reading.
        #expect(!Panel.hasReading(nil, quotaThrough: 500, from: 100))
        #expect(!Panel.hasReading(zero, quotaThrough: nil, from: 100))
        #expect(!Panel.hasReading(zero, quotaThrough: 50, from: 100))
        #expect(!Panel.hasReading(carried, quotaThrough: 500, from: 100))
        // Use that was counted is shown, carried or not.
        #expect(Panel.hasReading(used, quotaThrough: nil, from: 100))
        #expect(Panel.othersText(usd: nil, points: nil, rated: true) == "Others —")
        #expect(Panel.othersText(usd: 80, points: 3, rated: true) == "Others ≈$80 · 3%")
        #expect(Panel.othersText(usd: nil, points: 2.5, rated: false) == "Others 2.5%*")
    }

    // MARK: Overview and the Codex tab

    @Test
    func `overview limits show the codex tab's live readings names and order`() throws {
        // CodexBar switched to the second account and read it after the summary was written.
        let state = try StatusItemController.lemelsonCodexState(
            Fixtures.overviewState(), active: Fixtures.secondCodex)
        let reset = Int(Fixtures.stamp + 3 * 86400)
        let live = [
            Fixtures.secondCodex: UsageCodexLive(
                measuredAt: Fixtures.now.timeIntervalSince1970 + 30,
                fiveHour: nil,
                week: UsageQuotaLiveReading.Window(pct: 37, resetsAt: reset)),
        ]
        let names = [Fixtures.firstCodex: "Account 1"]

        let tab = try #require(UsageCodexPage(
            state: state, now: Fixtures.now, width: 310, mode: .limits, live: live, privateNames: names))
        let overview = UsageOverviewLimitAccount.all(
            in: state, now: Fixtures.now, codexLive: live, codexPrivateNames: names).filter { $0.provider == .codex }
        // The same accounts in the same order, with the same names and the same percent.
        #expect(overview.map(\.account.uuid) == [Fixtures.secondCodex, Fixtures.firstCodex])
        #expect(overview.map(\.account.uuid) == tab.entries.map(\.account.uuid))
        #expect(overview.map(\.name) == tab.entries.map(\.account.displayName))
        #expect(overview.map(\.name) == ["Account 2", "Account 1"])
        #expect(overview.map { $0.window?.pct } == tab.entries.map { $0.account.window(.week)?.pct })
        #expect(overview.first?.window?.pct == 37)
        #expect(overview.first?.window?.source == "live")
        #expect(overview.map(\.isActive) == [true, false])
        // What the limit moved since the summary's reading is nobody's yet.
        #expect(overview.first?.segments.map(\.kind) == [.others, .unknown])
        // The timeline's key does not follow the hidden name.
        #expect(overview.map(\.timelineKey) == [Fixtures.timelineKeys[3], Fixtures.timelineKeys[2]])

        // The page passes them through; without them it is the summary as written.
        let page = UsageOverviewPage(
            state: state, now: Fixtures.now, width: 310, detailWidth: 340, mode: .limits, codexLive: live,
            codexPrivateNames: names, clock: { Fixtures.now })
        #expect(page.limitAccounts.filter { $0.provider == .codex }.map(\.name) == ["Account 2", "Account 1"])
        #expect(page.limitAccounts.first { $0.account.uuid == Fixtures.secondCodex }?.window?.pct == 37)
        let plain = UsageOverviewLimitAccount.all(in: state, now: Fixtures.now).filter { $0.provider == .codex }
        #expect(plain.map(\.name) == ["Beta", "Alpha"])
        #expect(plain.first?.window?.pct == 1)
        // Claude and Antigravity are not touched by Codex's names.
        #expect(page.limitAccounts.filter { $0.provider != .codex }.map(\.name) == ["Alpha", "Beta", "Antigravity"])
    }

    @Test
    func `limits does not build the spend page and details use the clock`() throws {
        let state = try Fixtures.overviewState()
        var asked = 0
        let limits = UsageOverviewPage(
            state: state, now: Fixtures.now, width: 310, detailWidth: 340, mode: .limits,
            clock: {
                asked += 1
                return Fixtures.now
            })
        #expect(limits.spend == nil)
        #expect(asked == 0)
        // The panel is built when its row is pointed at, at the time it is pointed at.
        let row = try #require(limits.rows.first { $0.id.contains("limits-acct-") })
        _ = row.detail?()
        _ = row.detail?()
        #expect(asked == 2)
        #expect(UsageOverviewPage(state: state, now: Fixtures.now, width: 310, mode: .spend).spend != nil)
        #expect(UsageOverviewPage(state: state, now: Fixtures.now, width: 310, mode: nil).spend != nil)
    }

    @Test
    func `an account row opens its tab on limits a provider row keeps the tab's mode`() {
        #expect(StatusItemController.lemelsonOverviewClickMode(for: .account(.claude)) == .limits)
        #expect(StatusItemController.lemelsonOverviewClickMode(for: .account(.codex)) == .limits)
        #expect(StatusItemController.lemelsonOverviewClickMode(for: .account(.antigravity)) == .limits)
        #expect(StatusItemController.lemelsonOverviewClickMode(for: .provider(.codex)) == nil)
        #expect(StatusItemController.lemelsonOverviewClickMode(for: .recent) == nil)
        #expect(StatusItemController.lemelsonOverviewClickMode(for: .cache) == nil)
        // Both tabs with modes have Limits to land on.
        #expect(LemelsonModeTab.claude.modes.contains(.limits))
        #expect(LemelsonModeTab.codex.modes.contains(.limits))
    }

    @Test
    func `rows of a mode the page no longer has are let go`() {
        let page = LemelsonOverviewPageState.shared
        let saved = (page.warmRows, page.renderedMode)
        defer { (page.warmRows, page.renderedMode) = saved }
        // Under tests Overview has no modes, as after `lemelsonOverviewLimits off`: Spend is its one page.
        #expect(page.warmableModes == [.spend])
        page.warmRows = [.limits: ["a": NSView()], .spend: ["b": NSView()]]
        page.renderedMode = .limits
        page.dropRowsOfRetiredModes()
        #expect(Set(page.warmRows.keys) == [.spend])
        #expect(page.renderedMode == nil)
        page.renderedMode = .spend
        page.dropRowsOfRetiredModes()
        #expect(page.renderedMode == .spend)
    }

    // MARK: Bars and charts

    @Test
    func `claude without a rate shows the server's breakdown as others and not split`() throws {
        var window = Fixtures.window(pct: 30)
        window["mine"] = NSNull()
        window["server"] = ["claude_code": 20.0, "chat": 8.0, "cowork": 2.0]
        let decoded = try Fixtures.decodeWindow(window)
        let segments = UsageSegment.threeWay(for: decoded, sources: .split)
        // Chat and Cowork are certainly not this Mac; Claude Code is this Mac or another one.
        #expect(segments.map(\.kind) == [.others, .unknown])
        #expect(segments.map(\.barValue) == [10, 20])
        // No breakdown, or one that is all Claude Code: one hatched part, as before.
        let bare = try Fixtures.decodeWindow(Fixtures.window(pct: 30, extra: ["mine": NSNull()]))
        #expect(UsageSegment.threeWay(for: bare, sources: .split).map(\.kind) == [.unknown])
        window["server"] = ["claude_code": 30.0]
        let code = try Fixtures.decodeWindow(window)
        #expect(UsageSegment.threeWay(for: code, sources: .split).map(\.kind) == [.unknown])
    }

    @Test
    func `a part under half a percent is no sliver in the bar`() {
        let you = UsageSegment(kind: .you, value: 0.2, barValue: 0.2)
        let others = UsageSegment(kind: .others, value: 12, barValue: 12)
        #expect(UsageSegmentBar.drawn([you, others]).map(\.kind) == [.others])
        #expect(UsageSegmentBar.drawn([others]).map(\.kind) == [.others])
        // All there is stays, so a 0.3% reading is still a mark on the bar.
        let tiny = UsageSegment(kind: .unknown, value: 0.1, barValue: 0.1)
        #expect(UsageSegmentBar.drawn([you, tiny]).map(\.kind) == [.you])
        #expect(UsageSegmentBar.drawn([]).isEmpty)
        #expect(UsageSegmentBar.minSegmentWidth >= 2.5)

        // The weekly bars: the same rule, and the parts keep their places so the hatched one stays hatched.
        let week = UsageSplitBar.withoutSlivers([
            (41, UsagePalette.you), (0.3, UsagePalette.others), (2, UsagePalette.unsplitStripe),
        ])
        #expect(week.map(\.0) == [41, 0, 2])
        let sliver = UsageSplitBar.withoutSlivers([(0.2, UsagePalette.you), (0.4, UsagePalette.others)])
        #expect(sliver.map(\.0) == [0, 0.4])
        #expect(UsageSplitBar.withoutSlivers([(0, UsagePalette.you), (0, UsagePalette.others)]).map(\.0) == [0, 0])
        // The hover panel names a share from 0.05%, so it draws from there.
        let hover = UsageSplitBar.withoutSlivers(
            [(0.4, UsagePalette.you), (36, UsagePalette.others), (0.01, UsagePalette.unsplitStripe)], under: 0.05)
        #expect(hover.map(\.0) == [0.4, 36, 0])
    }

    @Test
    func `the limit chart uses the collector's others and breaks where you is unknown`() {
        let start = Fixtures.stamp - 86400
        typealias Point = UsagePanelState.Window.Point
        let points = [
            Point(time: start, used: 6, mine: 4, others: 2, unknown: 0),
            // The collector's numbers, which need not be the total minus the rest.
            Point(time: start + 600, used: 14, mine: 8, others: 2, unknown: 3),
            // No rate at this reading: no "you".
            Point(time: start + 1200, used: 16, mine: nil, others: 3, unknown: 13),
            Point(time: start + 1800, used: 18, mine: 9, others: 4, unknown: 5),
            // An older three-column reading: worked out from the total.
            Point(time: start + 2400, used: 20, mine: 9),
        ]
        let range = Date(timeIntervalSince1970: start - 60)...Date(timeIntervalSince1970: start + 86400)
        let samples = UsageLimitDetailPanelView.samples(of: points, in: range, local: true)
        #expect(samples.used.count == 5)
        // Two stretches of "you": the line stops at the reading without it and starts again after.
        #expect(samples.mine.map(\.series) == ["you-0", "you-0", "you-2", "you-2"])
        #expect(samples.mine.map(\.value) == [4, 8, 9, 9])
        #expect(samples.others.map(\.series) == ["others-0", "others-0", "others-1", "others-2", "others-2"])
        // mine + others, not used - unknown (which would be 11 for the second reading).
        #expect(samples.others.map(\.low) == [4, 8, 13, 9, 9])
        #expect(samples.others.map(\.high) == [6, 10, 16, 13, 20])
        // Claude's chart has no others band and keeps one "you" series while every reading has it.
        let claude = UsageLimitDetailPanelView.samples(of: Array(points.prefix(2)), in: range, local: false)
        #expect(claude.others.isEmpty)
        #expect(Set(claude.mine.map(\.series)) == ["you-0"])
    }
}
