import SwiftUI

/// What makes one single-account provider page different from another: name, card tint and badge, how its
/// model ids read, and the words for its prices and its local logs. Everything else (card, rows, spend, value,
/// footer, cache row) is the same shared parts.
///
/// A new provider is one more `static let` here, a key in `UsagePanelState` for its block, and a menu hook in
/// the app that builds `UsageProviderPage(spec:state:…)`.
public struct UsageProviderSpec: Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case antigravity
        case codex
    }

    public let key: Key
    /// "Antigravity", "Codex": card title, captions, the cache row.
    public let name: String
    /// The card's badge: "Ag", "Cx".
    public let initials: String
    /// The card's tint (header gradient and badge).
    public let tint: Color
    public let models: UsageModelNaming
    /// "Gemini API prices", "OpenAI API prices".
    public let prices: String
    /// Where the tokens are read from, after "from": "this Mac's Antigravity files".
    public let source: String
    /// Use the limit counts that this Mac cannot see, for "(…)" after "moved the limit more than this Mac's
    /// use explains".
    public let elsewhere: String
    /// Words dropped from the plan name in the card header: "Google AI Ultra 5x" → "Ultra 5x".
    let planPrefixes: [String]

    /// Every row id of the page starts with this (the app's warm-row recycling looks for it).
    public var idPrefix: String {
        "lemelson\(self.name)-"
    }

    /// Limit row ids start with this: `lemelsonLimit-` is the prefix the hover wiring looks for.
    public var limitRowPrefix: String {
        "lemelsonLimit-\(self.key.rawValue)-"
    }

    public var cardStyle: UsageLimitCardStyle {
        UsageLimitCardStyle(tint: self.tint, initials: self.initials)
    }

    /// The provider's block in the summary, or nil when the collector did not write one.
    public func block(in state: UsagePanelState) -> UsageProviderBlock? {
        switch self.key {
        case .antigravity: state.antigravity
        case .codex: state.codex
        }
    }

    /// Whose use "You" is on this provider's limits, for a window the collector split (`Window.Split`).
    public func localSource(block: UsageProviderBlock?) -> UsageLocalSource {
        UsageLocalSource(
            app: self.name,
            providerNote: self.elsewhere,
            stretchUsd: block?.calibration?.weekStretchUsd)
    }

    /// How a window's use is told apart: by the collector's split when it wrote one, else not at all.
    public func sources(for window: UsagePanelState.Window, block: UsageProviderBlock?) -> UsageLimitSources {
        window.split == nil ? .single : .local(self.localSource(block: block))
    }

    /// "Google AI Ultra 5x" → "Ultra 5x"; nil stays nil, an empty result keeps the whole name.
    public func shortPlan(_ plan: String?) -> String? {
        guard var plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else { return nil }
        for prefix in self.planPrefixes where plan.lowercased().hasPrefix(prefix.lowercased() + " ") {
            plan = String(plan.dropFirst(prefix.count + 1))
        }
        return plan.isEmpty ? nil : plan
    }

    public static func spec(for key: Key) -> UsageProviderSpec {
        switch key {
        case .antigravity: self.antigravity
        case .codex: self.codex
        }
    }

    /// Gemini through Antigravity: `state.antigravity`, `usage/ANTIGRAVITY-STATE.md`. Tint: the green of
    /// CodexBar's Antigravity tab, darker and lighter so it differs from the blue of the bar.
    public static let antigravity = UsageProviderSpec(
        key: .antigravity,
        name: "Antigravity",
        initials: "Ag",
        tint: UsagePalette.dynamic(light: 0x2F8A4F, dark: 0x6CCB8C),
        models: .gemini,
        prices: "Gemini API prices",
        source: "this Mac's Antigravity files",
        elsewhere: "a phone or the Gemini app",
        planPrefixes: ["Google AI", "Google"])

    /// Codex: `state.codex`, `usage/CODEX-STATE.md` (the same shape as Antigravity's block). Tint: the teal
    /// of CodexBar's Codex tab.
    public static let codex = UsageProviderSpec(
        key: .codex,
        name: "Codex",
        initials: "Cx",
        tint: UsagePalette.dynamic(light: 0x23798A, dark: 0x5CC0CE),
        models: .openai,
        prices: "OpenAI API prices",
        source: "this Mac's Codex sessions",
        elsewhere: "Codex cloud, ChatGPT or another computer",
        planPrefixes: ["ChatGPT"])
}
