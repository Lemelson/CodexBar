import Foundation
import LemelsonUsageKit

/// `overviewTimeline` for the preview (`usage/timeline.py` writes the real one): a copy of the summary with
/// the block replaced, so the picture goes through the same decoding as the menu.
///
///   made     a made-up timeline for every account of the summary: all three ranges, one Codex account
///            without a rate
///   partial  "made" with what the collector writes on a bad day: a provider rebuilt only in part, grid
///            points it could not fill, a share that is not split, a change left out at the start
///   none     no `overviewTimeline`: the summary of an older collector
///   error    the collector's `{"error": …}` in its place
enum OverviewFixture {
    static let names = ["made", "partial", "none", "error"]

    /// A copy of the summary at `url` with the fixture's timeline; nil when the summary cannot be read.
    static func writing(from url: URL, fixture: String, now: Date) -> URL? {
        guard let data = try? Data(contentsOf: url),
              var summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch fixture {
        case "none":
            summary["overviewTimeline"] = nil
        case "error":
            summary["overviewTimeline"] = ["error": "timeline-failed:KeyError"]
        default:
            summary["overviewTimeline"] = self.timeline(for: summary, partial: fixture == "partial", now: now)
        }
        guard let output = try? JSONSerialization.data(withJSONObject: summary) else { return nil }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemelson-preview-overview-\(fixture).json")
        do {
            try output.write(to: copy)
            return copy
        } catch {
            return nil
        }
    }

    // MARK: - The made-up timeline

    private struct Account {
        let key: String
        let provider: String
        let uuid: String
        let short: String
        let planName: Any
        let active: Bool
        /// Dollars per 100% of the weekly limit; nil for an account without a rate.
        let usdPer100: Double?
        /// Points of the weekly limit per day: this Mac and others.
        let you: Double
        let others: Double
    }

    private static func accounts(of summary: [String: Any]) -> [Account] {
        var found: [(provider: String, entry: [String: Any])] = []
        for entry in summary["accounts"] as? [[String: Any]] ?? [] {
            found.append(("claude", entry))
        }
        for provider in ["codex", "antigravity"] {
            guard let block = summary[provider] as? [String: Any], block["error"] == nil else { continue }
            let entries = block["accounts"] as? [[String: Any]] ?? []
            for entry in entries.isEmpty ? [block] : entries {
                found.append((provider, entry))
            }
        }
        // Made-up paces, so every account draws its own curve: (you, others) in points per day.
        let paces: [(Double, Double)] = [(9.5, 4.0), (2.0, 6.5), (0.4, 1.2), (5.0, 7.5), (0.0, 1.5), (1.0, 9.0)]
        let rates = [2800.0, 1240.0, 1310.0, 115.0, 0.0, 570.0]
        return found.enumerated().compactMap { index, item in
            guard let uuid = item.entry["uuid"] as? String else { return nil }
            let pace = paces[index % paces.count]
            // The second Codex account has no rate: its others' use has no dollar figure.
            let codexIndex = found.prefix(index).count(where: { $0.provider == "codex" })
            let rate = item.provider == "codex" && codexIndex == 1 ? nil : max(100, rates[index % rates.count])
            return Account(
                key: "\(item.provider):\(uuid)",
                provider: item.provider,
                uuid: uuid,
                short: item.entry["short"] as? String ?? item.entry["name"] as? String ?? uuid,
                planName: item.entry["planName"] ?? NSNull(),
                active: item.entry["active"] as? Bool ?? false,
                usdPer100: rate,
                you: pace.0,
                others: pace.1)
        }
    }

    private static func timeline(for summary: [String: Any], partial: Bool, now: Date) -> [String: Any] {
        let asOf = ((summary["generatedAt"] as? Double) ?? now.timeIntervalSince1970).rounded(.down)
        let accounts = self.accounts(of: summary)
        var ranges: [String: Any] = [:]
        for (name, hours, step) in [("24h", 24.0, 900.0), ("72h", 72.0, 1800.0), ("7d", 168.0, 3600.0)] {
            ranges[name] = self.range(accounts, from: asOf - hours * 3600, to: asOf, step: step, partial: partial)
        }
        return [
            "version": 1,
            "asOf": asOf,
            "quotaWindow": "7d",
            "providers": [
                "claude": ["builtAt": asOf, "partial": false],
                "codex": ["builtAt": asOf, "partial": partial],
                "antigravity": ["builtAt": asOf, "partial": false],
            ],
            "accounts": accounts.map { account -> [String: Any] in
                ["key": account.key, "provider": account.provider, "uuid": account.uuid, "short": account.short,
                 "planName": account.planName, "active": account.active, "rated": account.usdPer100 != nil,
                 "usdPer100": account.usdPer100 ?? NSNull(), "quotaThrough": asOf - 30]
            },
            "ranges": ranges,
        ]
    }

