import SwiftUI

// MARK: - One weekly window as parts of its limit

/// A weekly window of an account read against its limit: how far the week went from all sources, how much
/// of that was Claude Code on this Mac (by model), and what was left.
///
/// Past weeks come from the collector's `peakPct` / `minePct` / `minePctByModel` / `othersPct`; a summary
/// without them falls back to the week's dollars through the account's rate. The current week uses the live
/// window, as the Limits page does.
struct UsageWeekLimit: Equatable {
    enum Reading: Equatable {
        /// The current window: used so far and left.
        case live
        /// Read close to the end of the window: about where the week ended.
        case final
        /// The highest reading came earlier: the week used at least this much.
        case atLeast
        /// No reading of the limit in that window.
        case none
    }

    struct Part: Equatable, Identifiable {
        let family: UsageModelFamily
        let pct: Double

        var id: UsageModelFamily {
            self.family
        }
    }

    let reading: Reading
    /// All sources, in percent of the limit.
    let used: Double?
    /// Claude Code on this Mac; nil when the account has no rate yet.
    let mine: Double?
    let mineByModel: [Part]
    let others: Double?

    init(
        week: UsagePanelState.Week,
        window: UsagePanelState.Window?,
        capacity: Double?,
        fableWeight: Double,
        now: Date)
    {
        let split = week.split
        func weight(_ family: UsageModelFamily) -> Double {
            family == .fable ? fableWeight : 1
        }
        let weighted = UsageModelFamily.allCases.map { (family: $0, usd: split[$0].usd * weight($0)) }
        let weightedTotal = weighted.reduce(0) { $0 + $1.usd }
        let estimate = capacity.flatMap { $0 > 0 ? weightedTotal / $0 * 100 : nil }

        var used = week.peakPct
        var mine = week.minePct ?? estimate
        var others = week.othersPct
        var reading: Reading
        if week.current == true, let window, window.rolled != true, let pct = window.pct,
           let resetsAt = window.resetsAt, resetsAt > now.timeIntervalSince1970, abs(resetsAt - week.end) < 86400
        {
            reading = .live
            used = pct
            mine = window.mine ?? mine
            others = window.outside
        } else if let peak = used {
            reading = week.peakFinal == true || peak >= 99.5 ? .final : .atLeast
        } else {
            reading = .none
        }
        // This Mac's part is an estimate through the dollar rate; it can come out above the reading.
        // An early peak is then the weaker number, a live or late one the stronger.
        if let total = used, let part = mine, part > total {
            if reading == .atLeast {
                used = part
            } else {
                mine = total
            }
        }
        if let total = used, let part = mine {
            others = max(0, total - part)
        }

        var parts: [Part] = []
        if let mine, mine > 0 {
            let given = week.minePctByModel ?? [:]
            let givenTotal = given.values.reduce(0, +)
            for family in UsageModelFamily.allCases {
                let share = givenTotal > 0
                    ? (given[family.rawValue] ?? 0) / givenTotal
                    : (weightedTotal > 0 ? split[family].usd * weight(family) / weightedTotal : 0)
                if share > 0 {
                    parts.append(Part(family: family, pct: mine * share))
                }
            }
        }
        self.reading = reading
        self.used = used
        self.mine = mine
        self.mineByModel = parts
        self.others = others
    }

    /// This Mac's share of the limit for one model, for the week's model table.
    func mine(_ family: UsageModelFamily) -> Double? {
        guard self.mine != nil else { return nil }
        return self.mineByModel.first { $0.family == family }?.pct ?? 0
    }

    /// The bar: this Mac by model, then everyone else in gray; the rest of the track is what was left.
    var barParts: [(Double, Color)] {
        guard self.mine != nil else { return [(self.used ?? 0, UsagePalette.others)] }
        return self.mineByModel.map { ($0.pct, $0.family.color) } + [(self.others ?? 0, UsagePalette.others)]
    }

    /// "Used 51%", "At least 51% used", "Limit hit", "Now 71% used", "No limit reading".
    var headline: String {
        guard let used else { return "No limit reading" }
        let percent = UsageFormat.percent(used)
        switch self.reading {
        case .live: return "Now \(percent) used"
        case .final: return used >= 99.5 ? "Limit hit" : "Used \(percent)"
        case .atLeast: return "At least \(percent) used"
        case .none: return "No limit reading"
        }
    }

    /// What follows the headline: whose it was and what was left.
    /// ": you ≈34%, others ≈17% · 49% left", ", all yours", " · your part needs a rate".
    var tail: String {
        guard let mine else {
            return self.used == nil ? "" : " · your part needs a rate"
        }
        let you = "you ≈\(UsageFormat.percent(mine))"
        guard let used = self.used else { return ": \(you)" }
        var text: String
        let others = self.others ?? 0
        if others < 0.5 {
            text = mine < 0.5 ? "" : ", all yours"
        } else {
            let sign = self.reading == .atLeast ? "≥" : "≈"
            text = ": \(you), others \(sign)\(UsageFormat.percent(others))"
        }
        let left = max(0, 100 - used)
        switch self.reading {
        case .live:
            text += " · \(UsageFormat.percent(left)) left"
        case .final where used < 99.5:
            text += " · \(UsageFormat.percent(left)) unused"
        default:
            break
        }
        return text
    }
}

