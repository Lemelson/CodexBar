import AppKit
import SwiftUI

// The prompt cache, for people who never heard the word: a one-line menu row ("Prompt cache   94% reused")
// and the detail panel it opens, with one picture (a bar split into "reused" and "paid in full").

enum UsageCacheColors {
    /// Text the model had already seen: billed at about a tenth.
    static let reused = UsagePalette.paceGood
    /// Text sent as new: billed at the full input price. Red-orange next to the green: the two differ in hue
    /// and in brightness, so they stay apart on a warm screen.
    static let paidInFull = UsagePalette.paceBad
}

// MARK: - Menu row

/// A plain menu item in size and type, for the menu's footer area next to "Status Page": title on the left,
/// the share reused on the right, a submenu chevron. Measured against the native rows on a 2x screenshot:
/// the rows of this menu have no icons, their text starts 16.5 pt from the menu's edge, and the submenu
/// chevron is a label-coloured 13 pt glyph whose right edge sits 21 pt from the edge.
public struct UsageCacheRowView: View {
    let summary: UsageCacheSummary
    let width: CGFloat
    @Environment(\.usageRowHighlighted) private var highlighted

    /// A native item is 24 pt tall; a card row adds 7 pt around its content (6 padding, 1 descender).
    public static let rowHeight: CGFloat = 24
    public static let height: CGFloat = rowHeight - 7
    /// Where the native rows' text starts.
    public static let textInset: CGFloat = 16
    /// From the right edge to the chevron's right edge.
    static let chevronInset: CGFloat = 21

    public init(summary: UsageCacheSummary, width: CGFloat) {
        self.summary = summary
        self.width = width
    }

    public var body: some View {
        let font = Font.system(size: NSFont.menuFont(ofSize: 0).pointSize)
        HStack(spacing: 0) {
            Text("Prompt cache")
                .font(font)
                .foregroundStyle(UsageInk.primary(self.highlighted))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(UsageFormat.percent(self.summary.main.reusedPct)) reused")
                .font(font)
                .monospacedDigit()
                .foregroundStyle(UsageInk.secondary(self.highlighted))
                .lineLimit(1)
                .padding(.trailing, 10)
            Image(systemName: "chevron.forward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UsageInk.primary(self.highlighted))
        }
        .padding(.leading, Self.textInset)
        .padding(.trailing, Self.chevronInset)
        .frame(width: self.width, height: Self.height, alignment: .leading)
        .background {
            // The card's own highlight follows the content (13 pt here); a native row's fills the whole
            // 24 pt row, 5 pt in from the menu's sides. This one covers the card's.
            if self.highlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, 5)
                    .padding(.vertical, -(Self.rowHeight - Self.height) / 2)
            }
        }
    }
}

// MARK: - Detail panel

/// What the cache is, in one picture and two sentences, then the same over time and per account or model.
public struct UsageCachePanelView: View {
    let summary: UsageCacheSummary
    let width: CGFloat

    public init(summary: UsageCacheSummary, width: CGFloat) {
        self.summary = summary
        self.width = width
    }

    public var body: some View {
        let main = self.summary.main
        // One dollars column for both lists, so their bars end at the same place.
        let showsMoney = self.summary.hasMoney || self.summary.parts.contains { $0.savedUsd != nil }
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(
                title: "\(self.summary.productName) · Prompt cache",
                subtitle: main.id == "today" ? "Today" : "Last \(main.title)")
            Text("Every message sends the whole chat again. Text the model saw a moment ago is reused "
                + "at about a tenth of the price; the rest is paid in full.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            UsageCachePicture(span: main)
            if self.summary.spans.count >= 2 {
                Divider()
                UsageSectionLabel(text: "Reused over time")
                VStack(spacing: 4) {
                    ForEach(self.summary.spans) { span in
                        UsageCacheLine(
                            label: span.title,
                            reusedPct: span.reusedPct,
                            savedUsd: span.savedUsd,
                            showsMoney: showsMoney)
                    }
                }
            }
            if !self.summary.parts.isEmpty {
                Divider()
                UsageSectionLabel(text: self.summary.partsTitle)
                VStack(spacing: 4) {
                    ForEach(self.summary.parts) { part in
                        UsageCacheLine(
                            label: part.name,
                            reusedPct: part.reusedPct,
                            savedUsd: part.savedUsd,
                            showsMoney: showsMoney)
                    }
                }
            }
            Divider()
            UsageNote(text: self.note)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    private var note: String {
        var text = "Paid in full: a new chat, the first message after a pause, or a chat whose beginning changed."
        if self.summary.product == .claude {
            text += " Saving text for reuse costs a little extra and counts as paid in full."
        }
        if self.summary.hasMoney {
            text += self.summary.product == .claude ? " Dollars at API prices." : " Dollars at Gemini API prices."
        }
        return text
    }
}

/// The picture: one bar split into reused and paid in full, the two shares under it, and the dollars when
/// the summary has them.
struct UsageCachePicture: View {
    let span: UsageCacheSummary.Span

    var body: some View {
        let reused = self.span.reusedPct
        let paid = max(0, 100 - reused)
        VStack(alignment: .leading, spacing: 6) {
            UsageSplitBar(
                parts: [(reused, UsageCacheColors.reused), (paid, UsageCacheColors.paidInFull)],
                scale: 100,
                height: 12)
            HStack(alignment: .top) {
                self.legend(
                    color: UsageCacheColors.reused,
                    title: "Reused",
                    percent: reused,
                    money: self.span.savedUsd.map { "saved ≈ \(UsageFormat.usd($0))" },
                    alignment: .leading)
                Spacer(minLength: 8)
                self.legend(
                    color: UsageCacheColors.paidInFull,
                    title: "Paid in full",
                    percent: paid,
                    money: self.span.missUsd.map { "cost ≈ \(UsageFormat.usd($0)) extra" },
                    alignment: .trailing)
            }
        }
    }

    private func legend(
        color: Color,
        title: String,
        percent: Double,
        money: String?,
        alignment: HorizontalAlignment) -> some View
    {
        VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11))
                Text(UsageFormat.percent(percent))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            if let money {
                Text(money)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// "7 days   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬   94%   saved $927".
struct UsageCacheLine: View {
    let label: String
    let reusedPct: Double
    let savedUsd: Double?
    let showsMoney: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(self.label)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 76, alignment: .leading)
            UsageSplitBar(
                parts: [(self.reusedPct, UsageCacheColors.reused),
                        (max(0, 100 - self.reusedPct), UsageCacheColors.paidInFull)],
                scale: 100,
                height: 6)
            Text(UsageFormat.percent(self.reusedPct))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            if self.showsMoney {
                Text(self.savedUsd.map { "saved \(UsageFormat.usd($0))" } ?? "")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: 92, alignment: .trailing)
            }
        }
    }
}
