import Foundation

extension UsagePanelState {
    /// Top-level `overviewTimeline` of `state.json` (`usage/timeline.py`): what every account used over the last
    /// 24 hours, 72 hours and 7 days, told apart into this Mac, others and what cannot be told yet.
    ///
    /// Every series is cumulative from the start of its range and sits on one fixed grid: sample `i` is at
    /// `from + i * stepSec`. Per-account quota is in points of that account's weekly limit; the combined quota
    /// is in whole weekly limits (points / 100, added across accounts).
    public struct OverviewTimeline: Decodable, Sendable, Equatable {
        public var version: Int?
        public var asOf: Double?
        /// Which limit the quota series count: "7d".
        public var quotaWindow: String?
        public var providers: [String: ProviderStamp]
        public var accounts: [Entry]
        /// By range name: "24h", "72h", "7d".
        public var ranges: [String: Range]

        enum CodingKeys: String, CodingKey {
            case version, asOf, quotaWindow, providers, accounts, ranges
        }

        /// Part by part: one malformed account or range drops only itself. A block without `ranges` (the
        /// collector's `{"error": …}`) is no timeline at all.
        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            self.ranges = try keys.decode([String: Lenient<Range>].self, forKey: .ranges).compactMapValues(\.value)
            self.version = keys.lenient(Int.self, .version)
            self.asOf = keys.lenient(Double.self, .asOf)
            self.quotaWindow = keys.lenient(String.self, .quotaWindow)
            self.providers = keys.lenient([String: Lenient<ProviderStamp>].self, .providers)?
                .compactMapValues(\.value) ?? [:]
            self.accounts = keys.lenient([Lenient<Entry>].self, .accounts)?.compactMap(\.value) ?? []
        }

        public func range(_ name: String) -> Range? {
            self.ranges[name]
        }

        public func entry(_ key: String) -> Entry? {
            self.accounts.first { $0.key == key }
        }

        /// A provider's part could not be rebuilt this time, so its numbers are a lower bound.
        public var partialProviders: [String] {
            self.providers.filter(\.value.partial).keys.sorted()
        }
    }
}

extension UsagePanelState.OverviewTimeline {
    public struct ProviderStamp: Decodable, Sendable, Equatable {
        public var builtAt: Double?
        public var partial: Bool

