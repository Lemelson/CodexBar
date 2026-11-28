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
    /// Provider pages with a split: points nobody can be given yet (this Mac or others). Nil elsewhere.
    let unknown: Double?
    /// The limit was reset inside the window at this time: `used`, `mine` and `others` count from it.
    let resetAt: Double?
    /// `.single` (provider pages without a split): one quota, so no "you" and "others". `.local` (provider
    /// pages with the collector's split): you, others and what is not split yet, exactly as the collector
    /// wrote them: nothing is derived from the total here.
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
        var unknown: Double?
        if sources == .single {
            mine = nil
            others = nil
        } else if sources.local != nil {
            // The collector's own three parts. Without a rate this Mac's part is not known, and "others" is
            // only what was proven: never the total minus a guess.
            if reading == .live {
                let parts = window?.split
                let knowsMine = parts.map { $0.method == .calibrated || $0.method == .idle
                    || ($0.method == .mixed && $0.youPct > 0)
                } ?? false
                mine = knowsMine ? parts?.youPct : nil
                others = parts?.othersPct
                unknown = parts.map { $0.unknownPct + (knowsMine ? 0 : $0.youPct) }
            } else {
                // A week split without a rate has no "you" to estimate. The collector writes null then; an
                // explicit 0 is its own statement that this Mac's part is known to be nothing, and stays.
                // Any other number under such a method is not a measurement and is dropped.
                let method = week.splitMethod.flatMap(UsagePanelState.Window.Split.Method.init(rawValue:))
                mine = method == .floor || method == .unknown ? (week.minePct == 0 ? 0 : nil) : week.minePct
                others = week.othersPct
                unknown = week.unknownPct
            }
            if let total = used {
                let known = (mine ?? 0) + (others ?? 0)
                // Whatever the parts leave of the reading is not split either.
                unknown = max(unknown ?? 0, total - known)
                if known > total, known > 0 {
                    mine = mine.map { $0 * total / known }
                    others = others.map { $0 * total / known }
                }
            }
        } else {
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
        }

        var parts: [Part] = []
        if sources == .split, let mine, mine > 0 {
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
        self.unknown = unknown
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
        if self.sources.local != nil {
            return [
                (self.mine ?? 0, UsagePalette.you),
                (self.others ?? 0, UsagePalette.others),
                (self.unknown ?? 0, UsagePalette.unsplitStripe),
            ]
        }
        guard self.mine != nil else { return [(self.used ?? 0, UsagePalette.others)] }
        return self.mineByModel.map { ($0.pct, $0.family.color) } + [(self.others ?? 0, UsagePalette.others)]
    }

    /// Which of `barParts` are hatched ("Not split yet") rather than filled.
    var hatchedBarParts: Set<Int> {
        self.sources.local == nil ? [] : [2]
    }

    /// "Used 51%", "At least 51% used", "Limit hit", "Now 71% used", "No limit reading"; after a reset inside
    /// the week "After the Nov 14 reset · used 81%" (a dot, so the parts that follow in brackets do not make
    /// a second colon).
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
        return "After the \(UsageFormat.shortDay(resetAt)) reset · " + text.prefix(1).lowercased() + text.dropFirst()
    }

    /// The parts of a week in whole percent that add up to the week's own rounded reading, so "Limit hit" is
    /// never 45% + 45% + 11%. A part under one percent keeps its own value (it reads "<1%").
    static func labels(_ parts: [Double], of used: Double) -> [Double] {
        let rounded = UsageSegment.rounded(parts, to: min(used.rounded(), parts.reduce(0, +).rounded()))
        return zip(parts, rounded).map { part, label in label >= 1 ? label : min(part, 0.49) }
    }

    /// After a reset the headline already has its own separator: ": you 4%, others 8%" becomes
    /// " (you 4%, others 8%)".
    private func closing(_ text: String) -> String {
        guard self.resetAt != nil, text.hasPrefix(": ") else { return text }
        return " (" + text.dropFirst(2) + ")"
    }

    /// What follows the headline: whose it was and what was left.
    /// ": you ≈34%, others ≈17% · 49% left", ", all yours", " · your part needs a rate". After a reset the
    /// headline is longer, what was left goes (the empty part of the bar shows it) and the parts stand in
    /// brackets: " (you <1%, others ≈60%)". "≈" never stands before "<1%" or "0%".
    var tail: String {
        if self.sources == .single {
            guard let used = self.used, self.resetAt == nil else { return "" }
            switch self.reading {
            case .live: return " · \(UsageFormat.percent(max(0, 100 - used))) left"
            case .final where used < 99.5: return " · \(UsageFormat.percent(max(0, 100 - used))) unused"
            default: return ""
            }
        }
        if self.sources.local != nil {
            return self.localTail
        }
        guard let mine else {
            return self.used == nil ? "" : " · your part needs a rate"
        }
        guard let used = self.used else { return self.closing(": you \(UsageFormat.approxPercent(mine))") }
        var text: String
        let others = self.others ?? 0
        // Rounded together, so the two parts add up to the reading the headline shows.
        let labels = Self.labels([mine, others], of: used)
        let you = "you \(UsageFormat.approxPercent(labels[0]))"
        if others < 0.5, self.reading == .atLeast, mine >= 0.5 {
            // The limit was last read early in the week (an account that was not polled then): this Mac's part
            // already covers that reading, so how much others used afterwards was never measured.
            text = ": \(you), others unknown"
        } else if others < 0.5 {
            text = mine < 0.5 ? "" : ", all yours"
        } else if self.reading == .atLeast {
            // A floor is rounded down: 0.6 is never "at least 1%".
            text = ": you \(UsageFormat.approxPercent(mine)), others \(Self.atLeast(others))"
        } else {
            text = ": \(you), others \(UsageFormat.approxPercent(labels[1]))"
        }
        let left = max(0, 100 - used)
        guard self.resetAt == nil else { return self.closing(text) }
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

extension UsageWeekLimit {
    /// "≥12%" for a proven floor, rounded down; under one percent ">0%" (never "≥1%" for 0.6).
    static func atLeast(_ value: Double) -> String {
        value >= 1 ? "≥" + UsageFormat.floorPercent(value) : ">0%"
    }

    /// A provider's week: ": you ≈8%, others ≈4%", ": others ≥4%, 9% not split", " · not split yet"; an
    /// explicit zero stays ("you 0%"). The parts are rounded together, so they add up to the reading. What
    /// was left follows only while the line stays short; after a reset the parts stand in brackets.
    fileprivate var localTail: String {
        guard let used = self.used else { return "" }
        let unknown = self.unknown ?? 0
        let others = self.others ?? 0
        var names: [String] = []
        if let mine = self.mine {
            let labels = Self.labels([mine, others, unknown], of: used)
            names.append("you \(UsageFormat.approxPercent(labels[0]))")
            if others >= 0.5 {
                names.append("others \(UsageFormat.approxPercent(labels[1]))")
            }
            if unknown >= 0.5 {
                names.append("\(UsageFormat.percent(labels[2])) not split")
                return self.closing(": " + names.joined(separator: ", "))
            }
        } else {
            // No "you": others is only what was proven, rounded down; the rest of the reading is not split.
            if others >= 0.5 {
                names.append("others \(Self.atLeast(others))")
            }
            if unknown >= 0.5 {
                guard !names.isEmpty else { return " · not split yet" }
                let rest = max(0, used.rounded() - others.rounded(.down))
                names.append("\(UsageFormat.percent(rest)) not split")
                return self.closing(": " + names.joined(separator: ", "))
            }
        }
        var text = names.isEmpty ? "" : ": " + names.joined(separator: ", ")
        guard self.resetAt == nil else { return self.closing(text) }
        switch self.reading {
        case .live: text += " · \(UsageFormat.percent(max(0, 100 - used))) left"
        case .final where used < 99.5: text += " · \(UsageFormat.percent(max(0, 100 - used))) unused"
        default: break
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
                // "≈" never stands before a zero: a model that took nothing reads "0% of limit".
                Text(share < 0.05 ? "0% of limit" : "≈ \(UsageFormat.percentFine(share)) of limit")
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
                UsageSplitBar(
                    parts: UsageSplitBar.withoutSlivers(limit.barParts),
                    scale: 100,
                    hatched: limit.hatchedBarParts,
                    minPartWidth: UsageSegmentBar.minSegmentWidth)
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
    /// `.local` when the collector splits this provider's readings; `.single` otherwise.
    var sources: UsageLimitSources = .single

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
                                sources: self.sources))
                    }
                }
                UsageNote(text: self.sources.local == nil
                    ? "Dollars are this Mac's use at API prices; the bar is the week's highest reading."
                    : "Dollars are this Mac's use at API prices. Each bar is the week's highest reading: "
                    + "orange is you, grey is others, hatched is not split yet.")
            }
        }
    }
}
