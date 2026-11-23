import Foundation
import LemelsonUsageKit

/// Built-in Antigravity blocks for the preview, shaped as `usage/ANTIGRAVITY-STATE.md` describes, with times
/// relative to `now`. They go through the same JSON decoding as the real summary.
///
///   full      5-hour 0% with a fresh window, weekly 40%, four days of spend, three models, cache miss 6%
///   run-out   both limits in deficit, the forecast runs out before the reset
///   no-quota  spend, but CodexBar never recorded a window
///   no-spend  quota readings, but no calls on this Mac
///   one-day   history of one day: no rates, no value, cache for today only
///   error     the collector's Antigravity step failed
///   rolled    "full" after the 5-hour window reset with no newer reading
///   priced    "full" with a known plan and price: "You pay / You get"
enum AntigravityFixture {
    static let names = ["full", "run-out", "no-quota", "no-spend", "one-day", "error", "rolled", "priced"]

    static func state(_ name: String, now: Date) -> UsagePanelState? {
        let summary: [String: Any] = [
            "schema": 4,
            "generatedAt": now.timeIntervalSince1970 - 60,
            "accounts": [],
            "antigravity": self.block(name, now: now),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: summary) else { return nil }
        do {
            return try JSONDecoder().decode(UsagePanelState.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("fixture \(name) does not decode: \(error)\n".utf8))
            return nil
        }
    }

