import AppKit
import Foundation
import LemelsonUsageKit

// lemelson: the merged menu bar item shows one number, the API dollars spent over the last 24 hours across every
// subscription on this Mac (`state.json` → `spend24h`, written by `usage/tick.py`), instead of CodexBar's
// "5h 0% $18.96" layout.
//
// Reversible: `defaults write com.steipete.codexbar lemelsonMenuBarSpend stock` brings the stock layout back
// (`defaults delete …` returns to the number). `lemelsonMenuBarSpendCents -bool YES` always shows cents.
// Off under tests, and the stock layout is used whenever the summary is missing or has no 24-hour figure.

/// The last loaded summary, keyed by the file's modification date, so `applyIcon` decodes `state.json` only when
/// the collector rewrote it.
@MainActor
final class LemelsonMenuBarSpendCache {
    static let shared = LemelsonMenuBarSpendCache()

    private var loadedFor: Date?
    private var state: UsagePanelState?

    func current(url: URL = UsagePanelStore.defaultURL) -> UsagePanelState? {
        guard let modified = UsagePanelStore.modificationDate(of: url) else {
            self.invalidate()
            return nil
        }
        if modified != self.loadedFor {
            self.state = UsagePanelStore.load(from: url)
            self.loadedFor = modified
        }
        return self.state
    }

    func invalidate() {
        self.loadedFor = nil
        self.state = nil
    }
}

extension StatusItemController {
    static let lemelsonMenuBarSpendModeKey = "lemelsonMenuBarSpend"
    static let lemelsonMenuBarSpendCentsKey = "lemelsonMenuBarSpendCents"
    /// Older than this, the number is drawn in the secondary color: the collector has not run for a while.
    static let lemelsonMenuBarSpendStaleAfter: TimeInterval = 3600
    static let lemelsonMenuBarSpendTooltipHeader = "Last 24 hours · API prices"

    var lemelsonMenuBarSpendEnabled: Bool {
        guard !SettingsStore.isRunningTests else { return false }
        return UserDefaults.standard.string(forKey: Self.lemelsonMenuBarSpendModeKey)?.lowercased() != "stock"
    }

    /// Call when `state.json` changed or the menus closed: drops the cached summary and redraws the item.
    func lemelsonMenuBarSpendDidChange() {
        LemelsonMenuBarSpendCache.shared.invalidate()
        self.lastAppliedMergedIconRenderSignature = nil
        if self.shouldMergeIcons {
            _ = self.applyIcon(phase: nil)
        } else {
            self.updateIcons()
        }
    }

