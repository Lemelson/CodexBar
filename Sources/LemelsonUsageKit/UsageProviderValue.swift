import SwiftUI

// MARK: - What a provider's plan is worth, computed once

/// The numbers of a provider page's Value section. Reads `value` in the shape of `usage/ANTIGRAVITY-STATE.md`
/// (Codex's block has the same shape) when the collector writes it, and falls back to the older fields
/// (`weekOpusUsd`, `monthOpusUsd`, the account's plan price) when it does not.
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

    private static let weeksPerMonth = 30.44 / 7

    /// Nil when there is nothing to say: no rate yet and no reason from the collector.
    init?(block: UsageProviderBlock, spec: UsageProviderSpec, now: Date) {
        guard block.error == nil else { return nil }
        let worth = block.worth
        self.footnote = Self.footnote(block, spec: spec)
        if let worth, worth.confident == false {
            self.content = .reason(worth.reason ?? "The collector gave no reason.")
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

        // Model colors follow the spend chart of the same page.
        let spend = UsageProviderSpend(block: block, spec: spec, now: now)[.d30]
        var colors: [String: Color] = [:]
        for row in spend.rows {
            colors[row.id] = row.color.color
        }
        let ids = (worth?.byModel ?? []).compactMap(\.model)
        let labels = spec.models.labels(for: ids)
        var ceilings: [(label: String, color: Color, usd: Double, times: Double?)] = []
        for (index, model) in (worth?.byModel ?? []).enumerated() {
            guard let usd = model.monthUsd, usd > 0 else { continue }
            let id = model.model ?? "model-\(index)"
            ceilings.append((
                model.label ?? labels[id] ?? id,
                colors[id] ?? UsagePalette.others,
                usd,
                times(usd, given: model.timesPrice)))
        }
        let realUse = spend.rows.map { ($0.use.usd, $0.color.color) }
        let realUsd = spend.whole.usd
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
        self.content = .numbers(Numbers(
            planName: worth?.planName ?? block.account.planName,
            price: price,
            month: month,
            times: times(month, given: worth?.timesPrice),
            models: models))
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

// MARK: - The section

/// "What the plan is worth" on a provider page: one `UsageValueBlock`, the same view Claude's Value card
/// draws per account. Monthly only: one figure is enough on a page that is not about value.
public struct UsageProviderValueView: View {
    let block: UsageProviderBlock
    let spec: UsageProviderSpec
    let width: CGFloat
    let now: Date

    public init(block: UsageProviderBlock, spec: UsageProviderSpec, width: CGFloat, now: Date = Date()) {
        self.block = block
        self.spec = spec
        self.width = width
        self.now = now
    }

    static func hasContent(_ block: UsageProviderBlock, spec: UsageProviderSpec, now: Date) -> Bool {
        UsageProviderWorth(block: block, spec: spec, now: now) != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the plan is worth")
                .font(.system(size: 13, weight: .semibold))
            if let worth = UsageProviderWorth(block: self.block, spec: self.spec, now: self.now) {
                switch worth.content {
                case let .reason(reason):
                    UsageValueBlock(
                        color: UsagePalette.single,
                        name: self.spec.name,
                        plan: self.spec.shortPlan(self.block.account.planName),
                        times: nil,
                        content: .waiting("No estimate yet: too few readings of the weekly limit.", reason: reason))
                case let .numbers(numbers):
                    UsageNote(text: "A month of full weekly limits, bought through the API at list prices.")
                    UsageValueBlock(
                        color: UsagePalette.single,
                        name: self.spec.name,
                        plan: self.spec.shortPlan(numbers.planName),
                        times: numbers.times,
                        content: .numbers(UsageValueBlock.Numbers(
                            paid: numbers.price,
                            got: numbers.month,
                            scale: max(1, numbers.month, numbers.price ?? 0),
                            priceNote: numbers.price == nil ? "Plan price not set, so there is no ×." : nil,
                            models: numbers.models)))
                    UsageNote(text: worth.footnote)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }
}
