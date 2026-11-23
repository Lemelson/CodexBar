import Foundation
import LemelsonUsageKit

/// Changes to a real summary for renders of states it does not have right now.
enum ClaudeFixture {
    /// Fills the fields of `usage/STATE-ADDITIONS-24.md` that a summary does not have yet, from what it has:
    /// `refresh` from the VPN flag, and for every week `minePct` / `minePctByModel` / `othersPct` from its
    /// dollars through the account's rate, `peakAt` / `peakFinal` (every other past week read early).
    static func fillingMissingFields(_ state: UsagePanelState) -> UsagePanelState {
        var state = state
        let families = ["opus", "fable", "sonnet", "haiku", "other"]
        for index in state.accounts.indices {
            var account = state.accounts[index]
            if account.refresh == nil {
                account.refresh = account.needsVPN ? "manual" : "background"
                account.refreshEverySec = account.needsVPN ? nil : 3600
            }
            let capacity = account.rates?["7d"]?.usdPer100
            let fableWeight = state.fableWeight(for: account)
            for (position, week) in (account.weeks ?? []).enumerated() {
                var week = week
                if week.minePct == nil, let capacity, capacity > 0 {
                    var byModel: [String: Double] = [:]
                    for family in families {
                        let usd = week.m?[family]?.first ?? 0
                        byModel[family] = usd * (family == "fable" ? fableWeight : 1) / capacity * 100
                    }
                    week.minePctByModel = byModel
                    week.minePct = byModel.values.reduce(0, +)
                }
                if let peak = week.peakPct {
                    week.peakAt = week.peakAt ?? (week.end - (position.isMultiple(of: 2) ? 3600 : 2 * 86400))
                    week.peakFinal = week.peakFinal ?? (week.current != true && position.isMultiple(of: 2))
                    if week.othersPct == nil, let mine = week.minePct {
                        week.othersPct = max(0, peak - mine)
                    }
                }
                account.weeks?[position] = week
            }
            state.accounts[index] = account
        }
        return state
    }

    /// Moves the last reading of every manually read account `hours` back, windows and all, as if it had
    /// not been read since: with enough hours its windows have reset by now.
    static func agingManualReadings(_ state: UsagePanelState, hours: Double) -> UsagePanelState {
        var state = state
        let shift = hours * 3600
        for index in state.accounts.indices where !state.accounts[index].refreshesInBackground {
            var account = state.accounts[index]
            account.lastMeasuredAt = account.lastMeasuredAt.map { $0 - shift }
            for (key, window) in account.windows ?? [:] {
                var window = window
                window.measuredAt = window.measuredAt.map { $0 - shift }
                window.resetsAt = window.resetsAt.map { $0 - shift }
                window.start = window.start.map { $0 - shift }
                window.series = window.series?.map { row in
                    row.enumerated().map { $0.offset == 0 ? $0.element.map { $0 - shift } : $0.element }
                }
                window.forecast = nil
                account.windows?[key] = window
            }
            state.accounts[index] = account
        }
        return state
    }
}
