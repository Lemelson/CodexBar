import SwiftUI

// MARK: - What the Antigravity plan is worth, computed once

/// The numbers of the Antigravity Value block. Reads `antigravity.value` in the shape of
/// `usage/ANTIGRAVITY-STATE.md` when the collector writes it, and falls back to the older fields
/// (`weekOpusUsd`, `monthOpusUsd`, the account's plan price) when it does not.
struct UsageAntigravityWorth {
    struct ModelRow: Identifiable {
        let id: String
        let label: String
        let color: Color
        let monthUsd: Double
        let times: Double?
    }

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
        let models: [ModelRow]
        /// This Mac's spend over the last 30 days, by model color.
        let realUse: [(Double, Color)]
        let realUseUsd: Double
    }

    let content: Content
    let footnote: String

    private static let weeksPerMonth = 30.44 / 7

    /// Nil when there is nothing to say: no rate yet and no reason from the collector.
    init?(block: UsageAntigravityBlock, now: Date) {
        guard block.error == nil else { return nil }
        let worth = block.worth
        self.footnote = Self.footnote(block)
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
        let spend = UsageAntigravitySpend(block: block, now: now)[.d30]
        var colors: [String: Color] = [:]
        for row in spend.rows {
            colors[row.id] = row.color.color
        }
        let ids = (worth?.byModel ?? []).compactMap(\.model)
        let labels = UsageAntigravityModels.labels(for: ids)
        let models: [ModelRow] = (worth?.byModel ?? []).enumerated().compactMap { index, model in
            guard let usd = model.monthUsd, usd > 0 else { return nil }
            let id = model.model ?? "model-\(index)"
            return ModelRow(
                id: id,
                label: model.label ?? labels[id] ?? id,
                color: colors[id] ?? UsagePalette.others,
                monthUsd: usd,
                times: times(usd, given: model.timesPrice))
        }
        self.content = .numbers(Numbers(
            planName: worth?.planName ?? block.account.planName,
            price: price,
            month: month,
            times: times(month, given: worth?.timesPrice),
            models: models,
            realUse: spend.rows.map { ($0.use.usd, $0.color.color) },
            realUseUsd: spend.whole.usd))
    }

    /// How the dollars of a full limit were measured, in one or two sentences.
    private static func footnote(_ block: UsageAntigravityBlock) -> String {
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
                + "(a phone or the Gemini app), \(low) that moved it much less than the others."
        } else if dropped >= 1 {
            text += " \(dropped) left out: the limit moved more than this Mac's use explains "
                + "(a phone or the Gemini app)."
        } else if low >= 1 {
            text += " \(low) left out: the limit moved much less than the others agree on."
        }
        return text
    }
}

// MARK: - The block

/// "What the plan is worth", in the form of the Claude Value card: You pay / You get, the multiple, and the
/// same limit spent on one model. Monthly only: one figure is enough on a page that is not about value.
public struct UsageAntigravityValueView: View {
    let block: UsageAntigravityBlock
    let width: CGFloat
    let now: Date

    public init(block: UsageAntigravityBlock, width: CGFloat, now: Date = Date()) {
        self.block = block
        self.width = width
        self.now = now
    }

    static func hasContent(_ block: UsageAntigravityBlock, now: Date) -> Bool {
        UsageAntigravityWorth(block: block, now: now) != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the plan is worth")
                .font(.system(size: 13, weight: .semibold))
            if let worth = UsageAntigravityWorth(block: self.block, now: self.now) {
                switch worth.content {
                case let .reason(reason):
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No estimate yet: too few readings of the weekly limit.")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        UsageNote(text: reason.hasSuffix(".") ? reason : reason + ".")
                    }
                case let .numbers(numbers):
                    UsageNote(text: "A month of full weekly limits, bought through the API at list prices.")
                    self.numbers(numbers)
                    UsageNote(text: worth.footnote)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }

    private func numbers(_ numbers: UsageAntigravityWorth.Numbers) -> some View {
        let color = UsagePalette.single
        let scale = max(1, numbers.month, numbers.price ?? 0)
        // Real use is drawn against the same scale as the ceilings, so its bar shows how much of the limit
        // this Mac actually used.
        let modelScale = max(1, numbers.month, numbers.realUseUsd, numbers.models.map(\.monthUsd).max() ?? 0)
        return VStack(alignment: .leading, spacing: 5) {
            UsageValueTitleLine(color: color, name: "Antigravity", plan: numbers.planName, times: numbers.times)
            if let price = numbers.price {
                UsageValueBar(label: "You pay", value: price, scale: scale, color: Color.secondary.opacity(0.7),
                              strong: false)
            }
            UsageValueBar(label: "You get", value: numbers.month, scale: scale, color: color, strong: true)
            if numbers.price == nil {
                UsageNote(text: "Plan price not set, so there is no ×.")
            }
            if !numbers.models.isEmpty || numbers.realUseUsd > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    if !numbers.models.isEmpty {
                        UsageValueModelCaption()
                    }
                    ForEach(numbers.models) { model in
                        UsageValueModelRow(
                            label: "\(model.label) only",
                            parts: [(model.monthUsd, model.color)],
                            scale: modelScale,
                            times: model.times,
                            usd: model.monthUsd)
                    }
                    UsageValueModelRow(
                        label: "Real use, 30 days",
                        parts: numbers.realUse,
                        scale: modelScale,
                        times: numbers.price.map { numbers.realUseUsd / $0 },
                        usd: numbers.realUseUsd)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
