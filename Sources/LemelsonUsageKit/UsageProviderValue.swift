import SwiftUI

// MARK: - What a provider's plan is worth, computed once

/// The numbers of a provider page's value row and its detail panel. Reads `value` in the shape of
/// `usage/ANTIGRAVITY-STATE.md` (Codex's block has the same shape) when the collector writes it, and falls back
/// to the older fields (`weekOpusUsd`, `monthOpusUsd`, the account's plan price) when it does not.
struct UsageProviderWorth {
    enum Content {
        /// Too little data: the collector's reason instead of numbers.
        case reason(String)
        case numbers(Numbers)
    }

    struct Numbers {
        let planName: String?
        /// Nil: the plan price is not set, so no "You pay" and no ×.
        let price: Double?
        let month: Double
        let times: Double?
        let models: [UsageValueBlock.Model]
    }

    let content: Content
    let footnote: String
    /// The short value of the page's "Plan worth" row: "≈$289/mo · ×15", or "measuring, 1 of 4".
    let headline: String
    /// The plan name for the card ("Plus", "Ultra 5x").
    let planName: String?

    private static let weeksPerMonth = 30.44 / 7

    /// Nil when there is nothing to say: no rate yet and no reason from the collector. `spend` is the page's
    /// own spend (built once per page): model names and colors follow its 30-day layer.
    init?(block: UsageProviderBlock, spec: UsageProviderSpec, spend: UsageProviderSpend) {
        guard block.error == nil else { return nil }
        let worth = block.worth
        self.footnote = Self.footnote(block, spec: spec)
        self.planName = spec.shortPlan(block.account.planName ?? worth?.planName)
        if let worth, worth.confident == false {
            self.content = .reason(worth.reason ?? "The collector gave no reason.")
            self.headline = Self.measuring(block)
            return
        }
        let week = worth?.weekUsd ?? block.capacity(.week)
        guard let month = worth?.monthUsd ?? block.account.value?.monthOpusUsd ?? week.map({ $0 * Self.weeksPerMonth }),
              month > 0
        else { return nil }
        // A collector that writes the new shape owns the price: its null means "not set".
        let rawPrice = worth != nil ? worth?.planPriceUsd : block.account.planPriceUsd
        let price = rawPrice.flatMap { $0 > 0 ? $0 : nil }
        func times(_ usd: Double, given: Double?) -> Double? {
            guard let price else { return nil }
            return given ?? usd / price
        }

        // Model names and colors follow the spend chart of the same page (its 30-day layer).
        let spend30 = spend[.d30]
        var colors: [String: Color] = [:]
        for row in spend30.rows {
            colors[row.id] = row.color.color
        }
        var ceilings: [(label: String, color: Color, usd: Double, times: Double?)] = []
        for (index, model) in (worth?.byModel ?? []).enumerated() {
            guard let usd = model.monthUsd, usd > 0 else { continue }
            let id = model.model ?? "model-\(index)"
            ceilings.append((
                spend.labels[id] ?? id,
                colors[id] ?? UsagePalette.others,
                usd,
                times(usd, given: model.timesPrice)))
        }
        let realUse = spend30.rows.map { ($0.use.usd, $0.color.color) }
        let realUsd = spend30.whole.usd
        // Real use is drawn against the same scale as the ceilings, so its bar shows how much of the limit
        // this Mac actually used.
        let scale = max(1, month, realUsd, ceilings.map(\.usd).max() ?? 0)
        var models = ceilings.map {
            UsageValueBlock.Model(label: "\($0.label) only", parts: [($0.usd, $0.color)], scale: scale,
                                  times: $0.times, usd: $0.usd)
        }
        if !models.isEmpty || realUsd > 0 {
            models.append(UsageValueBlock.Model(
                label: "Real use, 30 days", parts: realUse, scale: scale, times: price.map { realUsd / $0 },
                usd: realUsd))
        }
        let multiple = times(month, given: worth?.timesPrice)
        self.content = .numbers(Numbers(
            planName: self.planName,
            price: price,
            month: month,
            times: multiple,
            models: models))
        self.headline = "≈\(UsageFormat.usd(month))/mo" + (multiple.map { " · \(UsageFormat.times($0))" } ?? "")
    }

