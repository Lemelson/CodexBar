import Charts
import SwiftUI

/// Detail panel that slides out when hovering a limit row: window progress over time, who spent how much, pace.
public struct UsageLimitDetailPanelView: View {
    let account: UsagePanelState.Account
    let kind: UsagePanelState.WindowKind
    let window: UsagePanelState.Window
    let now: Date
    let width: CGFloat
    /// Weekly limit only: see `UsageSessionsLeft.make(for:account:in:now:)`.
    let sessionsLeft: UsageSessionsLeft?
    /// Replaces the long window title ("5-hour session limit").
    let title: String?
    /// `.single` (provider pages without a split): no "You" line or "Where it went", dollars read as "your
    /// use", and a plain sentence instead of a chart with fewer than two readings. `.local` (provider pages
    /// with the collector's split): the same, plus You / Others / Not split yet on the chart and in
    /// "Where it went".
    let sources: UsageLimitSources
    /// One sentence in place of `sessionsLeft` while the session size is still being measured.
    let sessionsNote: String?

    public init(
        account: UsagePanelState.Account,
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        now: Date,
        width: CGFloat,
        sessionsLeft: UsageSessionsLeft? = nil,
        title: String? = nil,
        sources: UsageLimitSources = .split,
        sessionsNote: String? = nil)
    {
        self.account = account
        self.kind = kind
        self.window = window
        self.now = now
        self.width = width
        self.sessionsLeft = sessionsLeft
        self.title = title
        self.sources = sources
        self.sessionsNote = sessionsNote
    }

    struct Sample: Identifiable, Equatable {
        let date: Date
        let value: Double
        let series: String

        var id: String {
            "\(self.series)-\(self.date.timeIntervalSince1970)"
        }
    }

    private var used: Double {
        max(0, self.window.pct ?? 0)
    }

    private var range: ClosedRange<Date>? {
        guard let resetsAt = self.window.resetsAt else { return nil }
        return Date(timeIntervalSince1970: resetsAt - self.kind.span)...Date(timeIntervalSince1970: resetsAt)
    }

    private var subtitle: String {
        var parts = ["\(UsageFormat.percent(self.used)) used", "\(UsageFormat.percent(max(0, 100 - self.used))) left"]
        if self.window.rolled == true {
            parts.append("new window, no reading yet")
        } else if let resetsAt = self.window.resetsAt {
            parts.append("resets \(UsageFormat.weekdayTime(resetsAt))")
        }
        return parts.joined(separator: " · ")
    }

    /// Others' use between two heights of the chart.
    struct Band: Identifiable, Equatable {
        let date: Date
        let low: Double
        let high: Double
        /// The stretch of readings the band belongs to: see `Samples.run`.
        let series: String

        var id: Double {
            self.date.timeIntervalSince1970
        }
    }

    struct ChartSamples {
        var used: [Sample] = []
        var mine: [Sample] = []
        /// Provider pages: others above this Mac's part, or hanging below the reading while that part is unknown.
        var others: [Band] = []

        var drawsOthers: Bool {
            self.others.contains { $0.high - $0.low >= 0.5 }
        }
    }

    /// The window's readings as chart series. This Mac's part is drawn in stretches: a reading without it
    /// (no rate at that time) ends the stretch, so the orange line and area stop there and start again at the
    /// next reading that has it, instead of running straight across readings nobody split. Others' band is
    /// the collector's own fourth column when the reading has one; only an older three-column reading is
    /// worked out from the total.
    static func samples(
        of points: [UsagePanelState.Window.Point],
        in range: ClosedRange<Date>,
        local: Bool) -> ChartSamples
    {
        var result = ChartSamples()
        var run = 0
        var previousHadMine: Bool?
        for point in points {
            let date = Date(timeIntervalSince1970: point.time)
            guard range.contains(date) else { continue }
            result.used.append(Sample(date: date, value: point.used, series: "used"))
            // A new stretch whenever this Mac's part appears or disappears.
            let hasMine = point.mine != nil
            if let previousHadMine, previousHadMine != hasMine {
                run += 1
            }
            previousHadMine = hasMine
            if let value = point.mine {
                result.mine.append(Sample(date: date, value: value, series: "you-\(run)"))
            }
            guard local else { continue }
            let series = "others-\(run)"
            if let mine = point.mine {
                // Others sit right above the orange: the collector's own number, else what is neither this
                // Mac's nor unsplit.
                let top = point.others.map { mine + max(0, $0) } ?? max(mine, point.used - (point.unknown ?? 0))
                result.others.append(Band(date: date, low: mine, high: max(mine, min(point.used, top)), series: series))
            } else if let others = point.others, others > 0 {
                // No rate, so no orange: the proven part of others hangs below the reading.
                result.others.append(Band(
                    date: date, low: max(0, point.used - others), high: point.used, series: series))
            } else {
                result.others.append(Band(date: date, low: point.used, high: point.used, series: series))
            }
        }
        if !result.drawsOthers {
            result.others = []
        }
        return result
    }

