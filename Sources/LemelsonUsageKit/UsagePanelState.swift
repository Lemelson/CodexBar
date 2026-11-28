import Foundation

/// Summary of usage across Claude accounts, written every five minutes into `state.json`
/// by the Claude Switcher collector (`usage/tick.py`).
///
/// This only reads ready-made numbers: all calculations (my share, rates, subscription cost)
/// are done by the collector, so the logic can be changed without rebuilding CodexBar.
public struct UsagePanelState: Decodable, Sendable, Equatable {
    public var schema: Int?
    public var generatedAt: Double
    /// Fallback Fable/Opus ratio for accounts without their own; each account carries its own `kFable`.
    public var kFable: Double?
    /// Which account the fallback ratio comes from and over how many segments.
    public var kSource: String?
    public var kPairs: Double?
    public var dashboardPath: String?
    /// What runs the limits refresh when the menu opens.
    public var collector: Collector?
    public var vpnUp: Bool?
    public var vpnState: String?
    public var accounts: [Account]
    /// Gemini use through Antigravity (`usage/ANTIGRAVITY-STATE.md`). Decoded leniently: a malformed
    /// block never breaks the Claude part of the summary.
    public var antigravity: UsageProviderBlock?
    /// Codex (`usage/CODEX-STATE.md`): the same shape as `antigravity`, decoded by the same type.
    public var codex: UsageProviderBlock?
    /// Prompt cache of all Claude accounts together; never fails the summary.
    public var cache: UsageCacheStats?
    /// Set when the collector's cache step failed: then `cache` is null here and on every account.
    public var cacheError: String? {
        self.cacheErrorField?.value
    }

    /// A value of an unexpected shape reads as nil instead of costing the whole summary.
    private var cacheErrorField: Lenient<String>?

    /// API dollars of the last 24 hours (rolling) across every subscription on this Mac (`usage/CODEX-STATE.md`,
    /// Changes 2026-11-27). Nil in older summaries, when malformed, or when the collector's step failed.
    public var spend24h: Spend24h? {
        self.spend24hField?.value
    }

    /// Decoded leniently: a malformed block never costs the summary.
    private var spend24hField: Lenient<Spend24h>?

    /// You / others / not split yet across every account on fixed rolling grids (`usage/timeline.py`).
    /// Nil in older summaries, when malformed, or when the collector's step failed (`{"error": …}`).
    public var overviewTimeline: OverviewTimeline? {
        self.overviewTimelineField?.value
    }

    /// Decoded leniently: a malformed block never costs the summary.
    private var overviewTimelineField: Lenient<OverviewTimeline>?

    enum CodingKeys: String, CodingKey {
        case schema, generatedAt, accounts, dashboardPath, collector, vpnUp, vpnState, antigravity, codex, cache
        case cacheErrorField = "cacheError"
        case spend24hField = "spend24h"
        case overviewTimelineField = "overviewTimeline"
        case kFable = "k_fable"
        case kSource = "k_source"
        case kPairs = "k_pairs"
    }

    public struct Collector: Decodable, Sendable, Equatable {
        public var python: String
        public var tick: String
    }

    public struct Account: Decodable, Sendable, Equatable, Identifiable {
        public var uuid: String
        public var name: String
        public var short: String
        public var active: Bool?
        public var useHapp: Bool?
        public var planName: String?
        public var planPriceUsd: Double?
        public var has5h: Bool?
        /// One full 5-hour window as a percentage of the weekly limit, measured from paired readings of both
        /// limits. The collector does not write it yet: until it does, the panel uses the ratio of dollar rates.
        public var sessionPctOfWeek: Double?
        public var fableShareOfWeek: Double?
        /// How many times faster $1 of Fable uses this account's weekly limit than $1 of Opus.
        public var kFable: Double?
        /// How it was obtained: "share" (from the server's Fable cap share), "pure" (single-model stretches),
        /// "fit" (least squares on mixed stretches), "pooled" (borrowed from another account), "default".
        public var kSource: String?
        /// Short label of the account whose data gave the ratio, when it is borrowed.
        public var kFrom: String?
        public var windows: [String: Window]?
        public var rates: [String: Rate]?
        public var drift: [DriftPoint]?
        public var lastPoll: Poll?
        /// When the server last answered successfully for this account.
        public var lastMeasuredAt: Double?
        public var weeks: [Week]?
        public var daily: [Day]?
        public var usdToday: Double?
        public var tokensToday: Double?
        /// The last 24 hours, rolling (not since local midnight like `usdToday`).
        public var usd24h: Double? = nil
        public var tokens24h: Double? = nil
        public var usd7d: Double?
        public var tokens7d: Double?
        public var usd30d: Double?
        public var tokens30d: Double?
        /// Earliest spend record of this account on this Mac.
        public var trackedSince: Double?
        public var value: Value?
        /// "background": the collector reads the limits by itself; "manual": only while this (VPN-only)
        /// account is the active one. Missing in older summaries: see `refreshesInBackground`.
        public var refresh: String?
        public var refreshEverySec: Double?
        public var pausedByVpn: Bool?
        /// Prompt cache of this account by span ("today", "7d", "30d"); never fails the summary.
        public var cache: UsageCacheStats? = nil
        /// Set when the collector failed on this account ("error: ValueError: …"): the entry then has only its
        /// name, flags, refresh mode and cache, and the pages show one quiet line instead of numbers.
        public var error: String? = nil