    /// Draws the 24-hour dollar figure into the merged item. Returns nil when the stock layout should be drawn
    /// (turned off, under tests, no summary or no figure), otherwise whether the button already showed it.
    func lemelsonApplyMenuBarSpend(button: NSStatusBarButton, statusItem: NSStatusItem) -> Bool? {
        guard self.lemelsonMenuBarSpendEnabled,
              let state = LemelsonMenuBarSpendCache.shared.current(),
              let usd = state.rolling24hUsd
        else {
            // back to stock: the stock layout sets no tooltip or custom accessibility title, so drop ours
            if button.toolTip?.hasPrefix(Self.lemelsonMenuBarSpendTooltipHeader) == true {
                button.toolTip = nil
                button.setAccessibilityTitle(nil)
            }
            return nil
        }

        let alwaysCents = UserDefaults.standard.bool(forKey: Self.lemelsonMenuBarSpendCentsKey)
        let partial = state.isRolling24hPartial
        let formatted = Self.lemelsonFormatMenuBarSpend(usd, alwaysCents: alwaysCents)
        let text = partial ? "≥\(formatted)" : formatted
        let stale = Date().timeIntervalSince(state.generatedDate) > Self.lemelsonMenuBarSpendStaleAfter
        let color: NSColor = stale && !button.isHighlighted ? .secondaryLabelColor : .labelColor
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: Self.lemelsonMenuBarSpendFontSize(self.settings.menuBarLayoutSize),
            weight: .regular)
        let title = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let tooltip = self.lemelsonMenuBarSpendTooltip(state: state, alwaysCents: alwaysCents)
        let appName = Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier) ? "CodexBar Debug" : "CodexBar"
        let accessibility = partial
            ? "\(appName), at least \(formatted) spent in the last 24 hours, some data unavailable"
            : "\(appName), \(formatted) spent in the last 24 hours"

        // The stock path must redraw after this one, even if its quota is unchanged.
        self.lastAppliedMergedIconRenderSignature = nil
        let cached = button.image == nil
            && button.attributedTitle.isEqual(to: title)
            && button.toolTip == tooltip
            && button.accessibilityTitle() == accessibility
        if cached { return true }

        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = title
        button.toolTip = tooltip
        button.setAccessibilityTitle(accessibility)
        statusItem.length = Self.lemelsonMenuBarSpendWidth(title: title, gap: self.settings.menuBarLayoutGap)
        return false
    }

    /// "$4.20" under $10 (or always with `alwaysCents`), otherwise whole dollars with grouping: "$182", "$1,240".
    nonisolated static func lemelsonFormatMenuBarSpend(_ usd: Double, alwaysCents: Bool) -> String {
        let value = usd.isFinite && usd > 0 ? usd : 0
        let cents = alwaysCents || value < 10
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = cents ? 2 : 0
        formatter.maximumFractionDigits = cents ? 2 : 0
        formatter.roundingMode = .halfUp
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: cents ? "%.2f" : "%.0f", value)
        return "$" + number
    }

    /// The point size MenuBarLayoutRenderer uses for a single (not stacked) row.
    nonisolated static func lemelsonMenuBarSpendFontSize(_ size: MenuBarLayoutSize) -> CGFloat {
        switch size {
        case .small: 11
        case .regular: NSFont.systemFontSize
        case .large: 14
        }
    }

    /// Same padding rule as `MenuBarLayoutRenderedTitle.statusItemWidth(gap:)`.
    static func lemelsonMenuBarSpendWidth(title: NSAttributedString, gap: MenuBarLayoutGap) -> CGFloat {
        let bounds = title.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(18, ceil(bounds.width) + (gap == .tight ? 3 : 10))
    }

    func lemelsonMenuBarSpendTooltip(state: UsagePanelState, alwaysCents: Bool) -> String {
        func money(_ usd: Double) -> String {
            let value = usd.isFinite && usd > 0 ? usd : 0
            if !alwaysCents, value < 0.005 {
                return "$0"
            }
            return Self.lemelsonFormatMenuBarSpend(value, alwaysCents: alwaysCents)
        }
        var lines = [Self.lemelsonMenuBarSpendTooltipHeader]
        let byProvider = state.spend24h?.byProvider
        let claudeProvider = byProvider?.claude
        if claudeProvider?.error != nil {
            lines.append("Claude: unavailable")
        } else {
            let claudeAccounts: [(name: String, usd: Double)] = claudeProvider?.accounts?
                .map { ($0.short ?? $0.name, $0.usd) }
                ?? state.accounts.filter { !$0.isUnavailable }.compactMap { account in
                    account.usd24h.map { (account.short, $0) }
                }
            let failedAccounts = claudeProvider?.failedAccounts
                ?? state.accounts.filter(\.isUnavailable).count
            let claudeUsd = claudeProvider?.usd ?? Self.lemelsonSum(claudeAccounts.map(\.usd))
            if let claudeUsd {
                var line = "Claude: \(money(claudeUsd))"
                var parts: [String] = []
                if self.settings.hidePersonalInfo {
                    if claudeAccounts.count > 1 || failedAccounts > 0 {
                        parts.append(claudeAccounts.count == 1 ? "1 account" : "\(claudeAccounts.count) accounts")
                    }
                } else if claudeAccounts.count > 1 || failedAccounts > 0 {
                    parts = claudeAccounts.map { "\($0.name) \(money($0.usd))" }
                    let attributed = claudeAccounts.reduce(0) { $0 + $1.usd }
                    let unattributed = claudeUsd - attributed
                    if unattributed >= 0.5 {
                        parts.append("other \(money(unattributed))")
                    }
                }
                if failedAccounts > 0 {
                    parts.append("\(failedAccounts) unavailable")
                }
                if !parts.isEmpty {
                    line += " (\(parts.joined(separator: ", ")))"
                }
                lines.append(line)
            }
        }
        let others: [(String, UsageProviderBlock?, UsagePanelState.Spend24h.Provider?)] = [
            ("Codex", state.codex, byProvider?.codex),
            ("Antigravity", state.antigravity, byProvider?.antigravity),
        ]
        for (label, block, spend) in others {
            if let spend {
                lines.append(spend.error == nil ? "\(label): \(money(spend.usd))" : "\(label): unavailable")
            } else if let block {
                if block.error != nil {
                    lines.append("\(label): unavailable")
                } else if let usd = block.account.usd24h {
                    lines.append("\(label): \(money(usd))")
                }
            }
        }
        let asOf = state.spend24h?.asOf.map { Date(timeIntervalSince1970: $0) } ?? state.generatedDate
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"
        lines.append("Updated \(clock.string(from: asOf))")
        return lines.joined(separator: "\n")
    }

    private nonisolated static func lemelsonSum(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +)
    }
}