        enum CodingKeys: String, CodingKey {
            case builtAt, partial
        }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            self.builtAt = keys.lenient(Double.self, .builtAt)
            self.partial = keys.lenient(Bool.self, .partial) ?? false
        }
    }

    /// One account of the timeline: "claude:<uuid>", "codex:<uuid>", "antigravity:<uuid>".
    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public var key: String
        public var provider: String
        public var uuid: String?
        public var short: String?
        public var planName: String?
        public var active: Bool
        /// The account has a dollars-per-percent rate, so others' use can be put in API dollars.
        public var rated: Bool
        public var usdPer100: Double?
        /// The time of the last reading the quota series reaches.
        public var quotaThrough: Double?

        public var id: String {
            self.key
        }

        enum CodingKeys: String, CodingKey {
            case key, provider, uuid, short, planName, active, rated, usdPer100, quotaThrough
        }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            self.key = try keys.decode(String.self, forKey: .key)
            self.provider = keys.lenient(String.self, .provider)
                ?? String(self.key.split(separator: ":").first ?? "")
            self.uuid = keys.lenient(String.self, .uuid)
            self.short = keys.lenient(String.self, .short)
            self.planName = keys.lenient(String.self, .planName)
            self.active = keys.lenient(Bool.self, .active) ?? false
            self.usdPer100 = keys.lenient(Double.self, .usdPer100).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.rated = keys.lenient(Bool.self, .rated) ?? (self.usdPer100 != nil)
            self.quotaThrough = keys.lenient(Double.self, .quotaThrough)
        }
    }

    /// What is known about one sample of a quota series.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// No fresh reading around this time: the value is carried from the last one.
        public static let gap = Flags(rawValue: 1)
        /// This Mac's logs do not cover the time fully, so "you" may be low.
        public static let incomplete = Flags(rawValue: 2)
        /// "You" comes from a measured rate.
        public static let calibrated = Flags(rawValue: 4)
        /// A change that straddles the start of the range is left out.
        public static let boundary = Flags(rawValue: 8)
        /// The limit was full or was reset: the readings could not move while the use went on.
        public static let resetTail = Flags(rawValue: 16)

        /// The flags of a sample as the summary writes them: a number. Anything that is no small whole number
        /// (missing, negative, NaN, 1e300) is no flags; `Int(_:)` would trap on the last two.
        public init(number: Double?) {
            guard let number, number.isFinite, number >= 0, number <= Double(Int32.max) else {
                self.init(rawValue: 0)
                return
            }
            self.init(rawValue: Int(number))
        }
    }

    /// Cumulative quota at one grid point: `[you, others, unknown, flags]`.
    public struct Sample: Decodable, Sendable, Equatable {
        public var you: Double
        public var others: Double
        public var unknown: Double
        public var flags: Flags

        public init(you: Double, others: Double, unknown: Double = 0, flags: Flags = []) {
            self.you = you
            self.others = others
            self.unknown = unknown
            self.flags = flags
        }

        /// Throws on anything but three finite numbers first, so a `Lenient` wrapper reads it as a missing sample.
        public init(from decoder: Decoder) throws {
            let row = try decoder.singleValueContainer().decode([Double?].self)
            guard row.count >= 3,
                  let you = row[0], let others = row[1], let unknown = row[2],
                  you.isFinite, others.isFinite, unknown.isFinite
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A quota sample is [you, others, unknown, flags]"))
            }
            self.you = max(0, you)
            self.others = max(0, others)
            self.unknown = max(0, unknown)
            self.flags = Flags(number: row.count > 3 ? row[3] : nil)
        }

        public var total: Double {
            self.you + self.others + self.unknown
        }
    }

    /// The series of one account, or of all of them together.
    public struct Series: Decodable, Sendable, Equatable {
        /// A nil entry is a grid point the collector could not fill.
        public var quota: [Sample?]
        /// This Mac's API dollars.
        public var usdYou: [Double?]
        /// Others' use at this account's rate; nil for an account without a rate.
        public var usdOthers: [Double?]?
        /// Per account: this Mac's tokens over the whole range.
        public var tokensYou: Double?
        /// Combined only: accounts whose others' use has no dollar figure.
        public var unratedAccounts: [String]
        /// Combined only: accounts with a share of the range that is not split yet (this Mac or others), so
        /// neither "you" nor "others" is the whole story there. Nil when the collector does not write the list.
        public var unknownAccounts: [String]?
        public var totalYouUsd: Double?
        public var totalYouTokens: Double?
        public var totalOthersUsd: Double?
        public var totalYouQuota: Double?
        public var totalOthersQuota: Double?
        public var totalUnknownQuota: Double?

        enum CodingKeys: String, CodingKey {
            case quota, usdYou, usdOthers, tokensYou, unratedAccounts, unknownAccounts
            case totalYouUsd, totalYouTokens, totalOthersUsd, totalYouQuota, totalOthersQuota, totalUnknownQuota
        }

        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            self.quota = keys.lenient([Lenient<Sample>].self, .quota)?.map(\.value) ?? []
            self.usdYou = Self.numbers(keys, .usdYou) ?? []
            self.usdOthers = Self.numbers(keys, .usdOthers)
            self.tokensYou = keys.lenient(Double.self, .tokensYou)
            self.unratedAccounts = keys.lenient([Lenient<String>].self, .unratedAccounts)?.compactMap(\.value) ?? []
            self.unknownAccounts = keys.lenient([Lenient<String>].self, .unknownAccounts)?.compactMap(\.value)
            self.totalYouUsd = keys.lenient(Double.self, .totalYouUsd)
            self.totalYouTokens = keys.lenient(Double.self, .totalYouTokens)
            self.totalOthersUsd = keys.lenient(Double.self, .totalOthersUsd)
            self.totalYouQuota = keys.lenient(Double.self, .totalYouQuota)
            self.totalOthersQuota = keys.lenient(Double.self, .totalOthersQuota)
            self.totalUnknownQuota = keys.lenient(Double.self, .totalUnknownQuota)
        }

        private static func numbers(_ keys: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Double?]? {
            keys.lenient([Lenient<Double>].self, key)?.map { entry in
                entry.value.flatMap { $0.isFinite ? max(0, $0) : nil }
            }
        }

        /// The quota sample at `index`, or the last one before it when that grid point is missing.
        public func sample(at index: Int) -> Sample? {
            guard !self.quota.isEmpty else { return nil }
            var cursor = min(max(0, index), self.quota.count - 1)
            while cursor >= 0 {
                if let sample = self.quota[cursor] { return sample }
                cursor -= 1
            }
            return nil
        }

        public func usdYou(at index: Int) -> Double? {
            Self.value(self.usdYou, at: index)
        }

        public func usdOthers(at index: Int) -> Double? {
            self.usdOthers.flatMap { Self.value($0, at: index) }
        }

        private static func value(_ series: [Double?], at index: Int) -> Double? {
            guard !series.isEmpty else { return nil }
            var cursor = min(max(0, index), series.count - 1)
            while cursor >= 0 {
                if let value = series[cursor] { return value }
                cursor -= 1
            }
            return nil
        }
    }

    public struct Range: Decodable, Sendable, Equatable {
        public var from: Double
        public var to: Double
        public var stepSec: Double
        public var combined: Series
        /// By `Entry.key`.
        public var accounts: [String: Series]

        enum CodingKeys: String, CodingKey {
            case from, to, stepSec, combined, accounts
        }

        /// The most grid points a range may have: the collector writes a few hundred. More (a step of a
        /// millisecond, a range of centuries) is a broken block, not a chart to allocate.
        public static let maxPoints = 2000

        /// Throws on a grid that cannot be walked (a NaN or infinite bound, no step, an end before the start,
        /// more than `maxPoints` points), so a `Lenient` wrapper drops the range and the others stay.
        public init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            self.from = try keys.decode(Double.self, forKey: .from)
            self.to = try keys.decode(Double.self, forKey: .to)
            self.stepSec = try keys.decode(Double.self, forKey: .stepSec)
            guard self.from.isFinite, self.to.isFinite, self.stepSec.isFinite,
                  self.stepSec > 0, self.to >= self.from,
                  (self.to - self.from) / self.stepSec <= Double(Self.maxPoints - 1)
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A range needs finite from <= to, a positive step and at most "
                        + "\(Self.maxPoints) points"))
            }
            self.combined = try keys.decode(Series.self, forKey: .combined)
            self.accounts = keys.lenient([String: Lenient<Series>].self, .accounts)?.compactMapValues(\.value) ?? [:]
        }

        /// How many grid points the range has: 1...`maxPoints` (the decoder checked the grid).
        public var count: Int {
            let steps = ((self.to - self.from) / self.stepSec).rounded(.down)
            guard steps.isFinite, steps >= 0 else { return 1 }
            return Int(min(steps, Double(Self.maxPoints - 1))) + 1
        }

        public func time(at index: Int) -> Double {
            self.from + Double(index) * self.stepSec
        }
    }
}