    /// Adds a block read from a file (the collector's sample) to a summary.
    static func merging(blockAt url: URL, into state: UsagePanelState?, now: Date) -> UsagePanelState? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Either a whole summary or the block alone.
        let block = object["antigravity"] ?? object
        let summary: [String: Any] = [
            "schema": 4,
            "generatedAt": (object["generatedAt"] as? Double) ?? state?.generatedAt ?? now.timeIntervalSince1970,
            "accounts": [],
            "antigravity": block,
        ]
        guard let merged = try? JSONSerialization.data(withJSONObject: summary),
              let decoded = try? JSONDecoder().decode(UsagePanelState.self, from: merged)
        else { return nil }
        var result = state ?? decoded
        result.antigravity = decoded.antigravity
        return result
    }

    // MARK: - Blocks

    private static let hour = 3600.0
    private static let day = 86400.0

    private static func block(_ name: String, now: Date) -> [String: Any] {
        var block: [String: Any] = [
            "uuid": "antigravity", "name": "Antigravity", "short": "Antigravity", "beta": true,
            "active": false, "useHapp": false, "planName": NSNull(), "planPriceUsd": NSNull(),
            "lastPoll": NSNull(), "kFable": 1.0,
        ]
        switch name {
        case "error":
            return ["uuid": "antigravity", "name": "Antigravity", "short": "Antigravity", "beta": true,
                    "error": "antigravity.py: database disk image is malformed"]
        case "run-out":
            block.merge(self.quota(now: now, heavy: true)) { $1 }
            block.merge(self.spend(now: now, days: 4)) { $1 }
            block.merge(self.extras(now: now, cacheSpans: ["today", "7d", "30d"])) { $1 }
        case "no-quota":
            block.merge(self.spend(now: now, days: 4)) { $1 }
            block.merge(self.extras(now: now, cacheSpans: ["today", "7d", "30d"])) { $1 }
            block["windows"] = [String: Any]()
            block["rates"] = [String: Any]()
            block["has5h"] = NSNull()
            block["lastMeasuredAt"] = NSNull()
            block["value"] = NSNull()
            block["valueReason"] = "7d rate needs 12 pairs with ≥ $60 between samples; have 0"
        case "no-spend":
            var quota = self.quota(now: now, heavy: false)
            quota["value"] = NSNull()
            quota["rates"] = [String: Any]()
            block.merge(quota) { $1 }
            block.merge(["daily": [], "usdToday": 0, "usd7d": 0, "usd30d": 0, "tokensToday": 0,
                         "tokens7d": 0, "tokens30d": 0, "weeks": [], "trackedSince": NSNull(),
                         "models": [String: Any](), "cache": [String: Any](),
                         "coverage": ["tokens": "exact", "usd": "estimate", "calls": 0]]) { $1 }
        case "one-day":
            block.merge(self.quota(now: now, heavy: false, fresh: true)) { $1 }
            block.merge(self.spend(now: now, days: 1)) { $1 }
            block.merge(self.extras(now: now, cacheSpans: ["today"])) { $1 }
            block["rates"] = [String: Any]()
            block["value"] = NSNull()
            block["valueReason"] = "7d rate needs 12 pairs with ≥ $60 between samples; have 3"
        default:
            block.merge(self.quota(now: now, heavy: false)) { $1 }
            block.merge(self.spend(now: now, days: 4)) { $1 }
            block.merge(self.extras(now: now, cacheSpans: ["today", "7d", "30d"])) { $1 }
            if name == "rolled", var windows = block["windows"] as? [String: Any] {
                // As the collector writes it: 0%, no reset time, no series or forecast.
                windows["5h"] = ["pct": 0.0, "measuredAt": now.timeIntervalSince1970 - 5.5 * hour,
                                 "resetsAt": NSNull(), "source": "codexbar", "rolled": true,
                                 "start": now.timeIntervalSince1970 - 30 * 60,
                                 "usd": ["opus": 0, "fable": 0, "other": 1.8]]
                block["windows"] = windows
            }
            if name == "priced" {
                block["planName"] = "AI Ultra"
                block["planPriceUsd"] = 250.0
            }
        }
        return block
    }

    /// The 5-hour and weekly windows, rates and value.
    private static func quota(now: Date, heavy: Bool, fresh: Bool = false) -> [String: Any] {
        let t = now.timeIntervalSince1970
        let measured = t - (heavy ? 5 : 12) * 60
        var five: [String: Any]
        var week: [String: Any]
        if heavy {
            let reset5 = t + 2 * hour
            five = ["pct": 72.0, "measuredAt": measured, "resetsAt": reset5, "source": "codexbar", "rolled": false,
                    "start": reset5 - 5 * hour, "usd": ["opus": 0, "fable": 0, "other": 68.4],
                    "series": self.ramp(from: reset5 - 5 * hour, to: measured, pct: 72, steps: 9),
                    "forecast": ["at": t - 3 * 60, "pct": 72.0, "ratePerHour": 24.0, "endPct": 100.0,
                                 "endLo": 92.0, "endHi": 100.0, "hitAt": t + 80 * 60, "hitEarly": t + 55 * 60,
                                 "hitLate": NSNull(), "checks": 41, "bandSource": "own"]]
            let reset7 = t + 2 * day + 20 * hour
            week = ["pct": 78.0, "measuredAt": measured, "resetsAt": reset7, "source": "codexbar", "rolled": false,
                    "start": reset7 - 7 * day, "usd": ["opus": 0, "fable": 0, "other": 493.0],
                    "series": self.ramp(from: reset7 - 7 * day, to: measured, pct: 78, steps: 40),
                    "forecast": ["at": t - 3 * 60, "pct": 78.0, "ratePerHour": 0.52, "endPct": 100.0,
                                 "endLo": 96.0, "endHi": 100.0, "hitAt": t + 1 * day + 18 * hour,
                                 "hitEarly": t + 1 * day + 4 * hour, "hitLate": NSNull(), "checks": 33,
                                 "bandSource": "own"]]
        } else if fresh {
            let reset5 = t + 3 * hour + 10 * 60
            five = ["pct": 14.0, "measuredAt": measured, "resetsAt": reset5, "source": "codexbar", "rolled": false,
                    "start": reset5 - 5 * hour, "usd": ["opus": 0, "fable": 0, "other": 13.1],
                    "series": [[reset5 - 5 * hour, 0.0, NSNull()], [t - 70 * 60, 6.0, NSNull()],
                               [measured, 14.0, NSNull()]]]
            let reset7 = t + 6 * day + 20 * hour
            week = ["pct": 3.0, "measuredAt": measured, "resetsAt": reset7, "source": "codexbar", "rolled": false,
                    "start": reset7 - 7 * day, "usd": ["opus": 0, "fable": 0, "other": 13.1],
                    "series": [[measured, 3.0, NSNull()]]]
        } else {
            // A fresh 5-hour window: one reading, 0% used.
            let reset5 = t + 4 * hour + 48 * 60
            five = ["pct": 0.0, "measuredAt": measured, "resetsAt": reset5, "source": "codexbar", "rolled": false,
                    "start": reset5 - 5 * hour, "usd": ["opus": 0, "fable": 0, "other": 0],
                    "series": [[measured, 0.0, NSNull()]]]
            let reset7 = t + 3 * day + 4 * hour
            week = ["pct": 40.0, "measuredAt": measured, "resetsAt": reset7, "source": "codexbar", "rolled": false,
                    "start": reset7 - 7 * day, "usd": ["opus": 0, "fable": 0, "other": 252.9], "sinceMeasure": 0.3,
                    "series": self.weekSeries(now: now, measured: measured),
                    "forecast": ["at": t - 5 * 60, "pct": 40.0, "ratePerHour": 0.31, "endPct": 63.0,
                                 "endLo": 52.0, "endHi": 81.0, "hitAt": NSNull(), "hitEarly": NSNull(),
                                 "hitLate": NSNull(), "checks": 0, "bandSource": "default"]]
        }
        return [
            "has5h": true,
            "lastMeasuredAt": measured,
            "windows": ["5h": five, "7d": week],
            "rates": ["7d": ["pct_per_usd": 0.158, "usd_per_100": 632.0, "pairs": 40, "source": "own"],
                      "5h": ["pct_per_usd": 1.05, "usd_per_100": 95.0, "pairs": 18, "source": "own"]],
            "value": ["weekOpusUsd": 632.0, "monthOpusUsd": 2748.0, "pairs": 40],
            "valueReason": NSNull(),
        ]
    }

    /// Evenly rising readings, one change at a time, as CodexBar stores them.
    private static func ramp(from start: Double, to end: Double, pct: Double, steps: Int) -> [[Any]] {
        (0...steps).map { index in
            let share = Double(index) / Double(steps)
            return [start + (end - start) * share, (pct * share * 10).rounded() / 10, NSNull()]
        }
    }

    /// The weekly window of the "full" fixture: most use on the three days with spend.
    private static func weekSeries(now: Date, measured: Double) -> [[Any]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        var points: [[Any]] = []
        var pct = 0.0
        // (day offset, first hour, last hour, percent added that day)
        let days: [(Double, Double, Double, Double)] = [(-3, 19, 21, 0.1), (-2, 9, 23, 19.0), (-1, 11, 19, 8.4)]
        for (offset, first, last, added) in days {
            let hours = Int(last - first)
            for step in 0...hours {
                pct += added / Double(hours + 1)
                points.append([today + offset * day + (first + Double(step)) * hour, (pct * 10).rounded() / 10, NSNull()])
            }
        }
        let morning = today + 7 * hour
        let span = measured - morning
        for step in 0...4 {
            pct = 27.5 + 12.5 * Double(step) / 4
            points.append([morning + span * Double(step) / 4, (pct * 10).rounded() / 10, NSNull()])
        }
        return points
    }

    /// Daily spend by model: the last `days` days up to today, ending with the brief's $0.6 / $120 / $53 / $79.
    private static func spend(now: Date, days count: Int) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let all: [[String: [Double]]] = [
            ["gemini-4-neon": [0.63, 243_000]],
            ["gemini-4-neon": [117.51, 252_900_000], "gemini-4-carbon": [2.64, 7_400_000],
             "gemini-4-hydrogen": [0.11, 500_000]],
            ["gemini-4-neon": [52.75, 124_900_000], "gemini-4-hydrogen": [0.17, 900_000]],
            ["gemini-4-neon": [78.16, 177_000_000], "gemini-4-hydrogen": [0.97, 2_700_000]],
        ]
        let used = all.suffix(count)
        var daily: [[String: Any]] = []
        var usdTotal = 0.0
        var tokenTotal = 0.0
        for (index, models) in used.enumerated() {
            let offset = -(used.count - 1 - index)
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let usd = models.values.reduce(0) { $0 + $1[0] }
            let tokens = models.values.reduce(0) { $0 + $1[1] }
            usdTotal += usd
            tokenTotal += tokens
            daily.append(["day": UsageDayKey.string(date), "opus": 0, "fable": 0, "other": usd, "tokens": tokens,
                          "m": models])
        }
        let last = used.last ?? [:]
        let todayUsd = last.values.reduce(0) { $0 + $1[0] }
        let todayTokens = last.values.reduce(0) { $0 + $1[1] }
        let first = calendar.date(byAdding: .day, value: -(used.count - 1), to: today) ?? today
        return [
            "daily": daily,
            "trackedSince": first.timeIntervalSince1970 + 15 * hour,
            "usdToday": todayUsd, "tokensToday": todayTokens,
            "usd7d": usdTotal, "tokens7d": tokenTotal, "usd30d": usdTotal, "tokens30d": tokenTotal,
            "weeks": [],
        ]
    }

    private static func extras(now: Date, cacheSpans: [String]) -> [String: Any] {
        let cache: [String: [String: Any]] = [
            "today": ["missPct": 5.1, "coldCallsPct": 2.0, "calls": 1110],
            "7d": ["missPct": 6.0, "coldCallsPct": 3.1, "calls": 3095],
            "30d": ["missPct": 6.4, "coldCallsPct": 3.3, "calls": 3101],
        ]
        return [
            "models": [
                "gemini-4-neon": ["calls": 2981, "input": 32_400_000, "cached": 515_100_000, "cacheWrite": 0,
                                  "output": 4_950_000, "thinking": 1_880_000, "usd": 249.05, "missPct": 5.9,
                                  "efforts": ["High": 2936, "Medium": 45], "priced": true, "priceConfirmed": true],
                "gemini-4-carbon": ["calls": 51, "input": 700_000, "cached": 6_600_000, "cacheWrite": 0,
                                    "output": 60000, "thinking": 21000, "usd": 2.64, "missPct": 9.6,
                                    "priced": true, "priceConfirmed": true],
                "gemini-4-hydrogen": ["calls": 63, "input": 620_000, "cached": 3_400_000, "cacheWrite": 0,
                                      "output": 60000, "thinking": 24000, "usd": 1.25, "missPct": 15.4,
                                      "priced": true, "priceConfirmed": true],
            ],
            "cache": cache.filter { cacheSpans.contains($0.key) },
            "coverage": ["tokens": "exact", "usd": "estimate", "historySince": "2026-11-20", "dbFiles": 12,
                         "calls": 3095, "copiesDropped": 847, "encryptedConversations": 100,
                         "timeEstimatedCalls": 0, "outputCheckFailed": 0, "unpricedCalls30d": 0,
                         "unconfirmedPrices": [], "pricesChecked": "2026-11-23",
                         "notCounted": "encrypted .pb conversations, deleted conversations, Tab completions, other devices"],
            "quotaSource": ["app": "CodexBar", "lastSampleAt": now.timeIntervalSince1970 - 720, "ageSec": 720,
                            "cadence": "CodexBar keeps at most the peak sample of each clock hour"],
        ]
    }
}
