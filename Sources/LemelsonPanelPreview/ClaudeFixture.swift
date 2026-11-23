import Foundation
import LemelsonUsageKit

/// Changes to a real summary for renders of states it does not have right now.
enum ClaudeFixture {
    /// Fills the newer fields of `usage/README.md` that a summary does not have yet, from what it has:
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

    /// Made-up limit weeks for the Value page's limit chart, under made-up names ("Account A", ...):
    /// A has twelve weeks (three or four months), B only the current week (a single, preliminary month),
    /// C the last three weeks (a single month with enough days). Weeks end a day after the summary, as the
    /// current week does. Any further accounts lose their weeks.
    static func driftMonths(_ state: UsagePanelState) -> UsagePanelState {
        var state = state
        let week = 7 * 24 * 3600.0
        let lastEnd = state.generatedAt + 24 * 3600
        let plans: [[Double]] = [
            Array([905, 930, 1290, 880, 1010, 1160, 810, 1090, 1300, 1260, 1230, 1240].reversed()),
            [2980],
            [1520, 1610, 1580],
        ]
        for index in state.accounts.indices {
            let letter = String(UnicodeScalar(UInt8(65 + index % 26)))
            state.accounts[index].name = "Account \(letter)"
            state.accounts[index].short = "Account \(letter)"
            let values = index < plans.count ? plans[index] : []
            state.accounts[index].drift = Array(values.enumerated().map { offset, usd in
                let end = lastEnd - Double(offset) * week
                // Mostly Opus, with some Fable in every other week, so "My mix" has something to weigh.
                let spend = """
                {"opus": \(usd * 0.4), "fable": \(offset.isMultiple(of: 2) ? usd * 0.05 : 0), "other": 1}
                """
                let json = "{\"weekEnd\": \(end), \"usd_per_100\": \(usd), \"pairs\": 500, \"spend\": \(spend)}"
                return try! JSONDecoder().decode(UsagePanelState.DriftPoint.self, from: Data(json.utf8))
            }.reversed())
        }
        return state
    }

    /// The collector's failure isolation (`usage/README.md`), written into a copy of the summary's
    /// JSON so it goes through the real decoding: the accounts at `broken` (positions in the summary) become
    /// error stubs `{uuid, name, short, active, useHapp, error, refresh, refreshEverySec, cache}`, and with
    /// `cacheError` every `cache` is null and a top-level `cacheError` is set. Returns the copy's URL.
    static func writingFailures(from url: URL, broken: [Int], cacheError: Bool) -> URL? {
        guard let data = try? Data(contentsOf: url),
              var summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var accounts = summary["accounts"] as? [[String: Any]]
        else { return nil }
        let kept = ["uuid", "name", "short", "active", "useHapp", "refresh", "refreshEverySec", "cache"]
        for index in broken where accounts.indices.contains(index) {
            var stub = accounts[index].filter { kept.contains($0.key) }
            stub["error"] = "error: ValueError: made up for the preview"
            accounts[index] = stub
        }
        if cacheError {
            for index in accounts.indices {
                accounts[index]["cache"] = NSNull()
            }
            summary["cache"] = NSNull()
            summary["cacheError"] = "error: ZeroDivisionError: division by zero"
        }
        summary["accounts"] = accounts
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemelson-preview-failures-\(ProcessInfo.processInfo.processIdentifier).json")
        guard let merged = try? JSONSerialization.data(withJSONObject: summary),
              (try? merged.write(to: copy)) != nil
        else { return nil }
        return copy
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