// MARK: - The account panel's weeks

/// Title, one row per weekly limit window and the models of the pointed-at week.
struct UsageSpendWeekList: View {
    let account: UsagePanelState.Account
    let fableWeight: Double
    /// Hidden accounts in the stack must not track the mouse: tracking areas ignore SwiftUI opacity,
    /// so a hidden account would follow the pointer over the visible one's weeks.
    let isShown: Bool
    private let weeks: [UsagePanelState.Week]
    /// By week id, computed once: pointing at a week only changes which one is selected.
    private let limits: [Double: UsageWeekLimit]
    @State private var hoveredWeek: Double?

    init(account: UsagePanelState.Account, fableWeight: Double, isShown: Bool, now: Date) {
        self.account = account
        self.fableWeight = fableWeight
        self.isShown = isShown
        self.weeks = account.weeks ?? []
        let window = account.window(.week)
        let capacity = account.rates?["7d"]?.usdPer100
        var limits: [Double: UsageWeekLimit] = [:]
        for week in self.weeks {
            limits[week.id] = UsageWeekLimit(
                week: week, window: window, capacity: capacity, fableWeight: fableWeight, now: now)
        }
        self.limits = limits
    }

    /// How many Opus dollars this account's weekly limit holds.
    private var capacity: Double? {
        self.account.rates?["7d"]?.usdPer100
    }

    var body: some View {
        let weeks = self.weeks
        let shown = weeks.first { $0.id == self.hoveredWeek } ?? weeks.first
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(
                title: "\(self.account.displayName) · your Claude Code spend",
                subtitle: "This Mac only, dollars at API prices.")
            if let shown {
                VStack(alignment: .leading, spacing: 2) {
                    UsageSectionLabel(text: "Weekly limit, week by week · point at one")
                    UsageNote(text: "Each bar is one week's limit: colors are your Claude Code on this Mac, "
                        + "gray is other use, empty was left.")
                }
                VStack(spacing: 1) {
                    ForEach(weeks) { week in
                        self.weekRow(week, selected: week.id == shown.id)
                            .overlay {
                                if self.isShown {
                                    UsageMouseTracker { location in
                                        self.hover(week.id, inside: location != nil)
                                    }
                                }
                            }
                    }
                }
                self.weekDetail(shown)
            } else {
                UsageNote(text: "Weekly windows appear after the first limit reading of this account.")
            }
        }
        .onChange(of: self.isShown) { _, isShown in
            if !isShown, self.hoveredWeek != nil {
                self.hoveredWeek = nil
            }
        }
    }

    private func hover(_ id: Double, inside: Bool) {
        if inside {
            if self.hoveredWeek != id {
                self.hoveredWeek = id
            }
        } else if self.hoveredWeek == id {
            self.hoveredWeek = nil
        }
    }

    private func weekRow(_ week: UsagePanelState.Week, selected: Bool) -> some View {
        let split = week.split
        let limit = self.limits[week.id]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.dayRange(week.start, week.end))
                    .font(.system(size: 11, weight: .medium))
                if week.current == true {
                    Text("now")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(UsagePalette.you.opacity(0.22), in: Capsule())
                }
                Spacer(minLength: 6)
                Text("\(UsageFormat.usd(split.total.usd)) · \(UsageFormat.tokens(split.total.tokens))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            if let limit {
                UsageSplitBar(parts: limit.barParts, scale: 100)
                (Text(limit.headline).foregroundStyle(.primary) + Text(limit.tail))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(selected ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
    }

    /// The selected week's models: tokens, dollars and the part of the weekly limit each took.
    private func weekDetail(_ week: UsagePanelState.Week) -> some View {
        let split = week.split
        let limit = self.limits[week.id]
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(UsageFormat.dayRange(week.start, week.end)) · your Claude Code by model")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            ForEach(split.shownFamilies) { family in
                self.detailRow(family, split[family], share: limit?.mine(family))
            }
            if let capacity = self.capacity {
                Text("“Of limit” is your part of this account's weekly limit: a full week holds "
                    + "≈ \(UsageFormat.usd(capacity)) of Opus, and $1 of Fable counts as "
                    + "$\(String(format: "%.2f", self.fableWeight)).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ family: UsageModelFamily, _ use: UsageModelUse, share: Double?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(family.color)
                .frame(width: 8, height: 8)
            Text(family.title)
                .font(.system(size: 11))
                .frame(width: UsageModelRow.claudeNameWidth, alignment: .leading)
            Text("\(UsageFormat.tokens(use.tokens)) tok")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            Text(UsageFormat.usdFine(use.usd))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
            Spacer(minLength: 4)
            if let share {
                Text("≈ \(UsageFormat.percentFine(share)) of limit")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}
