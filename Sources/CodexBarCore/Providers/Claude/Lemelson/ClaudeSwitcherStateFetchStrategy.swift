import Foundation

/// Claude limits from the Claude Switcher summary (fork addition, not in upstream CodexBar).
///
/// The Claude Switcher collector (`usage/tick.py`) requests each account's limits itself and
/// follows the VPN rule: an account that lives only behind a VPN is not queried from the home IP,
/// and vice versa. CodexBar's usual sources (OAuth, cookie, CLI) do not know this rule and query
/// whichever account's token is currently in the Keychain. So while the summary exists, CodexBar
/// takes the active account's limits only from it and does not go to the network for them.
struct ClaudeSwitcherStateFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.switcher-state"
    let kind: ProviderFetchKind = .localProbe

    static let sourceLabel = "claude-switcher"

    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher/usage/state.json")
    }

    static var accountsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeSwitcher/accounts.json")
    }

    /// Enabled whenever Claude Switcher has either `state.json` or `accounts.json` so CodexBar never
    /// bypasses Switcher's VPN rule by falling back to direct network probes while `state.json` updates.
    static func makeIfAvailable(fileManager: FileManager = .default) -> ClaudeSwitcherStateFetchStrategy? {
        // Tests exercise CodexBar's own source routing; a summary on the developer's Mac must not change it.
        guard !TestProcessSafety.isRunning else { return nil }
        let exists = fileManager.fileExists(atPath: self.stateURL.path)
            || fileManager.fileExists(atPath: self.accountsURL.path)
        return exists ? ClaudeSwitcherStateFetchStrategy() : nil
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let state = try Self.loadState()
        let account = try Self.resolveActiveAccount(in: state)
        guard let usage = Self.snapshot(for: account, now: Date()) else {
            throw StateError.noMeasurement(account.short)
        }
        return self.makeResult(usage: usage, sourceLabel: Self.sourceLabel)
    }

    /// Never falls back to network sources: otherwise the VPN rule would be bypassed on any error.
    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    // MARK: - Summary

    enum StateError: LocalizedError {
        case unreadable
        case noActiveAccount
        case noMeasurement(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "The Claude Switcher usage summary cannot be read."
            case .noActiveAccount:
                "The Claude Switcher summary has no active account."
            case let .noMeasurement(name):
                "No limit reading for \(name) yet."
            }
        }
    }

    struct State: Decodable {
        let accounts: [Account]
    }

    struct Account: Decodable {
        let uuid: String?
        let name: String
        let short: String
        let active: Bool?
        let planName: String?
        let has5h: Bool?
        let windows: [String: Window]?
    }

    private struct SwitcherAccountsFile: Decodable {
        struct Entry: Decodable {
            let id: String
            let accountUuid: String?
        }

        let activeId: String?
        let accounts: [Entry]
    }

    static func activeAccountUuid(from accountsURL: URL = ClaudeSwitcherStateFetchStrategy.accountsURL) -> String? {
        guard let data = try? Data(contentsOf: accountsURL, options: [.uncached]),
              let store = try? JSONDecoder().decode(SwitcherAccountsFile.self, from: data),
              let activeId = store.activeId,
              let uuid = store.accounts.first(where: { $0.id == activeId })?.accountUuid,
              !uuid.isEmpty
        else { return nil }
        return uuid
    }

    /// Reconciles `state.json` against `accounts.json` when available so an account switch never displays
    /// the previous account's limits while `tick.py --switch` is still writing the new `state.json`.
    static func resolveActiveAccount(
        in state: State,
        accountsURL: URL = ClaudeSwitcherStateFetchStrategy.accountsURL) throws -> Account
    {
        if let liveUuid = self.activeAccountUuid(from: accountsURL) {
            if let matched = state.accounts.first(where: { $0.uuid == liveUuid }) {
                return matched
            }
            throw StateError.noActiveAccount
        }
        guard let account = state.accounts.first(where: { $0.active == true }) else {
            throw StateError.noActiveAccount
        }
        return account
    }

    struct Window: Decodable {
        let pct: Double?
        let measuredAt: Double?
        let resetsAt: Double?
        let source: String?
    }

    static func loadState(from url: URL = ClaudeSwitcherStateFetchStrategy.stateURL) throws -> State {
        guard let data = try? Data(contentsOf: url, options: [.uncached]),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { throw StateError.unreadable }
        return state
    }

    static func snapshot(for account: Account, now: Date) -> UsageSnapshot? {
        let windows = account.windows ?? [:]
        let primary: RateWindow? = account.has5h == false
            ? nil
            : self.rateWindow(windows["5h"], minutes: 5 * 60, now: now, requiresPoll: true)
        let secondary = self.rateWindow(windows["7d"], minutes: 7 * 24 * 60, now: now, requiresPoll: false)
        var scoped: [NamedRateWindow] = []
        if let fable = self.rateWindow(windows["fable"], minutes: 7 * 24 * 60, now: now, requiresPoll: false) {
            scoped = ClaudeScopedWeeklyLimitMapper.extraRateWindows(from: [
                ClaudeScopedWeeklyLimitMapper.Limit(
                    kind: "weekly_scoped",
                    group: "weekly",
                    percent: fable.usedPercent,
                    resetsAt: fable.resetsAt,
                    modelID: nil,
                    modelName: "Fable"),
            ])
        }
        guard primary != nil || secondary != nil || !scoped.isEmpty else { return nil }
        let measuredAt = windows.values.compactMap(\.measuredAt).max()
        // The address is the first word of the name: Claude Switcher may append a parenthesized note to it.
        let email = account.name.split(separator: " ").first.map(String.init)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: scoped.isEmpty ? nil : scoped,
            updatedAt: measuredAt.map { Date(timeIntervalSince1970: $0) } ?? now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: account.planName ?? self.sourceLabel,
                accountID: nil))
    }

    private static func rateWindow(_ window: Window?, minutes: Int, now: Date, requiresPoll: Bool) -> RateWindow? {
        guard let window, let percent = window.pct, percent.isFinite else { return nil }
        if requiresPoll, window.source != "poll" {
            return nil
        }
        let resetsAt = window.resetsAt.map { Date(timeIntervalSince1970: $0) }
        // A window that has already reset is shown empty: the old percentage does not apply to the new window.
        let expired = resetsAt.map { $0 <= now } ?? false
        return RateWindow(
            usedPercent: expired ? 0 : min(100, max(0, percent)),
            windowMinutes: minutes,
            resetsAt: expired ? nil : resetsAt,
            resetDescription: nil)
    }
}
