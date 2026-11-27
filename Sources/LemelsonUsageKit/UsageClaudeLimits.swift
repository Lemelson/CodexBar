import SwiftUI

// Claude Limits: one shared limit card (`UsageLimitCard.swift`) per Claude account. This file holds only what
// is Claude's own: the order of the cards, each account's tint and badge, and the notes under its name.

private enum UsageClaudeLimitAccount: String, CaseIterable {
    case lemelson
    case magomed
    case misha

    init?(account: UsagePanelState.Account) {
        self.init(rawValue: account.displayName.lowercased())
    }

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
            return UsageClaudeLimitAccount.position(of: lhs) < UsageClaudeLimitAccount.position(of: rhs)
        }
    }
}

extension UsageLimitCardStyle {
    /// The same account tint follows the account when the active one changes.
    public init(account: UsagePanelState.Account, in state: UsagePanelState) {
        switch UsageClaudeLimitAccount(account: account) {
        case .lemelson:
            self.init(tint: UsagePalette.dynamic(light: 0x6946B6, dark: 0xA98BFF), initials: "L", active: account.isActive)
        case .misha:
            self.init(tint: UsagePalette.dynamic(light: 0x2461B7, dark: 0x62A8FF), initials: "M", active: account.isActive)
        case .magomed:
            self.init(tint: UsagePalette.dynamic(light: 0x526C25, dark: 0xADC46D), initials: "Mg", active: account.isActive)
        case nil:
            self.init(
                tint: UsagePalette.account(state.colorIndex(of: account)),
                initials: String(account.displayName.prefix(2)).capitalized,
                active: account.isActive)
        }
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
