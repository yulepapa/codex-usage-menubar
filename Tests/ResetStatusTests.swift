import Foundation

@main
enum ResetStatusTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CodexUsage-reset-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = ResetWatcherReader.date("2030-01-01T08:00:00+09:00")!
        let expiry = ResetWatcherReader.date("2030-01-01T09:15:00+09:00")!
        let credit = CreditInfo(availableCount: 1, earliestExpiresAt: Int(expiry.timeIntervalSince1970))
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: " + label) }
            passed += 1
            print("PASS: " + label)
        }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
        }
        func log(_ entries: [[String: Any]]) throws {
            let lines = try entries.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            try write("reset_credit_watcher.log", lines.joined(separator: "\n") + "\n")
        }
        let cycle: [String: Any] = ["time": "2030-01-01T07:59:00+09:00", "message": "watch cycle complete",
            "expiresAt": "2030-01-01T09:15:00+09:00", "nextCheckSeconds": 3600, "dryRun": false]
        func read() -> ResetWatcherSnapshot { ResetWatcherReader.read(directory: root, now: now) }
        check(read().health(at: now) == .unlinked, "missing watcher is unlinked, not healthy")
        try write("reset_credit_watcher.py", "CONSUME_BEFORE_SECONDS = 20 * 60\nMAX_DISCOVERY_SLEEP_SECONDS = 60 * 60\n")
        try write("reset_credit_watcher_state.json", "{\"consume\": {}, \"missed\": {}}")
        check(read().health(at: now) == .unknown, "configuration alone does not prove a running watcher")
        try log([cycle])
        let fresh = read()
        check(fresh.health(at: now) == .observed, "successful recent check is observed")
        check(fresh.plannedAttempt(credits: credit, at: now) == expiry.addingTimeInterval(-1200), "next attempt follows the local 20-minute policy")
        check(ResetSection.formatDate(expiry, timeZone: seoul) == "2030-01-01 09:15 GMT+9" || ResetSection.formatDate(expiry, timeZone: seoul) == "2030-01-01 09:15 KST", "expiry crosses UTC date boundary correctly in Asia/Seoul")
        check(ResetSection.formatDate(expiry.addingTimeInterval(-1200), timeZone: seoul).hasPrefix("2030-01-01 08:55"), "planned attempt uses Korean calendar date")
        check(fresh.plannedAttempt(credits: nil, at: now) == nil, "unavailable live data never creates a next-use estimate")
        check(fresh.plannedAttempt(credits: CreditInfo(availableCount: 0, earliestExpiresAt: nil), at: now) == nil, "no credits has no planned attempt")
        check(ResetSection.rows(credits: CreditInfo(availableCount: 0, earliestExpiresAt: nil), watcher: fresh, now: now).first == localized("Credits: none available", "보유: 없음"), "zero is displayed as none")
        check(ResetSection.rows(credits: nil, watcher: fresh, now: now).first == localized("Credits: unknown", "보유: 확인 불가"), "missing count is displayed as unknown")
        check(fresh.plannedAttempt(credits: CreditInfo(availableCount: 1, earliestExpiresAt: nil), at: now) == nil, "unknown expiry stays unknown")
        check(fresh.plannedAttempt(credits: CreditInfo(availableCount: 1, earliestExpiresAt: Int(expiry.timeIntervalSince1970) + 3600), at: now) == nil, "new or mismatched credit is not claimed to be scheduled")
        check(fresh.health(at: now.addingTimeInterval(4800)) == .stale, "overdue watcher records become stale")
        check(fresh.plannedAttempt(credits: credit, at: now.addingTimeInterval(4800)) == nil, "stale status cannot promise auto-use")
        check(fresh.plannedAttempt(credits: credit, at: expiry) == nil, "expired credits cannot be planned")
        check(ResetWatcherReader.numericConstant("X", in: "X = danger()") == nil, "unknown Python expressions are never evaluated")
        check(ResetWatcherReader.numericConstant("X", in: "X = 1\nX = 2") == nil, "ambiguous policy stays unknown")
        check(ResetWatcherReader.numericConstant("X", in: "X = 1\nX = changed()") == nil, "unsupported policy reassignment stays unknown")
        check(ResetWatcherReader.numericConstant("X", in: "X = 999999999999 * 999999999999") == nil, "unreasonable policy values are rejected")

        let states: [(String, String, ResetAttempt.Outcome)] = [
            ("reset", "", .used), ("alreadyRedeemed", ",\"lastError\":\"retained old error\"", .used),
            ("noCredit", "", .noCredit), ("", ",\"lastError\":\"sensitive error must not render\"", .failed),
            ("", ",\"lastOutcome\":\"nothingToReset\"", .waiting), ("unexpected", "", .unknown)
        ]
        for (outcome, extra, expected) in states {
            try write("reset_credit_watcher_state.json", "{\"consume\":{\"secret-credit-id\":{\"outcome\":\"\(outcome)\",\"lastAttemptAt\":\"2030-01-01T07:50:00+09:00\",\"idempotencyKey\":\"secret-key\"\(extra)}}}")
            check(read().lastAttempt?.outcome == expected, "maps outcome \(outcome.isEmpty ? expected.rawValue : outcome)")
            let rendered = ResetSection.rows(credits: credit, watcher: read(), now: now, timeZone: seoul).joined()
            check(!rendered.contains("secret-") && !rendered.contains("sensitive error"), "does not disclose raw state identifiers or errors")
        }
        try write("reset_credit_watcher_state.json", "{\"consume\":{\"x\":{\"outcome\":\"dry-run\",\"lastAttemptAt\":\"2030-01-01T07:50:00+09:00\"}}}")
        check(read().lastAttempt == nil, "dry-run is never reported as actual consumption")
        try write("reset_credit_watcher_state.json", "{\"missed\":{\"x\":\"2030-01-01T07:50:00+09:00\"}}")
        check(read().lastAttempt?.outcome == .expired, "missed record is expired with success unconfirmed")
        try write("reset_credit_watcher_state.json", "{\"consume\":{\"x\":{\"lastError\":\"old\",\"lastAttemptAt\":\"2030-01-01T07:30:00+09:00\",\"lastCheckedAt\":\"2030-01-01T07:50:00+09:00\",\"lastOutcome\":\"waiting-for-eligible-usage\"}}}")
        check(read().lastAttempt?.outcome == .waiting, "newer eligibility check supersedes an old error")
        try log([cycle, ["time":"2030-01-01T07:59:30+09:00", "message":"watch cycle failed", "error":"do not show this"]])
        check(read().health(at: now) == .failed, "query failure is distinct from successful consumption")
        check(read().plannedAttempt(credits: credit, at: now) == nil, "query failure suppresses planned-use claims")
        try log([["time":"2030-01-01T07:50:00+09:00", "message":"watch cycle failed"], cycle])
        check(read().health(at: now) == .observed, "later successful check clears query failure")
        try log([cycle, ["time":"2030-01-01T07:58:00+09:00", "message":"thread notification failed", "error":"private prompt"]])
        check(read().notificationFailure != nil && read().health(at: now) == .observed, "notification failure does not imply redemption failure")
        try log([cycle, ["time":"2030-01-01T07:58:00+09:00", "message":"thread notification failed"], ["time":"2030-01-01T07:59:00+09:00", "message":"thread report turn completed"]])
        check(read().notificationFailure == nil, "successful thread notification resolves its failure")
        try log([cycle, ["time":"2030-01-01T07:58:00+09:00", "message":"thread notification failed"], ["time":"2030-01-01T07:59:00+09:00", "message":"local notification delivered"]])
        check(read().notificationFailure != nil, "local notification cannot mask thread failure")
        try write("reset_credit_watcher_state.json", "{\"consume\":{\"x\":{\"outcome\":\"reset\",\"lastAttemptAt\":\"2030-01-01T07:50:00+09:00\"}}}")
        try log([cycle, ["time":"2030-01-01T07:50:00+09:00", "message":"consume attempt failed"]])
        check(read().lastAttempt?.outcome == .used, "confirmed success wins an error with the same second timestamp")
        var malformedCycle = cycle; malformedCycle["nextCheckSeconds"] = true
        try log([malformedCycle])
        check(read().health(at: now) == .unknown, "boolean schedule interval is malformed, not one second")
        try log([cycle])
        try write("reset_credit_watcher_state.json", "{")
        check(read().health(at: now) == .unknown, "partial or corrupt state fails closed")
        try write("reset_credit_watcher_state.json", "{}")
        var dryCycle = cycle; dryCycle["dryRun"] = true
        try log([dryCycle])
        check(read().health(at: now) == .unknown, "dry-run check does not establish actual watcher health")
        var futureCycle = cycle; futureCycle["time"] = "2031-01-01T07:59:00+09:00"
        try log([futureCycle])
        check(read().health(at: now) == .unknown, "future timestamps fail closed")
        try log([["time":"2030-01-01T07:59:00+09:00", "message":"no available reset credits"]])
        check(read().health(at: now) == .observed && read().observedExpiry == nil, "no-credit check is healthy but provides no expiry")
        try log([cycle])
        let validLog = try String(contentsOf: root.appendingPathComponent("reset_credit_watcher.log"), encoding: .utf8)
        try write("reset_credit_watcher.log", String(repeating: "한글잡음", count: 50000) + "\n" + validLog + "{partial")
        check(read().health(at: now) == .observed, "bounded log tail tolerates UTF-8 and partial last line")
        let names = try fm.contentsOfDirectory(atPath: root.path).sorted()
        let before = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        for _ in 0..<25 { _ = read(); _ = ResetSection.rows(credits: credit, watcher: read(), now: now) }
        let after = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let namesAfter = try fm.contentsOfDirectory(atPath: root.path).sorted()
        check(before == after && names == namesAfter, "repeated refreshes do not write state, logs, policy, or schedules")
        check(ResetWatcherReader.defaultDirectory(environment: [:], home: root).path == root.appendingPathComponent(".codex/automations/codex").path, "default discovery is scoped to the known watcher")
        let statePath = root.appendingPathComponent("reset_credit_watcher_state.json")
        try fm.removeItem(at: statePath)
        try fm.createSymbolicLink(at: statePath, withDestinationURL: root.appendingPathComponent("reset_credit_watcher.py"))
        check(read().readFailed, "symbolic links cannot redirect state reads to unrelated files")
        print("\(passed) reset status checks passed")
    }
}