        public var id: String {
            self.uuid
        }

        /// The collector failed on this account this time.
        public var isUnavailable: Bool {
            self.error != nil
        }

        /// "Collector error: ValueError: made up": the one line the pages show for an account without numbers.
        public var unavailableNote: String? {
            guard var text = self.error?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if text.lowercased().hasPrefix("error:") {
                text = String(text.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            }
            return text.isEmpty ? "Collector error" : "Collector error: \(text)"
        }

        public var isActive: Bool {
            self.active ?? false
        }

        public var needsVPN: Bool {
            self.useHapp ?? false
        }

        /// Older summaries have no `refresh`: a VPN-only account is the one read only by hand.
        public var refreshesInBackground: Bool {
            switch self.refresh {
            case "manual": false
            case "background": true
            default: !self.needsVPN
            }
        }

        /// Read in the background, but skipped while the VPN is on (`pausedByVpn == true` or
        /// `lastPoll.status == "vpn_mismatch"`): the reading is waiting, not failing.
        public var isPausedByVPN: Bool {
            if let paused = self.pausedByVpn { return paused }
            return self.refreshesInBackground && self.lastPoll?.status == "vpn_mismatch"
        }

        public func window(_ kind: WindowKind) -> Window? {
            self.windows?[kind.rawValue]
        }
    }

    public enum WindowKind: String, Sendable, CaseIterable {
        case fiveHour = "5h"
        case week = "7d"
        case fable
    }

    public struct Window: Decodable, Sendable, Equatable {
        /// Limit percentage from the server's latest reading.
        public var pct: Double?
        public var measuredAt: Double?
        public var resetsAt: Double?
        public var source: String?
        public var rolled: Bool?
        public var start: Double?
        /// My spend in this window in API dollars, by model family.
        public var usd: Spend?
        /// How many percent of the limit is Claude Code on this Mac.
        public var mine: Double?
        /// Remainder: what was spent from somewhere other than this Mac.
        public var outside: Double?
        /// Mine since the reading: not yet included in the server's percentage.
        public var sinceMeasure: Double?
        /// The server's own breakdown (week only): claude_code, chat, cowork, other.
        public var server: [String: Double]?
        /// Window progress: [time, limit percentage, of which mine, others, not split yet]. The last two are
        /// written only by the providers that split by readings (Codex, Antigravity).
        public var series: [[Double?]]?
        /// Where the window will end up at the reset: computed by the collector from the window progress and past windows.
        public var forecast: Forecast?
        /// Codex and Antigravity: the reading split into this Mac, others and what cannot be told yet.
        /// Nil in older summaries and for Claude, whose split is `mine` / `outside` / `server`.
        public var split: Split? {
            get { self.splitField?.value }
            set { self.splitField = newValue.map { Lenient(value: $0) } }
        }

        /// A value of an unexpected shape reads as nil instead of costing the window.
        var splitField: Lenient<Split>? = nil

        enum CodingKeys: String, CodingKey {
            case pct, measuredAt, resetsAt, source, rolled, start, usd, mine, outside, sinceMeasure, server, series
            case forecast
            case splitField = "split"
        }

        /// The forecast is valid while both the reading it starts from and the forecast itself are fresh, and the
        /// window has not been reset. The one check for every consumer: the row's verdict, the panel's chart and
        /// its Forecast section, so the row never says "No forecast" while the panel still shows one.
        public func liveForecast(now: Date) -> Forecast? {
            guard self.rolled != true,
                  let forecast = self.forecast,
                  UsageLimitReading.isFresh(forecast.at, now: now),
                  UsageLimitReading.isFresh(self.measuredAt, now: now),
                  let resetsAt = self.resetsAt,
                  resetsAt > now.timeIntervalSince1970
            else { return nil }
            return forecast
        }