    /// One range: every series cumulative from `from`, on the grid `from + i * step`.
    private static func range(
        _ accounts: [Account], from: Double, to: Double, step: Double, partial: Bool) -> [String: Any]
    {
        let count = Int(((to - from) / step).rounded(.down)) + 1
        // Use comes in working hours: the share of a day's use that falls on each grid step.
        func weight(_ time: Double, shift: Double) -> Double {
            let hourOfDay = ((time / 3600 + shift).truncatingRemainder(dividingBy: 24) + 24)
                .truncatingRemainder(dividingBy: 24)
            return hourOfDay > 9 && hourOfDay < 23 ? 1.6 : 0.15
        }
        var perAccount: [String: Any] = [:]
        var combinedQuota = Array(repeating: [0.0, 0.0, 0.0], count: count)
        var combinedYouUsd = Array(repeating: 0.0, count: count)
        var combinedOthersUsd = Array(repeating: 0.0, count: count)
        var tokens = 0.0
        for (order, account) in accounts.enumerated() {
            var you = 0.0
            var others = 0.0
            var unknown = 0.0
            var quota: [Any] = []
            var usdYou: [Any] = []
            var usdOthers: [Any] = []
            // Without a rate nothing is "you": this Mac's part stays unsplit.
            let rated = account.usdPer100 != nil
            for index in 0..<count {
                let time = from + Double(index) * step
                if index > 0 {
                    let days = step / 86400
                    let mine = account.you * days * weight(time, shift: 3)
                    let theirs = account.others * days * weight(time, shift: Double(order) * 5)
                    let hazy = partial && order == 1
                    you += rated && !hazy ? mine : 0
                    unknown += rated && !hazy ? 0 : mine
                    others += theirs
                }
                var flags = rated ? 4 : 0
                if partial {
                    flags |= index < 2 ? 8 : 0
                    flags |= order == 1 ? 2 : 0
                    flags |= order == 2 && index > count * 2 / 3 ? 1 : 0
                }
                // A stretch of grid points the collector could not fill.
                let missing = partial && order == 0 && index > count / 2 && index < count / 2 + 6
                quota.append(missing ? NSNull() : [you, others, unknown, flags] as [Any])
                // This Mac's dollars are known with or without a rate.
                let rate = account.usdPer100 ?? 240
                let mineUsd = (you + (rated ? 0 : unknown)) * rate / 100
                usdYou.append(mineUsd)
                usdOthers.append(others * rate / 100)
                combinedQuota[index][0] += you / 100
                combinedQuota[index][1] += others / 100
                combinedQuota[index][2] += unknown / 100
                combinedYouUsd[index] += mineUsd
                combinedOthersUsd[index] += rated ? others * rate / 100 : 0
            }
            tokens += (you + unknown) * 21_000_000
            var series: [String: Any] = ["quota": quota, "usdYou": usdYou, "tokensYou": (you + unknown) * 21_000_000]
            series["usdOthers"] = rated ? usdOthers : NSNull()
            perAccount[account.key] = series
        }
        let flags = partial ? 13 : 4
        let last = combinedQuota.last ?? [0, 0, 0]
        return [
            "from": from,
            "to": to,
            "stepSec": step,
            "combined": [
                "quota": combinedQuota.map { [$0[0], $0[1], $0[2], Double(flags)] },
                "usdYou": combinedYouUsd,
                "usdOthers": combinedOthersUsd,
                "unratedAccounts": accounts.filter { $0.usdPer100 == nil }.map(\.key),
                "totalYouUsd": combinedYouUsd.last ?? 0,
                "totalYouTokens": tokens,
                "totalOthersUsd": combinedOthersUsd.last ?? 0,
                "totalYouQuota": last[0],
                "totalOthersQuota": last[1],
                "totalUnknownQuota": last[2],
            ],
            "accounts": perAccount,
        ]
    }
}