    private func samples(in range: ClosedRange<Date>) -> ChartSamples {
        Self.samples(of: self.window.points, in: range, local: self.sources.local != nil)
    }

    public var body: some View {
        let segments = self.sources.hasParts
            ? UsageSegment.build(for: self.window, kind: self.kind, sources: self.sources).filter { $0.kind != .all }
            : []
        let pace = UsageLimitPace.make(window: self.window, kind: self.kind, now: self.now)
        let forecast = self.window.liveForecast(now: self.now)
        // The row's verdict: the panel's forecast says the same thing in more words, in the same colour.
        let verdict = UsageLimitVerdict(window: self.window, now: self.now)
        let title = self.title ?? self.kind.longTitle
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(title: "\(self.account.displayName) · \(title)", subtitle: self.subtitle)
            if let sparse = self.sparseReadings {
                Text(sparse)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let range = self.range {
                let samples = self.samples(in: range)
                self.chart(range: range, samples: samples)
                if let first = self.window.points.first,
                   first.time > range.lowerBound.timeIntervalSince1970 + 0.15 * self.kind.span
                {
                    UsageNote(text: self.sources == .split
                        ? "No readings of this limit before \(self.stamp(first.time)): "
                        + "the account was not being checked then."
                        : "No readings of this limit before \(self.stamp(first.time)).")
                }
                UsageFlowLayout(spacing: 12) {
                    if self.sources == .split {
                        UsageChip(color: .primary, text: "Used, all sources", line: true)
                        UsageChip(color: UsagePalette.you, text: "You")
                    } else {
                        UsageChip(color: .primary, text: "Used", line: true)
                        if self.sources.local != nil, !samples.mine.isEmpty {
                            UsageChip(color: UsagePalette.you, text: "You")
                        }
                        if samples.drawsOthers {
                            UsageChip(color: UsagePalette.others, text: "Others")
                        }
                    }
                    UsageChip(color: .secondary, text: "Even pace", dashed: true)
                    if forecast != nil {
                        UsageChip(color: Color.primary.opacity(0.45), text: "Forecast and likely range", dashed: true)
                    }
                    if forecast?.hitAt != nil {
                        UsageChip(color: UsagePalette.paceBad.opacity(0.5), text: "Limit used up")
                    }
                }
            }
            if !segments.isEmpty {
                Divider()
                UsageSectionLabel(text: "Where it went")
                VStack(spacing: 4) {
                    ForEach(segments) { segment in
                        self.row(segment)
                    }
                }
                if let local = self.sources.local {
                    if let split = self.window.split {
                        UsageNote(text: local.note(
                            for: split, usd: self.spentInWindow, used: self.used, rated: self.hasRate))
                    }
                } else if self.kind != .week, segments.contains(where: { $0.kind == .others }) {
                    UsageNote(text: "The server does not split this limit by source, so everything "
                        + "outside this Mac is shown as one part.")
                }
            }
            if let pace {
                Divider()
                UsageSectionLabel(text: "Pace")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The same "T" as on the row's bar, in the same colour.
                    UsageTimeMarkGlyph(color: pace.color)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(self.paceExplanation(pace))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let resetsAt = self.window.resetsAt, forecast != nil || verdict == .outNow {
                Divider()
                UsageSectionLabel(text: "Forecast")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(verdict.color)
                        .frame(width: 2, height: 10)
                    Text(self.forecastText(forecast, verdict: verdict, resetsAt: resetsAt))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let forecast, !self.isUsedUp {
                    UsageNote(text: self.forecastBasis(forecast))
                }
            }
            if let sessionsLeft {
                Divider()
                UsageSectionLabel(text: "5-hour sessions left")
                Text(sessionsLeft.explanation)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                UsageNote(text: sessionsLeft.basisNote)
            } else if let sessionsNote {
                Divider()
                UsageSectionLabel(text: "5-hour sessions left")
                Text(sessionsNote)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.sources != .split, self.kind == .week, !(self.account.weeks ?? []).isEmpty {
                // Claude shows the weeks in Spend's account panel; a provider page has no such panel.
                Divider()
                UsageWeekWindows(account: self.account, now: self.now, sources: self.sources)
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(self.facts, id: \.self) { fact in
                    UsageNote(text: fact)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    /// This Mac's dollars in this window, as "Where it went" shows them next to "You"; nil after a reset,
    /// when the last dollars belong to the window before.
    private var spentInWindow: Double? {
        self.window.rolled == true ? nil : self.window.usd?.total
    }

    /// Whether the account has a dollars-per-percent rate for this limit; nil when the summary has no rates.
    private var hasRate: Bool? {
        guard let rates = self.account.rates else { return nil }
        return (rates[self.kind.rawValue]?.usdPer100 ?? 0) > 0
    }

    /// With a single source, fewer than two readings in the window say more as a sentence than as a chart
    /// of one dot. Claude keeps its chart.
    private var sparseReadings: String? {
        guard self.sources != .split else { return nil }
        guard let range = self.range else {
            return self.window.rolled == true
                ? "No reading since this window reset."
                : "No reset time for this window yet, so there is nothing to chart."
        }
        let readings = self.window.points.filter { range.contains(Date(timeIntervalSince1970: $0.time)) }
        switch readings.count {
        case 0:
            return "No readings in this window yet."
        case 1:
            let only = readings[0]
            return "One reading in this window so far (\(UsageFormat.percent(only.used)) at \(self.stamp(only.time))): "
                + "the chart starts with the next one."
        default:
            return nil
        }
    }

    private func stamp(_ time: Double) -> String {
        self.kind == .fiveHour
            ? UsageFormat.clock(Date(timeIntervalSince1970: time))
            : UsageFormat.weekdayTime(time)
    }

    /// Key for planning: when the limit runs out and how long to wait for the reset after that. Worded after
    /// the row's verdict, so "May run out" on the row is never "Lasts until the reset" here.
    /// The reading itself says 100 %: measured, not forecast.
    private var isUsedUp: Bool {
        (self.window.pct ?? 0) >= 100
    }

    private func forecastText(
        _ forecast: UsagePanelState.Forecast?,
        verdict: UsageLimitVerdict,
        resetsAt: Double) -> String
    {
        let back = "It comes back at the reset, \(self.stamp(resetsAt))."
        if verdict == .outNow {
            if self.isUsedUp {
                return "Used up: the last reading shows 100%. " + back
            }
            // Out by the forecast only: its run-out time has passed, the reading has not caught up yet.
            let when = forecast?.hitAt.map { " around \(self.stamp($0))" } ?? ""
            return "Likely used up: the forecast had it running out\(when), and that time has passed; "
                + "the last reading shows \(UsageFormat.percent(self.used)). " + back
        }
        guard let forecast else { return back }
        if let hit = forecast.hitAt, hit < resetsAt {
            let gap = UsageFormat.duration(max(0, resetsAt - hit))
            var text = "Likely runs out around \(self.stamp(hit)), \(gap) before the reset: "
                + "about \(gap) without this limit."
            if let early = forecast.hitEarly, hit - early > 10 * 60 {
                text += " If you keep pushing, as early as \(self.stamp(early)) "
                    + "(\(UsageFormat.duration(max(0, resetsAt - early))) without it)."
            }
            if forecast.hitLate == nil {
                text += " It still lasts if you slow down."
            }
            return text
        }
        let end = UsageFormat.percent(forecast.endPct ?? self.used)
        let low = UsageFormat.percent(forecast.endLo ?? self.used)
        let high = UsageFormat.percent(forecast.endHi ?? self.used)
        if let early = forecast.hitEarly, early < resetsAt {
            return "May run out: likely lasts until the reset, ending near \(end), but if you push harder than "
                + "usual it could run out around \(self.stamp(early)), "
                + "\(UsageFormat.duration(max(0, resetsAt - early))) early."
        }
        if verdict == .mayRunOut {
            return "May run out: likely ends near \(end), but the likely range (\(low)–\(high)) reaches the limit "
                + "before the reset."
        }
        return "Lasts until the reset. Expected to end near \(end) (likely \(low)–\(high))."
    }

    private func forecastBasis(_ forecast: UsagePanelState.Forecast) -> String {
        let recent = self.kind == .fiveHour ? "last hour" : "last 2 days"
        guard let checks = forecast.checks, checks > 0 else {
            return "Rough forecast from your pace in this window and in the \(recent): too few past windows to check it."
        }
        // With too little history of its own, an account's spread comes from all accounts together.
        let whose = forecast.bandSource == "pooled" ? "past windows of all your accounts" : "your past windows"
        return "From your pace in this window and in the \(recent), corrected by how \(whose) "
            + "went on from the same point (\(Int(checks)) checks). The shaded range covers 6 cases out of 10."
    }

    private struct Fan: Identifiable {
        let date: Date
        let low: Double
        let mid: Double
        let high: Double

        var id: Double {
            self.date.timeIntervalSince1970
        }
    }

    /// Forecast fan from the current minute to the reset: lower bound, middle, upper bound.
    private func fan(range: ClosedRange<Date>) -> [Fan] {
        guard let forecast = self.window.liveForecast(now: self.now),
              let at = forecast.at,
              let pct = forecast.pct
        else { return [] }
        let reset = range.upperBound.timeIntervalSince1970
        guard reset > at else { return [] }
        func rate(hit: Double?, end: Double?) -> Double {
            if let hit, hit > at {
                return (100 - pct) / (hit - at)
            }
            return ((end ?? pct) - pct) / (reset - at)
        }
        let low = rate(hit: forecast.hitLate, end: forecast.endLo)
        let mid = rate(hit: forecast.hitAt, end: forecast.endPct)
        let high = rate(hit: forecast.hitEarly, end: forecast.endHi)
        var stamps = (0...24).map { at + (reset - at) * Double($0) / 24 }
        for hit in [forecast.hitEarly, forecast.hitAt, forecast.hitLate] {
            if let hit, hit > at + 1, hit < reset - 1 {
                stamps.append(hit)
            }
        }
        return stamps.sorted().map { stamp in
            let delta = stamp - at
            return Fan(
                date: Date(timeIntervalSince1970: stamp),
                low: min(100, pct + low * delta),
                mid: min(100, pct + mid * delta),
                high: min(100, pct + high * delta))
        }
    }

    @ChartContentBuilder
    private func forecastMarks(_ fan: [Fan], range: ClosedRange<Date>) -> some ChartContent {
        if let hit = self.window.liveForecast(now: self.now)?.hitAt {
            RectangleMark(
                xStart: .value("Out", Date(timeIntervalSince1970: hit)),
                xEnd: .value("Reset", range.upperBound),
                yStart: .value("Bottom", 0.0),
                yEnd: .value("Top", 100.0))
                .foregroundStyle(UsagePalette.paceBad.opacity(0.16))
        }
        ForEach(fan) { point in
            AreaMark(
                x: .value("Time", point.date),
                yStart: .value("Low", point.low),
                yEnd: .value("High", point.high),
                series: .value("Series", "range"))
                .foregroundStyle(Color.primary.opacity(0.10))
        }
        ForEach(fan) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Percent", point.mid),
                series: .value("Series", "forecast"))
                .foregroundStyle(Color.primary.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    /// The reserve or deficit only: when the limit runs out is the Forecast section's (or, without a
    /// forecast, nobody's: the row then says "No forecast" too).
    private func paceExplanation(_ pace: UsageLimitPace) -> String {
        if pace.isStale {
            // An account that is not being polled: the mark is drawn from its last reading.
            let age = self.window.measuredAt.map { " (\(UsageFormat.age($0, now: self.now)))" } ?? ""
            return "\(pace.headline). Even use would be at \(UsageFormat.percent(pace.expected)) by now; "
                + "the last reading\(age) was \(UsageFormat.percent(self.used))."
        }
        return "\(pace.headline). Even use would be at \(UsageFormat.percent(pace.expected)) by now; you are at "
            + "\(UsageFormat.percent(self.used))."
    }

    private var facts: [String] {
        if self.sources != .split {
            return self.singleSourceFacts
        }
        var facts: [String] = []
        if let usd = self.window.usd {
            let total = self.kind == .fable ? (usd.fable ?? 0) : usd.total
            var line = "Your spend in this window: \(UsageFormat.usd(total)) at API prices"
            if self.kind != .fable, total >= 0.5 {
                var parts: [String] = []
                if (usd.opus ?? 0) >= 0.5 {
                    parts.append("Opus \(UsageFormat.usd(usd.opus ?? 0))")
                }
                if (usd.fable ?? 0) >= 0.5 {
                    parts.append("Fable \(UsageFormat.usd(usd.fable ?? 0))")
                }
                if (usd.other ?? 0) >= 0.5 {
                    parts.append("other \(UsageFormat.usd(usd.other ?? 0))")
                }
                if !parts.isEmpty {
                    line += " (\(parts.joined(separator: " · ")))"
                }
            }
            facts.append(line + ".")
        }
        if let rate = self.account.rates?[self.kind.rawValue], let capacity = rate.usdPer100 {
            let unit = self.kind == .fable ? "of Fable" : "in Opus-equivalent dollars"
            let source = rate.source == "derived" ? ", derived from the weekly limit" : ""
            facts.append("100% of this limit ≈ \(UsageFormat.usd(capacity)) \(unit)\(source).")
        } else if self.window.mine == nil, self.used > 0 {
            facts.append("Your share appears after a few more readings of this limit.")
        }
        if let measuredAt = self.window.measuredAt {
            facts.append("Reading from \(UsageFormat.stamp(measuredAt, now: self.now)) "
                + "(\(UsageFormat.age(measuredAt, now: self.now))).")
        }
        return facts
    }

    /// A provider page: dollars at API prices are an estimate of the use, not a bill.
    private var singleSourceFacts: [String] {
        var facts: [String] = []
        // After a reset the last reading and its dollars belong to the previous window.
        let rolled = self.window.rolled == true
        let spent = rolled ? nil : self.window.usd.map(\.total).flatMap { $0 >= 0.005 ? $0 : nil }
        if let spent {
            facts.append("Your use in this window ≈ \(UsageFormat.usdFine(spent)) at API prices.")
        }
        if let capacity = self.account.rates?[self.kind.rawValue]?.usdPer100, capacity > 0 {
            // The rate comes from past windows. When this window's own dollars per percent differ a lot, both
            // are named, so "$12 at 89%" next to "100% ≈ $9.3" is not left unexplained.
            let own = spent.flatMap { self.used >= 10 ? $0 / self.used * 100 : nil }
            if let own, abs(own - capacity) / capacity > 0.3 {
                facts.append("100% of this limit ≈ \(UsageFormat.usd(capacity)) at API prices, measured on past "
                    + "windows; this window works out to ≈ \(UsageFormat.usd(own)).")
            } else {
                facts.append("100% of this limit ≈ \(UsageFormat.usd(capacity)) at API prices.")
            }
        }
        if let measuredAt = self.window.measuredAt {
            let when = "\(UsageFormat.stamp(measuredAt, now: self.now)) (\(UsageFormat.age(measuredAt, now: self.now)))"
            facts.append(rolled ? "Last reading \(when), before this window began." : "Reading from \(when).")
        }
        return facts
    }

    private func row(_ segment: UsageSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if segment.isHatched {
                UsageHatchSwatch(size: CGSize(width: 8, height: 8))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(segment.color)
                    .frame(width: 8, height: 8)
            }
            Text(segment.longLabel)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let usd = segment.usd, usd >= 0.5 {
                Text(UsageFormat.usd(usd))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(segment.kind == .unknown && segment.local == nil ? "—" : segment.longValueText)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private func chart(range: ClosedRange<Date>, samples: ChartSamples) -> some View {
        let pace = [
            Sample(date: range.lowerBound, value: 0, series: "pace"),
            Sample(date: range.upperBound, value: 100, series: "pace"),
        ]
        let clock = self.kind == .fiveHour
        let fan = self.fan(range: range)
        return Chart {
            self.forecastMarks(fan, range: range)
            ForEach(pace) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Percent", sample.value),
                    series: .value("Series", sample.series))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(samples.others) { band in
                AreaMark(
                    x: .value("Time", band.date),
                    yStart: .value("Low", band.low),
                    yEnd: .value("High", band.high),
                    series: .value("Series", band.series))
                    .foregroundStyle(UsagePalette.others.opacity(0.42))
            }
            ForEach(samples.mine) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Percent", sample.value),
                    series: .value("Series", "area-" + sample.series))
                    .foregroundStyle(UsagePalette.you.opacity(0.30))
            }
            ForEach(samples.mine) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Percent", sample.value),
                    series: .value("Series", sample.series))
                    .foregroundStyle(UsagePalette.you)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(samples.used) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Percent", sample.value),
                    series: .value("Series", sample.series))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let last = samples.used.last {
                PointMark(x: .value("Time", last.date), y: .value("Percent", last.value))
                    .foregroundStyle(Color.primary)
                    .symbolSize(26)
            }
            if range.contains(self.now) {
                RuleMark(x: .value("Now", self.now))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(UsageFormat.percent(percent)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: clock ? 5 : 7)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(clock ? UsageFormat.clock(date) : UsageFormat.weekday(date))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 140)
        .padding(.trailing, 22)
    }
}