        public struct Point: Sendable, Equatable, Identifiable {
            public var time: Double
            public var used: Double
            public var mine: Double?
            /// Proven to be someone else's use at this reading (provider pages).
            public var others: Double? = nil
            /// Not told apart yet at this reading: this Mac or others (provider pages).
            public var unknown: Double? = nil

            public var id: Double {
                self.time
            }
        }

        public var points: [Point] {
            (self.series ?? []).compactMap { row in
                guard row.count >= 2, let time = row[0], let used = row[1] else { return nil }
                return Point(
                    time: time,
                    used: used,
                    mine: row.count > 2 ? row[2] : nil,
                    others: row.count > 3 ? row[3] : nil,
                    unknown: row.count > 4 ? row[4] : nil)
            }
        }

        /// One reading of a provider's limit told apart: `youPct + othersPct + unknownPct` is the reading.
        public struct Split: Decodable, Sendable, Equatable {
            /// How the parts were obtained.
            public enum Method: String, Sendable, Equatable {
                /// Nothing ran on this Mac while the limit moved: all of it is others.
                case idle
                /// This Mac's part comes from the measured dollars-per-percent rate.
                case calibrated
                /// No rate yet, but some of the movement happened while this Mac was idle: others is a floor.
                case floor
                /// A rate exists, and part of the reading still cannot be told apart.
                case mixed
                /// No rate and no idle movement: nothing can be told apart yet.
                case unknown
            }

            public var youPct: Double
            public var othersPct: Double
            public var unknownPct: Double
            public var method: Method
            /// The rate rests on a single stretch, so this Mac's part is approximate.
            public var preliminary: Bool
            /// Why a part is not split, in the collector's words ("uncovered", "rounding", …).
            public var reason: String?

            public init(
                youPct: Double,
                othersPct: Double,
                unknownPct: Double = 0,
                method: Method,
                preliminary: Bool = false,
                reason: String? = nil)
            {
                self.youPct = youPct
                self.othersPct = othersPct
                self.unknownPct = unknownPct
                self.method = method
                self.preliminary = preliminary
                self.reason = reason
            }

            enum CodingKeys: String, CodingKey {
                case youPct, othersPct, unknownPct, method, preliminary, reason
            }

            /// Field by field: a missing or malformed part reads as zero, an unfamiliar method as "unknown".
            public init(from decoder: Decoder) throws {
                let keys = try decoder.container(keyedBy: CodingKeys.self)
                self.youPct = Self.points(keys.lenient(Double.self, .youPct))
                self.othersPct = Self.points(keys.lenient(Double.self, .othersPct))
                self.unknownPct = Self.points(keys.lenient(Double.self, .unknownPct))
                self.method = keys.lenient(String.self, .method).flatMap(Method.init(rawValue:)) ?? .unknown
                self.preliminary = keys.lenient(Bool.self, .preliminary) ?? false
                self.reason = keys.lenient(String.self, .reason)
            }

            private static func points(_ value: Double?) -> Double {
                guard let value, value.isFinite else { return 0 }
                return max(0, value)
            }

            public var total: Double {
                self.youPct + self.othersPct + self.unknownPct
            }
        }
    }

    /// Window forecast: middle and 20–80 % spread, based on how my past windows continued.
    public struct Forecast: Decodable, Sendable, Equatable {
        /// When it was computed and from which percentage.
        public var at: Double?
        public var pct: Double?
        public var ratePerHour: Double?
        /// Percentage at the reset: likely, with a calm continuation and with a heavy one.
        public var endPct: Double?
        public var endLo: Double?
        public var endHi: Double?
        /// When the limit runs out: likely, earliest and latest (no value means it lasts until the reset).
        public var hitAt: Double?
        public var hitEarly: Double?
        public var hitLate: Double?
        /// How many checks on past windows stand behind the spread (0 means not enough history yet).
        public var checks: Double?
        /// Whose history the spread comes from: "own", "pooled" (all accounts together) or "default".
        public var bandSource: String?
    }

