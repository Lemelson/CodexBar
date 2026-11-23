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
    public var accounts: [Account]
    /// Gemini use through Antigravity (`usage/ANTIGRAVITY-STATE.md`). Decoded leniently: a malformed
    /// block never breaks the Claude part of the summary.
    public var antigravity: UsageAntigravityBlock?

    enum CodingKeys: String, CodingKey {
        case schema, generatedAt, accounts, dashboardPath, collector, vpnUp, antigravity
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
        public var usd7d: Double?
        public var tokens7d: Double?
        public var usd30d: Double?
        public var tokens30d: Double?
        /// Earliest spend record of this account on this Mac.
        public var trackedSince: Double?
        public var value: Value?

        public var id: String {
            self.uuid
        }

        public var isActive: Bool {
            self.active ?? false
        }

        public var needsVPN: Bool {
            self.useHapp ?? false
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
        /// Window progress: [time, limit percentage, of which mine].
        public var series: [[Double?]]?
        /// Where the window will end up at the reset: computed by the collector from the window progress and past windows.
        public var forecast: Forecast?

        /// The forecast is valid while the summary is fresh and the window has not been reset.
        public func liveForecast(now: Date) -> Forecast? {
            guard self.rolled != true,
                  let forecast = self.forecast,
                  let at = forecast.at,
                  let resetsAt = self.resetsAt
            else { return nil }
            let stamp = now.timeIntervalSince1970
            return stamp - at < 30 * 60 && resetsAt > stamp ? forecast : nil
        }

        public struct Point: Sendable, Equatable, Identifiable {
            public var time: Double
            public var used: Double
            public var mine: Double?

            public var id: Double {
                self.time
            }
        }

        public var points: [Point] {
            (self.series ?? []).compactMap { row in
                guard row.count >= 2, let time = row[0], let used = row[1] else { return nil }
                return Point(time: time, used: used, mine: row.count > 2 ? row[2] : nil)
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

        public var id: Double {
            self.end
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

        public var total: Double {
            (self.opus ?? 0) + (self.fable ?? 0) + (self.other ?? 0)
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

    /// The ratio as text: one number when all accounts agree, otherwise the range.
    public var fableWeightText: String {
        let values = self.accounts.map { (self.fableWeight(for: $0) * 100).rounded() / 100 }
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
