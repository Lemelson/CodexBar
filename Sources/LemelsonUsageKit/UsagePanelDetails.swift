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
    /// Replaces the long window title ("5-hour session limit"), e.g. "5-hour limit" for Antigravity.
    let title: String?
    /// `.single` (Antigravity): no "You" line or "Where it went", dollars read as "your use", and a plain
    /// sentence instead of a chart with fewer than two readings.
    let sources: UsageLimitSources

    public init(
        account: UsagePanelState.Account,
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        now: Date,
        width: CGFloat,
        sessionsLeft: UsageSessionsLeft? = nil,
        title: String? = nil,
        sources: UsageLimitSources = .split)
    {
        self.account = account
        self.kind = kind
        self.window = window
        self.now = now
        self.width = width
        self.sessionsLeft = sessionsLeft
        self.title = title
        self.sources = sources
    }

    private struct Sample: Identifiable {
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

    private func samples(in range: ClosedRange<Date>) -> (used: [Sample], mine: [Sample]) {
        var used: [Sample] = []
        var mine: [Sample] = []
        for point in self.window.points {
            let date = Date(timeIntervalSince1970: point.time)
            guard range.contains(date) else { continue }
            used.append(Sample(date: date, value: point.used, series: "used"))
            if let value = point.mine {
                mine.append(Sample(date: date, value: value, series: "you"))
            }
        }
        return (used, mine)
    }

    public var body: some View {
        let segments = self.sources == .split ? UsageSegment.build(for: self.window, kind: self.kind) : []
        let pace = UsagePace.make(window: self.window, kind: self.kind, now: self.now)
        let forecast = self.window.liveForecast(now: self.now)
        let title = self.title ?? self.kind.longTitle
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(title: "\(self.account.displayName) · \(title)", subtitle: self.subtitle)
            if let sparse = self.sparseReadings {
                Text(sparse)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let range = self.range {
                self.chart(range: range)
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
                        UsageChip(color: .primary, text: "Used, all sources", dashed: true)
                        UsageChip(color: UsagePalette.you, text: "You")
                    } else {
                        UsageChip(color: .primary, text: "Used", dashed: true)
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
                if self.kind != .week, segments.contains(where: { $0.kind == .others }) {
                    UsageNote(text: "The server does not split this limit by source, so everything "
                        + "outside this Mac is shown as one part.")
                }
            }
            if let pace {
                Divider()
                UsageSectionLabel(text: "Pace")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(pace.color)
                        .frame(width: 2, height: 10)
                    Text(self.paceExplanation(pace, hasForecast: forecast != nil))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let forecast, let resetsAt = self.window.resetsAt {
                Divider()
                UsageSectionLabel(text: "Forecast")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(forecast.hitAt == nil ? UsagePalette.paceGood : UsagePalette.paceBad)
                        .frame(width: 2, height: 10)
                    Text(self.forecastText(forecast, resetsAt: resetsAt))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                UsageNote(text: self.forecastBasis(forecast))
            }
            if let sessionsLeft {
                Divider()
                UsageSectionLabel(text: "5-hour sessions left")
                Text(sessionsLeft.explanation)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                UsageNote(text: sessionsLeft.basisNote)
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

    /// With a single source, fewer than two readings in the window say more as a sentence than as a chart
    /// of one dot. Claude keeps its chart.
    private var sparseReadings: String? {
        guard self.sources == .single else { return nil }
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

    /// Key for planning: when the limit runs out and how long to wait for the reset after that.
    private func forecastText(_ forecast: UsagePanelState.Forecast, resetsAt: Double) -> String {
        if let hit = forecast.hitAt {
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
        if let early = forecast.hitEarly {
            return "Likely lasts until the reset, ending near \(end). If you push harder than usual it could "
                + "run out around \(self.stamp(early)), \(UsageFormat.duration(max(0, resetsAt - early))) early."
        }
        let low = UsageFormat.percent(forecast.endLo ?? self.used)
        let high = UsageFormat.percent(forecast.endHi ?? self.used)
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

    private func paceExplanation(_ pace: UsagePace, hasForecast: Bool) -> String {
        if pace.isStale {
            // An account that is not being polled: the mark is drawn from its last reading.
            let age = self.window.measuredAt.map { " (\(UsageFormat.age($0, now: self.now)))" } ?? ""
            return "\(pace.headline). Even use would be at \(UsageFormat.percent(pace.expected)) by now; "
                + "the last reading\(age) was \(UsageFormat.percent(self.used))."
        }
        let even = "Even use would be at \(UsageFormat.percent(pace.expected)) by now; you are at "
            + "\(UsageFormat.percent(self.used))."
        if hasForecast {
            return "\(pace.headline). \(even)"
        }
        if pace.lastsToReset {
            return "\(pace.headline). \(even) At this rate the limit lasts until it resets."
        }
        return "\(pace.headline). \(even) At this rate it \(pace.tail)."
    }

    private var facts: [String] {
        if self.sources == .single {
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

    /// Antigravity: dollars at Gemini API prices are an estimate of the use, not a bill.
    private var singleSourceFacts: [String] {
        var facts: [String] = []
        // After a reset the last reading and its dollars belong to the previous window.
        let rolled = self.window.rolled == true
        if !rolled, let usd = self.window.usd, usd.total >= 0.005 {
            facts.append("Your use in this window ≈ \(UsageFormat.usdFine(usd.total)) at API prices.")
        }
        if let capacity = self.account.rates?[self.kind.rawValue]?.usdPer100, capacity > 0 {
            facts.append("100% of this limit ≈ \(UsageFormat.usd(capacity)) at API prices.")
        }
        if let measuredAt = self.window.measuredAt {
            let when = "\(UsageFormat.stamp(measuredAt, now: self.now)) (\(UsageFormat.age(measuredAt, now: self.now)))"
            facts.append(rolled ? "Last reading \(when), before this window began." : "Reading from \(when).")
        }
        return facts
    }

    private func row(_ segment: UsageSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(segment.color)
                .frame(width: 8, height: 8)
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
            Text(segment.kind == .unknown ? "—" : UsageFormat.percent(segment.value))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private func chart(range: ClosedRange<Date>) -> some View {
        let samples = self.samples(in: range)
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
            ForEach(samples.mine) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Percent", sample.value))
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