    /// My spend in one weekly limit window.
    public struct Week: Decodable, Sendable, Equatable, Identifiable {
        public var start: Double
        public var end: Double
        public var current: Bool?
        public var usd: Spend?
        public var tokens: Double?
        /// How high the weekly limit got in this window, in percent (if there were readings).
        public var peakPct: Double?
        /// By model family: [dollars, tokens].
        public var m: [String: [Double]]?
        /// When the `peakPct` reading was taken.
        public var peakAt: Double?
        /// The peak was read in the last hours of the window, so it is about where the week ended.
        /// False: the week used at least this much.
        public var peakFinal: Bool?
        /// This Mac's Claude Code in points of that week's limit; null when the account has no rate.
        public var minePct: Double?
        /// `minePct` by model family (opus, fable, sonnet, haiku, other).
        public var minePctByModel: [String: Double]?
        /// `peakPct - minePct`, never below zero.
        public var othersPct: Double?
        /// The weekly limit was reset inside this window, at this time (epoch seconds). The limit fields above
        /// (`peakPct`, `peakAt`, `peakFinal`, `minePct`, `minePctByModel`, `othersPct`) then count from the reset;
        /// `usd`, `m` and `tokens` stay the whole week.
        public var resetAt: Double?
        /// Provider pages: no readings that week, so its boundaries are a guess (`peakPct` is null).
        public var approx: Bool?
        /// Provider pages: the window was reset early; `end` is when the next one began, this is when it was due.
        public var scheduledEnd: Double?
        /// Provider pages: points of that week's peak that cannot be told apart (this Mac or others).
        public var unknownPct: Double?
        /// Provider pages: how the week was split (`Window.Split.Method` raw values).
        public var splitMethod: String?

        public var id: Double {
            self.end
        }

        enum CodingKeys: String, CodingKey {
            case start, end, current, usd, tokens, peakPct, m
            case peakAt, peakFinal, minePct, minePctByModel, othersPct, resetAt, approx, scheduledEnd
            case unknownPct, splitMethod
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.start = try container.decode(Double.self, forKey: .start)
            self.end = try container.decode(Double.self, forKey: .end)
            self.current = try container.decodeIfPresent(Bool.self, forKey: .current)
            self.usd = try container.decodeIfPresent(Spend.self, forKey: .usd)
            self.tokens = try container.decodeIfPresent(Double.self, forKey: .tokens)
            self.peakPct = try container.decodeIfPresent(Double.self, forKey: .peakPct)
            self.m = try container.decodeIfPresent([String: [Double]].self, forKey: .m)
            // Fields being added by the collector right now: a value of an unexpected shape is dropped
            // rather than costing the whole summary.
            self.peakAt = try? container.decodeIfPresent(Double.self, forKey: .peakAt)
            self.peakFinal = try? container.decodeIfPresent(Bool.self, forKey: .peakFinal)
            self.minePct = try? container.decodeIfPresent(Double.self, forKey: .minePct)
            self.minePctByModel = (try? container.decodeIfPresent([String: Double?].self, forKey: .minePctByModel))?
                .compactMapValues { $0 }
            self.othersPct = try? container.decodeIfPresent(Double.self, forKey: .othersPct)
            self.resetAt = (try? container.decodeIfPresent(Double.self, forKey: .resetAt))
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.approx = try? container.decodeIfPresent(Bool.self, forKey: .approx)
            self.scheduledEnd = (try? container.decodeIfPresent(Double.self, forKey: .scheduledEnd))
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.unknownPct = container.lenient(Double.self, .unknownPct)
                .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            self.splitMethod = container.lenient(String.self, .splitMethod)
        }
    }

    public struct Spend: Decodable, Sendable, Equatable {
        public var opus: Double?
        public var fable: Double?
        public var other: Double?

        public var total: Double {
            (self.opus ?? 0) + (self.fable ?? 0) + (self.other ?? 0)
        }
    }

    public struct Rate: Decodable, Sendable, Equatable {
        public var usdPer100: Double?
        public var pairs: Double?
        public var source: String?

        enum CodingKeys: String, CodingKey {
            case pairs, source
            case usdPer100 = "usd_per_100"
        }
    }

    public struct DriftPoint: Decodable, Sendable, Equatable {
        public var weekEnd: Double
        public var usdPer100: Double
        public var pairs: Double?
        /// What I used that week: this determines how many "real" dollars the limit holds.
        public var spend: Spend?

        enum CodingKeys: String, CodingKey {
            case weekEnd, pairs, spend
            case usdPer100 = "usd_per_100"
        }
    }

    public struct Poll: Decodable, Sendable, Equatable {
        public var ts: Double?
        public var status: String?
    }

