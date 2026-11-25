import Foundation
import LemelsonUsageKit
import Testing

// lemelson: the live quota readings files of Antigravity and Codex (usage/ANTIGRAVITY-STATE.md, "Live readings file").
@MainActor
struct LemelsonUsageQuotaLiveTests {
    typealias Reading = UsageQuotaLiveReading

    private func reading(_ ts: Int, five: Double? = 1, week: Double? = 40.8, reset: Int? = 1_795_439_520) -> Reading {
        Reading(
            ts: ts,
            fiveHour: five.map { Reading.Window(pct: $0, resetsAt: reset) },
            week: week.map { Reading.Window(pct: $0, resetsAt: 1_795_873_920) })
    }

    private func scratchFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lemelson-live-\(UUID().uuidString)", isDirectory: true)
        // The writer creates the folder itself.
        return dir.appendingPathComponent("antigravity-quota.jsonl")
    }

    @Test
    func `line format matches the contract`() {
        #expect(self.reading(1_795_424_947).jsonLine ==
            "{\"ts\": 1795424947, \"source\": \"codexbar-live\", \"windows\": {\"5h\": {\"pct\": 1.0, \"resetsAt\": 1795439520}, \"7d\": {\"pct\": 40.8, \"resetsAt\": 1795873920}}}\n")
        // A missing window is left out; an unknown reset is null; the percent is rounded to hundredths.
        let partial = Reading(ts: 10, fiveHour: .init(pct: 59.199999999999996, resetsAt: nil as Int?), week: nil)
        #expect(partial.jsonLine == "{\"ts\": 10, \"source\": \"codexbar-live\", \"windows\": {\"5h\": {\"pct\": 59.2, \"resetsAt\": null}}}\n")
        // A fractional epoch is truncated.
        let dated = Reading(at: Date(timeIntervalSince1970: 100.9), fiveHour: nil, week: .init(pct: 3, resetsAt: Date(timeIntervalSince1970: 200.7)))
        #expect(dated.jsonLine == "{\"ts\": 100, \"source\": \"codexbar-live\", \"windows\": {\"7d\": {\"pct\": 3.0, \"resetsAt\": 200}}}\n")
        // The line parses as JSON and reads back the same.
        let line = self.reading(5).jsonLine
        #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        #expect(Reading(jsonLine: line) == self.reading(5))
    }

    @Test
    func `plan key is optional, as fetched, and not a value of the reading`() {
        let base = self.reading(7)
        let planned = Reading(ts: 7, fiveHour: base.fiveHour, week: base.week, plan: "  Pro Plan \"x\"  ")
        #expect(planned.plan == "Pro Plan \"x\"")
        let line = planned.jsonLine
        #expect(line.hasSuffix(", \"plan\": \"Pro Plan \\\"x\\\"\"}\n"))
        // The other keys and their order stay as they were.
        #expect(line.hasPrefix(String(base.jsonLine.dropLast(2))))
        #expect(Reading(jsonLine: line) == planned)
        // Unknown (nil or blank): the key is left out.
        #expect(Reading(ts: 7, fiveHour: base.fiveHour, week: base.week, plan: " ").jsonLine == base.jsonLine)
        // A new plan name alone does not make a line.
        #expect(UsageQuotaLiveWriter.decide(Reading(ts: 8, fiveHour: base.fiveHour, week: base.week, plan: "Other"), after: planned) == .unchanged)
    }

    @Test
    func `account key goes last, is never an e-mail, and a new account writes a line at once`() {
        let base = self.reading(7)
        let key = "codex:v1:provider-account:16f67a35"
        let owned = Reading(ts: 7, fiveHour: base.fiveHour, week: base.week, plan: "Plus", account: key)
        #expect(owned.jsonLine.hasSuffix(", \"plan\": \"Plus\", \"account\": \"\(key)\"}\n"))
        #expect(Reading(jsonLine: owned.jsonLine) == owned)
        // Unknown: no key at all.
        #expect(!Reading(ts: 7, fiveHour: base.fiveHour, week: base.week, account: " ").jsonLine.contains("account"))
        // The same numbers from another account are a new line, not "unchanged".
        let other = Reading(ts: 8, fiveHour: base.fiveHour, week: base.week, plan: "Plus", account: "codex:v1:other")
        #expect(UsageQuotaLiveWriter.decide(other, after: owned) == .written)
        let again = Reading(ts: 8, fiveHour: base.fiveHour, week: base.week, plan: "Plus", account: key)
        #expect(UsageQuotaLiveWriter.decide(again, after: owned) == .unchanged)
    }

    @Test
    func `one file per provider next to the summary`() {
        let folder = UsagePanelStore.defaultURL.deletingLastPathComponent()
        #expect(UsageQuotaLiveWriter.antigravity.url == folder.appendingPathComponent("antigravity-quota.jsonl"))
        #expect(UsageQuotaLiveWriter.codex.url == folder.appendingPathComponent("codex-quota.jsonl"))
        #expect(UsageQuotaLiveWriter.codex.lockURL.lastPathComponent == "codex-quota.jsonl.lock")
    }

    @Test
    func `changed, unchanged and the ten minute rule`() {
        let first = self.reading(1000)
        #expect(UsageQuotaLiveWriter.decide(first, after: nil) == .written)
        // Same values, less than ten minutes later.
        #expect(UsageQuotaLiveWriter.decide(self.reading(1599), after: first) == .unchanged)
        // Same values, ten minutes later.
        #expect(UsageQuotaLiveWriter.decide(self.reading(1600), after: first) == .written)
        // A changed percent, a changed reset, a window that appears or goes: written at once.
        #expect(UsageQuotaLiveWriter.decide(self.reading(1001, five: 2), after: first) == .written)
        #expect(UsageQuotaLiveWriter.decide(self.reading(1001, reset: 1_795_457_520), after: first) == .written)
        #expect(UsageQuotaLiveWriter.decide(self.reading(1001, five: nil), after: first) == .written)
        #expect(UsageQuotaLiveWriter.decide(self.reading(1001, reset: nil), after: first) == .written)
        // A reset time that moved by a few seconds is the same reset.
        #expect(UsageQuotaLiveWriter.decide(self.reading(1001, reset: 1_795_439_550), after: first) == .unchanged)
        // The same snapshot again, or an older one.
        #expect(UsageQuotaLiveWriter.decide(self.reading(1000, five: 5), after: first) == .stale)
        #expect(UsageQuotaLiveWriter.decide(self.reading(900, five: 5), after: first) == .stale)
        // Nothing to write.
        #expect(UsageQuotaLiveWriter.decide(self.reading(2000, five: nil, week: nil), after: first) == .empty)
    }

    @Test
    func `writer appends whole lines under the lock and resumes after a restart`() async throws {
        let url = try self.scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = UsageQuotaLiveWriter(url: url)
        #expect(await writer.record(self.reading(1000)) == .written)
        #expect(await writer.record(self.reading(1100)) == .unchanged)
        #expect(await writer.record(self.reading(1200, five: 3)) == .written)
        #expect(await writer.record(self.reading(1800, five: 3)) == .written)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(text.hasSuffix("\n"))
        #expect(lines.count == 4) // three lines and the empty rest after the last "\n"
        #expect(lines.dropLast().allSatisfy { Reading(jsonLine: $0) != nil })
        #expect(FileManager.default.fileExists(atPath: writer.lockURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)

        // A new writer (the app restarted) continues from the last line of the file.
        let again = UsageQuotaLiveWriter(url: url)
        #expect(await again.record(self.reading(1900, five: 3)) == .unchanged)
        #expect(await again.last == self.reading(1800, five: 3))

        // An unfinished last line (no "\n") is not taken as the last reading.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"ts\": 5000, \"source\"".utf8))
        try handle.close()
        #expect(UsageQuotaLiveWriter.lastLine(of: url) == self.reading(1800, five: 3))
    }

    @Test
    func `concurrent writes reach the file one at a time, in order, without duplicates`() async throws {
        let url = try self.scratchFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = UsageQuotaLiveWriter(url: url)
        // Readings handed over from many tasks at once, some of them the same values again.
        let readings = (0..<40).map { self.reading(1000 + $0, five: Double($0 / 2)) }
        let outcomes = await withTaskGroup(of: UsageQuotaLiveWriter.Outcome.self) { group in
            for reading in readings {
                group.addTask {
                    await writer.record(reading)
                }
            }
            var all: [UsageQuotaLiveWriter.Outcome] = []
            for await outcome in group {
                all.append(outcome)
            }
            return all
        }
        #expect(outcomes.count == 40)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").compactMap { Reading(jsonLine: $0) }
        #expect(!lines.isEmpty)
        #expect(lines.count == outcomes.filter { $0 == .written }.count)
        // Strictly newer each line, and never the same values twice in a row.
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.ts < $1.ts && !$1.hasSameValues(as: $0) })
    }
}
