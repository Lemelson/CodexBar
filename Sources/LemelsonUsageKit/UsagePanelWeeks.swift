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
    /// The limit was reset inside the window at this time: `used`, `mine` and `others` count from it.
    let resetAt: Double?
    /// `.single` (provider pages): one quota with no split by source, so no "you" and "others".
    let sources: UsageLimitSources

    init(
        week: UsagePanelState.Week,
        window: UsagePanelState.Window?,
        capacity: Double?,
        fableWeight: Double,
        now: Date,
        sources: UsageLimitSources = .split)
    {
        self.sources = sources
        let split = week.split
        func weight(_ family: UsageModelFamily) -> Double {
            family == .fable ? fableWeight : 1
        }
        let weighted = UsageModelFamily.allCases.map { (family: $0, usd: split[$0].usd * weight($0)) }
        let weightedTotal = weighted.reduce(0) { $0 + $1.usd }
        // The week's dollars cover the whole week: after a reset they would count the part before it too.
        let estimate = week.resetAt == nil ? capacity.flatMap { $0 > 0 ? weightedTotal / $0 * 100 : nil } : nil

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
        if sources == .single {
            mine = nil
            others = nil
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
        self.resetAt = week.resetAt
    }

    /// This Mac's share of the limit for one model, for the week's model table.
    func mine(_ family: UsageModelFamily) -> Double? {
        guard self.mine != nil else { return nil }
        return self.mineByModel.first { $0.family == family }?.pct ?? 0
    }

    /// The bar: this Mac by model, then everyone else in gray; the rest of the track is what was left.
    var barParts: [(Double, Color)] {
        if self.sources == .single {
            return [(self.used ?? 0, UsagePalette.single)]
        }
        guard self.mine != nil else { return [(self.used ?? 0, UsagePalette.others)] }
        return self.mineByModel.map { ($0.pct, $0.family.color) } + [(self.others ?? 0, UsagePalette.others)]
    }

    /// "Used 51%", "At least 51% used", "Limit hit", "Now 71% used", "No limit reading"; after a reset inside
    /// the week "After the Nov 14 reset: used 81%".
    var headline: String {
        let text: String
        if let used {
            let percent = UsageFormat.percent(used)
            text = switch self.reading {
            case .live: "Now \(percent) used"
            case .final: used >= 99.5 ? "Limit hit" : "Used \(percent)"
            case .atLeast: "At least \(percent) used"
            case .none: "No limit reading"
            }
        } else {
            text = "No limit reading"
        }
        guard let resetAt else { return text }
        return "After the \(UsageFormat.shortDay(resetAt)) reset: " + text.prefix(1).lowercased() + text.dropFirst()
    }

    /// What follows the headline: whose it was and what was left.
    /// ": you ≈34%, others ≈17% · 49% left", ", all yours", " · your part needs a rate". After a reset the
    /// headline is longer and what was left goes: the empty part of the bar shows it.
    var tail: String {
        if self.sources == .single {
            guard let used = self.used, self.resetAt == nil else { return "" }
            switch self.reading {
            case .live: return " · \(UsageFormat.percent(max(0, 100 - used))) left"
            case .final where used < 99.5: return " · \(UsageFormat.percent(max(0, 100 - used))) unused"
            default: return ""
            }
        }
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
        guard self.resetAt == nil else { return text }
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
        UsageWeekRow(week: week, limit: self.limits[week.id], selected: selected)
    }

    /// The selected week's models: tokens, dollars and the part of the weekly limit each took. The same rows
    /// and the same note for every week of the account, so pointing at another week never changes the panel's
    /// height (the panel is measured once): a model one week lacks shows zeros, and a reset is named in the
    /// one-line title.
    private func weekDetail(_ week: UsagePanelState.Week) -> some View {
        let split = week.split
        let limit = self.limits[week.id]
        let range = UsageFormat.dayRange(week.start, week.end)
        return VStack(alignment: .leading, spacing: 4) {
            Text(week.resetAt.map { "\(range) · by model · reset \(UsageFormat.shortDay($0))" }
                ?? "\(range) · your Claude Code by model")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            ForEach(self.families) { family in
                self.detailRow(family, split[family], share: limit?.mine(family))
            }
            if let note = self.detailNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Every model any week of this account shows.
    private var families: [UsageModelFamily] {
        let shown = Set(self.weeks.flatMap(\.split.shownFamilies))
        return UsageModelFamily.allCases.filter { shown.contains($0) }
    }

    /// What "of limit" means, and, when a week of the account had a reset, what it counts after one.
    private var detailNote: String? {
        let reset = self.weeks.contains { $0.resetAt != nil }
            ? "After a reset inside a week, “of limit” counts from the reset; tokens and dollars are the whole week."
            : nil
        guard let capacity = self.capacity else { return reset }
        let meaning = "“Of limit” is your part of this account's weekly limit: a full week holds "
            + "≈ \(UsageFormat.usd(capacity)) of Opus, and $1 of Fable counts as "
            + "$\(String(format: "%.2f", self.fableWeight))."
        return reset.map { meaning + " " + $0 } ?? meaning
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

// MARK: - One week as a row

/// "Nov 18 – Nov 25  now   $24 · 129M", the week's bar against its limit and "Now 27% used · 73% left": a
/// row of Claude Spend's account panel and of a provider's weekly limit panel.
struct UsageWeekRow: View {
    let week: UsagePanelState.Week
    let limit: UsageWeekLimit?
    var selected = false

    var body: some View {
        let split = self.week.split
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // A window without readings has guessed boundaries: "≈".
                Text((self.week.approx == true ? "≈ " : "") + UsageFormat.dayRange(self.week.start, self.week.end))
                    .font(.system(size: 11, weight: .medium))
                if self.week.current == true {
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
                (Text(self.week.approx == true ? "No readings that week" : limit.headline).foregroundStyle(.primary)
                    + Text(limit.tail + self.earlyReset))
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
            Color.primary.opacity(self.selected ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
    }

    /// " · reset early": the window ended (the next one began) well before the reset it was due at.
    private var earlyReset: String {
        guard let due = self.week.scheduledEnd, due - self.week.end > 3600 else { return "" }
        return " · reset early"
    }
}

// MARK: - A provider's weekly windows

/// The last few weekly windows of a single-quota account (Antigravity, Codex), newest first, drawn with the
/// rows of Claude Spend's account panel: how far each week went and what it cost on this Mac.
struct UsageWeekWindows: View {
    let account: UsagePanelState.Account
    let now: Date
    /// Rows at most: the panel sits beside the menu and must not outgrow the screen.
    var limit = 4

    var body: some View {
        let weeks = Array((self.account.weeks ?? []).sorted { $0.end > $1.end }.prefix(self.limit))
        if !weeks.isEmpty {
            let window = self.account.window(.week)
            VStack(alignment: .leading, spacing: 4) {
                UsageSectionLabel(text: "Weekly windows")
                VStack(spacing: 1) {
                    ForEach(weeks) { week in
                        UsageWeekRow(
                            week: week,
                            limit: UsageWeekLimit(
                                week: week, window: window, capacity: nil, fableWeight: 1, now: self.now,
                                sources: .single))
                    }
                }
                UsageNote(text: "Dollars are this Mac's use at API prices; the bar is the week's highest reading.")
            }
        }
    }
}