    public struct Day: Decodable, Sendable, Equatable {
        public var day: String
        public var opus: Double?
        public var fable: Double?
        public var other: Double?
        public var tokens: Double?
        /// By model family: [dollars, tokens].
        public var m: [String: [Double]]?
        /// Provider pages: tokens of models without a price that day, by model id (only on such days).
        public var unpriced: [String: Double]?

        public var total: Double {
            (self.opus ?? 0) + (self.fable ?? 0) + (self.other ?? 0)
        }

        enum CodingKeys: String, CodingKey {
            case day, opus, fable, other, tokens, m, unpriced
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.day = try container.decode(String.self, forKey: .day)
            self.opus = try container.decodeIfPresent(Double.self, forKey: .opus)
            self.fable = try container.decodeIfPresent(Double.self, forKey: .fable)
            self.other = try container.decodeIfPresent(Double.self, forKey: .other)
            self.tokens = try container.decodeIfPresent(Double.self, forKey: .tokens)
            self.m = try container.decodeIfPresent([String: [Double]].self, forKey: .m)
            // Newer than the rest of the day: a value of another shape is dropped, not the summary.
            self.unpriced = try? container.decodeIfPresent([String: Double].self, forKey: .unpriced)
        }
    }

    public struct Value: Decodable, Sendable, Equatable {
        public var weekOpusUsd: Double?
        public var monthOpusUsd: Double?
        public var weekFableCapUsd: Double?
        public var fableCapShareOfWeek: Double?
        public var weekMixUsd: Double?
        public var weekAllFableUsd: Double?
        public var timesPrice: Double?
    }
}

extension UsagePanelState {
    /// Active account first, the rest in Claude Switcher order.
    public var orderedAccounts: [Account] {
        let indexed = self.accounts.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { lhs, rhs in
            if lhs.1.isActive != rhs.1.isActive {
                return lhs.1.isActive
            }
            return lhs.0 < rhs.0
        }.map(\.1)
    }

    /// The Fable/Opus ratio of one account, falling back to the summary-wide one.
    public func fableWeight(for account: Account) -> Double {
        account.kFable ?? self.kFable ?? 1
    }

    /// The ratio as text: one number when all accounts agree, otherwise the range. An account the collector
    /// failed on has no ratio of its own and does not widen the range.
    public var fableWeightText: String {
        let counted = self.accounts.filter { !$0.isUnavailable }
        let values = (counted.isEmpty ? self.accounts : counted).map { (self.fableWeight(for: $0) * 100).rounded() / 100 }
        guard let low = values.min(), let high = values.max() else { return "1.00" }
        let lowText = String(format: "%.2f", low)
        return low == high ? lowText : "\(lowText)–\(String(format: "%.2f", high))"
    }

    public var generatedDate: Date {
        Date(timeIntervalSince1970: self.generatedAt)
    }

    /// The collector runs every five minutes; if the summary is older, it did not run.
    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(self.generatedDate) > 20 * 60
    }

    public var total30dUsd: Double {
        self.accounts.reduce(0) { $0 + ($1.usd30d ?? 0) }
    }

    /// Dollars of the last 24 hours across all subscriptions: `spend24h.usd`, else the sum of whatever accounts
    /// and provider blocks carry `usd24h`; nil when none does.
    public var rolling24hUsd: Double? {
        if let usd = self.spend24h?.usd { return usd }
        return Self.sum(self.rolling24hAccounts.map(\.usd24h))
    }

    /// Tokens of the last 24 hours, with the same fallback as `rolling24hUsd`.
    public var rolling24hTokens: Double? {
        if let spend = self.spend24h { return spend.tokens }
        return Self.sum(self.rolling24hAccounts.map(\.tokens24h))
    }

    /// True when some subscription or Claude account failed this time, so `rolling24hUsd` is a lower bound.
    public var isRolling24hPartial: Bool {
        if let spend = self.spend24h {
            if spend.partial == true { return true }
            if let by = spend.byProvider {
                if by.claude?.error != nil || (by.claude?.failedAccounts ?? 0) > 0 { return true }
                if by.codex?.error != nil || by.antigravity?.error != nil { return true }
            }
            return false
        }
        return self.accounts.contains(where: \.isUnavailable)
            || self.codex?.error != nil
            || self.antigravity?.error != nil
    }

    private var rolling24hAccounts: [Account] {
        self.accounts + [self.codex, self.antigravity].compactMap { block in
            guard let block, block.error == nil else { return nil }
            return block.account
        }
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }

    public var totalTodayUsd: Double {
        self.accounts.reduce(0) { $0 + ($1.usdToday ?? 0) }
    }