    /// "measuring, 1 of 4": how many measurements the estimate stands on and how many it needs.
    static func measuring(_ block: UsageProviderBlock) -> String {
        func count(_ value: Double?) -> Int? {
            value.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil }
        }
        let seen = count(block.worth?.pairs ?? block.valuePairs)
        let needed = count(block.calibration?.valuePairsNeeded).flatMap { $0 > 0 ? $0 : nil }
        if let seen, let needed, seen < needed {
            return "measuring, \(seen) of \(needed)"
        }
        return "measuring"
    }

    /// How the dollars of a full limit were measured, in one or two sentences.
    private static func footnote(_ block: UsageProviderBlock, spec: UsageProviderSpec) -> String {
        let pairs = block.worth?.pairs ?? block.weekRate?.pairsUsed ?? block.valuePairs
            ?? block.account.rates?["7d"]?.pairs
        var text = if let method = block.weekRate?.method, !method.isEmpty {
            method.hasSuffix(".") ? method : method + "."
        } else if let pairs, pairs > 0 {
            "Measured from \(Int(pairs)) pairs of quota readings and the dollars spent between them."
        } else {
            "Measured from pairs of quota readings and the dollars spent between them."
        }
        // How many stretches the rate does not stand on, and why: "polluted" (moved too much) and "low" (moved
        // much less than the others agree on).
        let dropped = block.weekRate?.pairsDropped.map { Int($0.rounded()) } ?? 0
        let low = block.weekRate?.pairsLow.map { Int($0.rounded()) } ?? 0
        if dropped >= 1, low >= 1 {
            text += " Left out: \(dropped) that moved the limit more than this Mac's use explains "
                + "(\(spec.elsewhere)), \(low) that moved it much less than the others."
        } else if dropped >= 1 {
            text += " \(dropped) left out: the limit moved more than this Mac's use explains (\(spec.elsewhere))."
        } else if low >= 1 {
            text += " \(low) left out: the limit moved much less than the others agree on."
        }
        return text
    }
}

// MARK: - The detail panel

/// The hover panel of a provider page's "Plan worth" row: one `UsageValueBlock`, the same view Claude's Value
/// card draws per account, then the plan's worth by month with Claude Value's month chart
/// (`UsageDriftMonthChartView`), one bar per calendar month in the provider's API dollars.
struct UsageProviderValueView: View {
    let worth: UsageProviderWorth
    let block: UsageProviderBlock
    let spec: UsageProviderSpec
    let width: CGFloat
    /// The summary's time: the current month counts its days up to here.
    let until: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(
                title: "\(self.spec.name) · What the plan is worth",
                subtitle: "A month of full weekly limits, bought through the API at list prices.")
            switch self.worth.content {
            case let .reason(reason):
                UsageValueBlock(
                    color: self.spec.tint,
                    name: self.spec.name,
                    plan: self.worth.planName,
                    times: nil,
                    content: .waiting("No estimate yet: too few readings of the weekly limit.", reason: reason))
            case let .numbers(numbers):
                UsageValueBlock(
                    color: self.spec.tint,
                    name: self.spec.name,
                    plan: numbers.planName,
                    times: numbers.times,
                    content: .numbers(UsageValueBlock.Numbers(
                        paid: numbers.price,
                        got: numbers.month,
                        scale: max(1, numbers.month, numbers.price ?? 0),
                        priceNote: numbers.price == nil ? "Plan price not set, so there is no ×." : nil,
                        models: numbers.models)))
            }
            UsageNote(text: self.worth.footnote)
            if let series = self.monthSeries {
                Divider()
                UsageSectionLabel(text: "Is the limit changing? · by month")
                UsageNote(text: "A bar is a month of full weekly limits at \(self.spec.prices): its average week "
                    + "× 4.35. Faded: under 2 weeks of it measured.")
                UsageDriftMonthChartView(series: [series])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    /// The weekly limit's measured worth, week by week (`drift`), spread over calendar months; nil when no
    /// month has enough measured days.
    private var monthSeries: UsageDriftMonthSeries? {
        let points = (self.block.account.drift ?? []).compactMap { item -> UsageDriftPoint? in
            guard item.usdPer100 > 0 else { return nil }
            return UsageDriftPoint(
                account: self.spec.name,
                color: self.spec.tint,
                date: Date(timeIntervalSince1970: item.weekEnd),
                usd: item.usdPer100)
        }
        let months = UsageDriftMonths.months(of: points, until: self.until)
        guard !months.isEmpty else { return nil }
        return UsageDriftMonthSeries(id: self.spec.key.rawValue, name: self.spec.name, color: self.spec.tint, months: months)
    }
}
