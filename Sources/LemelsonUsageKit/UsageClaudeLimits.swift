import SwiftUI

// Claude Limits and Codex Limits: one shared limit card (`UsageLimitCard.swift`) per account. This file holds
// what the two tabs share about an account (its tint and badge, by name) and what is Claude's own: the order
// of the cards and the notes under its name.

/// The people whose accounts appear on both tabs, by the short name Claude Switcher gives them
/// (`account-names.json`): the same tint and badge on Claude and on Codex, whichever account is active.
public enum UsageAccountTint: String, CaseIterable, Sendable {
    case lemelson
    case magomed
    case misha

    public init?(account: UsagePanelState.Account) {
        self.init(rawValue: account.displayName.lowercased())
    }

    /// Hex colors for light and dark appearance.
    public var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .lemelson: (0x6946B6, 0xA98BFF)
        case .misha: (0x2461B7, 0x62A8FF)
        case .magomed: (0x526C25, 0xADC46D)
        }
    }

    public var initials: String {
        switch self {
        case .lemelson: "L"
        case .misha: "M"
        case .magomed: "Mg"
        }
    }

    public var color: Color {
        UsagePalette.dynamic(light: self.hex.light, dark: self.hex.dark)
    }

    /// Claude Limits' card order: the active account first, then these, then everyone else.
    static func position(of account: UsagePanelState.Account) -> Int {
        guard let known = Self(account: account) else { return self.allCases.count }
        return self.allCases.firstIndex(of: known) ?? self.allCases.count
    }
}

extension UsagePanelState {
    /// Promote the active account while keeping the remaining cards in their usual order.
    public var claudeLimitAccounts: [Account] {
        self.accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return UsageAccountTint.position(of: lhs) < UsageAccountTint.position(of: rhs)
        }
    }
}

extension UsageLimitCardStyle {
    /// The same account tint follows the account when the active one changes.
    public init(account: UsagePanelState.Account, in state: UsagePanelState) {
        self.init(account: account, fallbackIndex: state.colorIndex(of: account))
    }

    /// A known person's tint and badge (`UsageAccountTint`); anyone else gets the chart color of their
    /// position (`fallbackIndex`) and the first two letters of their name. Shared by Claude and Codex Limits.
    public init(account: UsagePanelState.Account, fallbackIndex: Int) {
        if let known = UsageAccountTint(account: account) {
            self.init(tint: known.color, initials: known.initials, active: account.isActive)
        } else {
            self.init(
                tint: UsagePalette.account(fallbackIndex),
                initials: String(account.displayName.prefix(2)).capitalized,
                active: account.isActive)
        }
    }
}

extension UsageSeriesColor {
    /// The color of an account on a chart that sits next to its limit card: the card's tint for a known
    /// person, else the chart color of its position.
    public static func accountTint(_ account: UsagePanelState.Account, fallbackIndex: Int) -> UsageSeriesColor {
        UsageAccountTint(account: account).map { .tint($0) } ?? .account(fallbackIndex)
    }
}

extension UsageLimitCardHeader {
    /// A Claude account's card header: no plan on the right (the three accounts are told apart by name and
    /// tint), the VPN pause status and the age of an old reading in the top-right corner, and a warning note
    /// below only when the account needs an action.
    public init(
        account: UsagePanelState.Account,
        style: UsageLimitCardStyle,
        now: Date,
        width: CGFloat,
        hasLimits: Bool)
    {
        self.init(
            name: account.displayName,
            style: style,
            status: account.limitCardStatus,
            statusAccessibilityLabel: account.limitCardStatus != nil ? "Paused while VPN is on" : nil,
            measuredAt: account.measuredAt,
            now: now,
            note: account.limitCardNote,
            width: width,
            hasLimits: hasLimits)
    }
}

extension UsagePanelState.Account {
    /// The line under a Claude account's name: only what needs an action from me (warnings).
    public var limitCardNote: UsageLimitCardHeader.Note? {
        if let note = self.unavailableNote ?? (self.lastPoll?.status == "auth_rejected" ? nil : self.actionNote) {
            return .init(note, isWarning: true)
        }
        return nil
    }

    /// Quiet trailing label in the header's top-right corner when paused by VPN (unless a warning takes precedence).
    public var limitCardStatus: String? {
        guard self.limitCardNote == nil else { return nil }
        return self.pauseStatus
    }

    /// Age badge text shown in the card header ("2h old"), or nil while fresh.
    public func limitCardAgeText(now: Date) -> String? {
        UsageLimitCardHeader.ageText(measuredAt: self.measuredAt, now: now)
    }

    /// An account the collector skips while the VPN is on is waiting, not failing.
    var pauseStatus: String? {
        self.isPausedByVPN ? "Paused · VPN" : nil
    }

    /// What needs an action from me. Of the reasons an account is merely waiting only the VPN pause is shown
    /// (`pauseStatus`, quietly in the header corner); for the rest the age of the reading says enough.
    var actionNote: String? {
        switch self.lastPoll?.status {
        case "auth_rejected":
            "Sign-in expired: open it once in Claude Switcher."
        case "keychain_denied":
            "No Keychain access to read limits."
        case "no_session_cookie", "cookies_unreadable", "no_org":
            "No saved sign-in for this account yet."
        default:
            nil
        }
    }
}