    public var hasDrift: Bool {
        self.accounts.contains { ($0.drift?.count ?? 0) >= 2 }
    }

    public var hasDaily: Bool {
        self.accounts.contains { !($0.daily ?? []).isEmpty }
    }
}

extension UsagePanelState {
    /// Top-level `spend24h` of `state.json`.
    public struct Spend24h: Decodable, Sendable, Equatable {
        public var usd: Double
        public var tokens: Double?
        /// When the collector added it up (seconds since 1970).
        public var asOf: Double?
        /// True when any provider or Claude account failed, so `usd` is a lower bound.
        public var partial: Bool?
        public var byProvider: ByProvider?

        public init(
            usd: Double,
            tokens: Double? = nil,
            asOf: Double? = nil,
            partial: Bool? = nil,
            byProvider: ByProvider? = nil)
        {
            self.usd = usd
            self.tokens = tokens
            self.asOf = asOf
            self.partial = partial
            self.byProvider = byProvider
        }

        enum CodingKeys: String, CodingKey {
            case usd, tokens, asOf, partial, byProvider
        }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            self.usd = try keys.decode(Double.self, forKey: .usd)
            self.tokens = keys.lenient(Double.self, .tokens)
            self.asOf = keys.lenient(Double.self, .asOf)
            self.partial = keys.lenient(Bool.self, .partial)
            self.byProvider = keys.lenient(ByProvider.self, .byProvider)
        }

        public struct ByProvider: Decodable, Sendable, Equatable {
            public var claude: Provider?
            public var codex: Provider?
            public var antigravity: Provider?

            public init(claude: Provider? = nil, codex: Provider? = nil, antigravity: Provider? = nil) {
                self.claude = claude
                self.codex = codex
                self.antigravity = antigravity
            }

            enum CodingKeys: String, CodingKey {
                case claude, codex, antigravity
            }

            /// Provider by provider: one malformed entry drops only itself.
            public init(from decoder: Decoder) throws {
                let keys = try decoder.container(keyedBy: CodingKeys.self)
                self.claude = keys.lenient(Provider.self, .claude)
                self.codex = keys.lenient(Provider.self, .codex)
                self.antigravity = keys.lenient(Provider.self, .antigravity)
            }
        }

        public struct Provider: Decodable, Sendable, Equatable {
            public var usd: Double
            public var tokens: Double?
            /// Claude only: per account.
            public var accounts: [AccountEntry]?
            /// Claude only: accounts whose step failed this time.
            public var failedAccounts: Int?
            /// Set when this provider's step failed; `usd` is then 0.
            public var error: String?

            public init(
                usd: Double,
                tokens: Double? = nil,
                accounts: [AccountEntry]? = nil,
                failedAccounts: Int? = nil,
                error: String? = nil)
            {
                self.usd = usd
                self.tokens = tokens
                self.accounts = accounts
                self.failedAccounts = failedAccounts
                self.error = error
            }

            enum CodingKeys: String, CodingKey {
                case usd, tokens, accounts, failedAccounts, error
            }

            public init(from decoder: Decoder) throws {
                let keys = try decoder.container(keyedBy: CodingKeys.self)
                self.usd = try keys.decode(Double.self, forKey: .usd)
                self.tokens = keys.lenient(Double.self, .tokens)
                self.accounts = keys.lenient([Lenient<AccountEntry>].self, .accounts)?.compactMap(\.value)
                self.failedAccounts = keys.lenient(Int.self, .failedAccounts)
                self.error = keys.lenient(String.self, .error)
            }
        }

        public struct AccountEntry: Decodable, Sendable, Equatable, Identifiable {
            public var uuid: String
            public var name: String
            public var short: String?
            public var usd: Double
            public var tokens: Double?

            public var id: String {
                self.uuid
            }

            public init(uuid: String, name: String, short: String? = nil, usd: Double, tokens: Double? = nil) {
                self.uuid = uuid
                self.name = name
                self.short = short
                self.usd = usd
                self.tokens = tokens
            }
        }
    }
}

public enum UsagePanelStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher/usage/state.json")
    }

    /// Reads the summary. `nil` if the file is missing or cannot be parsed: then CodexBar
    /// shows its usual cards.
    public static func modificationDate(of url: URL = UsagePanelStore.defaultURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func load(from url: URL = UsagePanelStore.defaultURL) -> UsagePanelState? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return nil }
        guard let state = try? JSONDecoder().decode(UsagePanelState.self, from: data),
              !state.accounts.isEmpty
        else { return nil }
        return state
    }
}
