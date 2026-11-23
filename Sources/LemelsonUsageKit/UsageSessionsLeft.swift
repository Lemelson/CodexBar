import Foundation

/// How many full 5-hour sessions the rest of the weekly limit is worth, and how many still fit before the
/// weekly reset. Same idea as the stock card's "session quotas left · windows until reset" line.
public struct UsageSessionsLeft: Equatable, Sendable {
    /// Where the size of one session came from.
    public enum Basis: Equatable, Sendable {
        /// Measured by the collector from paired readings of both limits.
        case readings
        /// Ratio of this account's own dollar rates for the two limits.
        case ownRates
        /// Ratio of another account on the same plan: this one has no weekly rate yet.
        case samePlan(String)
    }

    private static let sessionSpan: Double = 5 * 3600

    /// One full 5-hour session as a percentage of the weekly limit.
    public let percentPerSession: Double
    /// Weekly limit left, in percent, as of the last reading.
    public let percentLeft: Double
    /// The rest of the weekly limit in full sessions.
    public let left: Double
    /// Time until the weekly reset in 5-hour spans; `fit` is its whole part.
    public let available: Double
    public let basis: Basis

    public var fit: Int {
        Int(self.available.rounded(.down))
    }

    /// More limit is left than time to spend it, even with back-to-back sessions.
    public var timeIsShort: Bool {
        self.left > self.available
    }

    /// The line belongs to the weekly row only; other rows get `nil`.
    public static func make(
        for kind: UsagePanelState.WindowKind,
        account: UsagePanelState.Account,
        in state: UsagePanelState,
        now: Date) -> UsageSessionsLeft?
    {
        kind == .week ? self.make(account: account, in: state, now: now) : nil
    }

    public static func make(
        account: UsagePanelState.Account,
        in state: UsagePanelState,
        now: Date) -> UsageSessionsLeft?
    {
        self.make(account: account, donors: state.accounts, now: now)
    }

    /// `donors`: accounts whose ratio may stand in when this one has no weekly rate yet (same plan only).
    /// Antigravity passes none: a Claude plan says nothing about a Google quota.
    public static func make(
        account: UsagePanelState.Account,
        donors: [UsagePanelState.Account],
        now: Date) -> UsageSessionsLeft?
    {
        // The data decides, not the plan name: the same plan may come with or without a 5-hour limit.
        guard account.has5h != false,
              account.has5h == true || account.visibleWindows.contains(where: { $0.0 == .fiveHour }),
              let week = account.window(.week),
              week.rolled != true,
              let used = week.pct,
              used < 100,
              let resetsAt = week.resetsAt
        else { return nil }
        let remaining = resetsAt - now.timeIntervalSince1970
        guard remaining > 0, remaining <= UsagePanelState.WindowKind.week.span + 120 else { return nil }
        guard let (share, basis) = self.share(of: account, donors: donors) else { return nil }
        let percentLeft = 100 - max(0, used)
        return UsageSessionsLeft(
            percentPerSession: share,
            percentLeft: percentLeft,
            left: percentLeft / share,
            available: remaining / self.sessionSpan,
            basis: basis)
    }

    private static func share(
        of account: UsagePanelState.Account,
        donors: [UsagePanelState.Account]) -> (Double, Basis)?
    {
        if let measured = account.sessionPctOfWeek, self.isPlausible(measured) {
            return (measured, .readings)
        }
        if let own = account.sessionShareFromRates {
            return (own, .ownRates)
        }
        // No weekly rate yet (too few readings). Limits are set by the plan, so an account on the same plan
        // that has both rates gives the same ratio.
        guard let plan = account.planName else { return nil }
        let donor = donors
            .filter { $0.uuid != account.uuid && $0.planName == plan && $0.has5h != false }
            .compactMap { other in other.sessionShareFromRates.map { (other, $0) } }
            .max { ($0.0.rates?["7d"]?.pairs ?? 0) < ($1.0.rates?["7d"]?.pairs ?? 0) }
        return donor.map { ($0.1, .samePlan($0.0.displayName)) }
    }

    fileprivate static func isPlausible(_ share: Double) -> Bool {
        share.isFinite && share >= 1 && share <= 100
    }

    // MARK: Text

    /// "≈4.7": one decimal below ten, none above.
    public var leftNumber: String {
        if self.left < 0.05 {
            return "≈0"
        }
        if self.left >= 9.95 {
            return "≈\(Int(self.left.rounded()))"
        }
        let text = String(format: "%.1f", self.left)
        return "≈" + (text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }

    /// Goes right after `leftNumber`: " full 5h sessions left".
    public var leftUnit: String {
        if self.left < 0.95 {
            return " of a 5h session left"
        }
        return self.left < 1.05 ? " full 5h session left" : " full 5h sessions left"
    }

    /// "21 fit before reset", "only 1 fits before reset", "none fit before reset".
    public var fitText: String {
        switch self.fit {
        case 0: self.timeIsShort ? "none fit before reset" : "fits before reset"
        case 1: self.timeIsShort ? "only 1 fits before reset" : "1 fits before reset"
        default: self.timeIsShort ? "only \(self.fit) fit before reset" : "\(self.fit) fit before reset"
        }
    }

    public var text: String {
        "\(self.leftNumber)\(self.leftUnit) · \(self.fitText)"
    }

    /// For the detail panel: the size of one session and the verdict.
    public var explanation: String {
        let size = "One full 5-hour session is about \(UsageFormat.percent(self.percentPerSession)) of this limit, "
            + "so the \(UsageFormat.percent(self.percentLeft)) left is \(self.leftNumber)\(self.leftUnit.dropLast(5))."
        let unused = "part of this limit will go unused even at full speed."
        let enough = "there is time to use all of it."
        let verdict = switch (self.fit, self.timeIsShort) {
        case (0, true): "No full session fits before the reset: \(unused)"
        case (0, false): "The reset is less than 5 hours away, but that is still enough time to use all of it."
        case (1, true): "Only 1 full session fits before the reset: \(unused)"
        case (1, false): "1 full session fits before the reset: \(enough)"
        case (_, true): "Only \(self.fit) full sessions fit before the reset: \(unused)"
        case (_, false): "\(self.fit) full sessions fit before the reset: \(enough)"
        }
        return "\(size) \(verdict)"
    }

    public var basisNote: String {
        switch self.basis {
        case .readings:
            "Session size measured from readings of both limits."
        case .ownRates:
            "Session size from this account's dollar rates for the two limits."
        case let .samePlan(name):
            "Session size taken from \(name) (same plan): too few weekly readings here yet."
        }
    }
}

extension UsagePanelState.Account {
    /// `100 × $ per 5-hour limit / $ per weekly limit`: the share of the week one full session costs.
    var sessionShareFromRates: Double? {
        guard let session = self.rates?["5h"]?.usdPer100,
              let week = self.rates?["7d"]?.usdPer100,
              session > 0, week > 0
        else { return nil }
        let share = 100 * session / week
        return UsageSessionsLeft.isPlausible(share) ? share : nil
    }

    /// Label without a parenthesized note: "Name (note)" reads as "Name".
    public var displayName: String {
        let name = self.short.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return name.isEmpty ? self.short : name
    }
}
