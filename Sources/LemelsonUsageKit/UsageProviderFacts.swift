import SwiftUI

// Codex-only facts the Codex page shows inside its card, after the limit rows (`UsageProviderPage(extras:)`).
// The numbers come from CodexBar's own Codex snapshot (the app passes them in); this file only turns them
// into card rows and their hover detail, so the app and the preview draw them the same way.

public enum UsageCodexFacts {
    /// The credits balance and the limit reset credits, in this order; a fact without data is left out.
    ///   - creditsLeft: the credits balance CodexBar shows on its Codex card (`CreditsSnapshot.displayRemaining`).
    ///   - creditsNote: CodexBar's own line under the balance (a monthly credit cap, why the balance is
    ///     unavailable), shown as is.
    ///   - resetCredits: expiry of each available limit reset credit, soonest first (nil: no expiry); nil when
    ///     CodexBar has no reset credit data or hides it.
    @MainActor
    public static func extras(
        creditsLeft: Double?,
        creditsNote: String? = nil,
        resetCredits: [Date?]?,
        now: Date,
        detailWidth: CGFloat = UsageProviderPage.defaultDetailWidth) -> [UsageProviderPage.Extra]
    {
        var extras: [UsageProviderPage.Extra] = []
        if let creditsLeft, creditsLeft.isFinite {
            let note = creditsNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            extras.append(.init(fact: UsageLimitCardFact(
                id: "credits",
                symbol: "creditcard",
                title: "Credits",
                value: "\(self.credits(creditsLeft)) left",
                caption: note?.isEmpty == false ? note : nil)))
        }
        if let resetCredits, !resetCredits.isEmpty {
            let next = resetCredits.compactMap(\.self).min()
            let caption = next.map { "Next one expires in \(UsageFormat.duration($0.timeIntervalSince(now)))" }
                ?? "No expiry date"
            let lines = resetCredits.enumerated().map { index, date in
                UsageLimitCardFactDetail.Line(
                    label: "\(index + 1).",
                    value: date.map {
                        "expires in \(UsageFormat.duration($0.timeIntervalSince(now))) · "
                            + UsageFormat.format($0, "EEE MMM d, HH:mm")
                    } ?? "no expiry date")
            }
            extras.append(.init(
                fact: UsageLimitCardFact(
                    id: "reset-credits",
                    symbol: "arrow.counterclockwise",
                    title: "Limit reset credits",
                    value: "\(resetCredits.count) available",
                    caption: caption),
                detail: {
                    AnyView(UsageLimitCardFactDetail(
                        title: "Limit reset credits",
                        text: "Each one resets a Codex usage limit once. Unused ones expire.",
                        lines: lines,
                        width: detailWidth))
                }))
        }
        return extras
    }

    /// "58,169": whole credits with thousands separators; below 100 one decimal ("12.5").
    static func credits(_ value: Double) -> String {
        guard value >= 100 else { return String(format: value == value.rounded() ? "%.0f" : "%.1f", value) }
        let digits = String(Int(value.rounded(.down)))
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return String(result.reversed())
    }
}

/// The hover detail of a card fact: a title, one sentence, and a short list.
public struct UsageLimitCardFactDetail: View {
    public struct Line: Hashable, Sendable {
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    let title: String
    let text: String
    let lines: [Line]
    let width: CGFloat

    public init(title: String, text: String, lines: [Line], width: CGFloat = UsageProviderPage.defaultDetailWidth) {
        self.title = title
        self.text = text
        self.lines = lines
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(self.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(self.lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(line.value)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }
}
