import Foundation
import Darwin

enum SimulatedResetError: Error { case responseTimeout }

// The fake server records a reset before losing its response. A repeated key
// confirms the original result without performing another logical redemption.
final class ResponseLossResetService: ResetService {
    let payload: UsagePayload
    var calls: [(String, String)] = []
    var redeemed: [String: String] = [:]
    init(payload: UsagePayload) { self.payload = payload }
    func read() throws -> UsagePayload { payload }
    func consume(credit: ResetCredit, key: String) throws -> String {
        calls.append((credit.id, key))
        if redeemed[key] == credit.id { return "alreadyRedeemed" }
        redeemed[key] = credit.id
        throw SimulatedResetError.responseTimeout
    }
}

final class FakeResetService: ResetService {
    var snapshots: [UsagePayload] = []
    var fallback: UsagePayload!
    var calls: [(String, String)] = []
    var outcome = "reset"
    var failRead = false
    var failConsume = false
    var beforeConsume: (() throws -> Void)?
    func read() throws -> UsagePayload {
        if failRead { throw ResetStorageError.invalid }
        return snapshots.isEmpty ? fallback : snapshots.removeFirst()
    }
    func consume(credit: ResetCredit, key: String) throws -> String {
        try beforeConsume?(); calls.append((credit.id, key))
        if failConsume { throw ResetStorageError.invalid }
        return outcome
    }
}

final class FakeResetNotifier: ResetNotifier {
    var status = "authorized"
    var delivered: [Int] = []
    var cleared: [String] = []
    func send(credit: ResetCredit, milestone: Int, now: Date) throws { delivered.append(milestone) }
    func clear(credit: ResetCredit) { cleared.append(credit.id) }
}

@main enum ResetEngineTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lease-probe" {
            do {
                let lease = try ResetLease(url: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("worker.lock"))
                withExtendedLifetime(lease) {}
                exit(2)
            } catch ResetStorageError.locked { exit(0) }
            catch { exit(3) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsage-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiry = now.addingTimeInterval(3600)
        let credit = ResetCredit(id: "synthetic-credit", expiresAt: expiry)
        let store = ResetStore(directory: root)
        let service = FakeResetService(); let notifier = FakeResetNotifier()
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }; passed += 1; print("PASS: " + message)
        }
        func snapshot(primary: Int = 95, weekly: Int = 0, core: Bool = true, credits: [ResetCredit]? = nil) -> UsagePayload {
            let values = credits ?? [credit]
            return UsagePayload(bucketLabel: "Codex", windows: [
                UsageWindow(slot: "primary", usedPercent: primary, windowDurationMins: 300, resetsAt: nil),
                UsageWindow(slot: "secondary", usedPercent: weekly, windowDurationMins: 10080, resetsAt: nil)
            ], credits: CreditInfo(availableCount: values.count, earliestExpiresAt: values.map { Int($0.expiresAt.timeIntervalSince1970) }.min()), resetCredits: values, isCoreCodex: core)
        }
        func reset() throws -> ResetEngine {
            try store.write("settings.json", ResetSettings(autoUse: true, reminders: true))
            try store.write("ownership.json", ["active": true])
            try store.write("state.json", ResetEngineState())
            service.fallback = snapshot(); service.snapshots = []; service.calls = []; service.outcome = "reset"
            service.failRead = false; service.failConsume = false; service.beforeConsume = nil
            notifier.delivered = []; notifier.cleared = []; notifier.status = "authorized"
            return ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        }
        var engine = try reset()
        try engine.tick(active: false)
        check(service.calls.isEmpty && notifier.delivered.isEmpty, "standby performs only read-only readiness checks")
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered == [3600], "one hour reminder without early consumption")
        try engine.tick(active: true)
        check(notifier.delivered == [3600], "repeated cycle does not duplicate reminder")
        now = expiry.addingTimeInterval(-1200)
        service.fallback = snapshot(primary: 1)
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered == [3600,1200], "small primary usage is not eligible but twenty minute reminder is sent")
        now = expiry.addingTimeInterval(-300)
        engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        try engine.tick(active: true); try engine.tick(active: true)
        check(notifier.delivered == [3600,1200,300], "restart preserves all notification milestones")
        now = expiry.addingTimeInterval(-240)
        engine = try reset(); service.fallback = snapshot(primary: 0)
        try engine.tick(active: true)
        check(notifier.delivered == [300], "wake inside final five minutes sends only closest reminder")
        now = expiry
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered == [300], "expired credit is not redeemed or reminded")
        now = expiry.addingTimeInterval(-1100)
        engine = try reset(); service.fallback = snapshot(primary: 0, weekly: 90)
        service.beforeConsume = {
            let pending = try store.state().attempts[credit.id]
            check(pending?.outcome == "pending" && pending?.key.isEmpty == false, "idempotency intent is durable before RPC")
        }
        try engine.tick(active: true)
        check(service.calls.count == 1 && notifier.delivered.isEmpty, "weekly threshold qualifies even with zero primary usage; successful use suppresses reminder")
        let used = try store.state()
        check(used.attempts[credit.id]?.outcome == "reset", "confirmed reset is recorded")
        try engine.tick(active: true)
        check(service.calls.count == 1, "repeated cycle cannot redeem a completed credit twice")
        engine = try reset(); service.fallback = snapshot(primary: 89, weekly: 89)
        try engine.tick(active: true)
        check(service.calls.isEmpty, "eleven percent remaining is not eligible")
        engine = try reset(); service.fallback = snapshot(core: false)
        try engine.tick(active: true)
        check(service.calls.isEmpty, "other metered buckets cannot authorize a core reset")
        engine = try reset(); service.snapshots = [snapshot(), snapshot(primary: 0)]
        try engine.tick(active: true)
        check(service.calls.isEmpty, "fresh eligibility supersedes earlier exhausted snapshot")
        engine = try reset(); service.snapshots = [snapshot(), snapshot(credits: [])]
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered.isEmpty, "manual use between reads suppresses both consumption and reminder")
        engine = try reset(); service.failRead = true
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered.isEmpty, "query failure cannot trigger actions")
        engine = try reset()
        try store.updateSettings { $0.autoUse = false }
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered == [1200], "auto-use off keeps separately enabled reminders")
        engine = try reset()
        try store.write("ownership.json", ["active": false])
        try engine.tick(active: true)
        check(service.calls.isEmpty, "ownership must still be active immediately before dispatch")
        engine = try reset()
        engine.save = { _ in throw ResetStorageError.invalid }
        do { try engine.tick(active: true) } catch {}
        check(service.calls.isEmpty, "persistence failure prevents consumption")
        engine = try reset(); service.failConsume = true
        try engine.tick(active: true)
        let firstKey = service.calls.first!.1
        check(notifier.delivered == [1200], "uncertain consume result retains a single expiry reminder")
        now = now.addingTimeInterval(181)
        engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        service.failConsume = false; service.outcome = "alreadyRedeemed"
        try engine.tick(active: true)
        check(service.calls.count == 2 && service.calls.last!.1 == firstKey, "uncertain result retries same key after restart")
        check(tryState(store).attempts[credit.id]?.outcome == "alreadyRedeemed", "idempotent success is terminal")
        engine = try reset(); service.failConsume = true
        try engine.tick(active: true)
        service.failConsume = false; service.fallback = snapshot(credits: [])
        now = now.addingTimeInterval(181)
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).phase == "needsReview", "missing credit after uncertain RPC requires review instead of assuming success")
        engine = try reset(); service.outcome = "nothingToReset"
        try engine.tick(active: true)
        let noResetKey = service.calls.first!.1
        now = now.addingTimeInterval(181)
        try engine.tick(active: true)
        check(service.calls.last!.1 != noResetKey && tryState(store).attempts[credit.id]?.outcome == "nothingToReset", "known no-op can create a later logical attempt without claiming success")
        engine = try reset(); service.outcome = "noCredit"
        try engine.tick(active: true); try engine.tick(active: true)
        check(service.calls.count == 1 && notifier.delivered.isEmpty, "noCredit is terminal and stops reminders")
        engine = try reset(); notifier.status = "denied"; service.fallback = snapshot(primary: 0)
        try engine.tick(active: true)
        check(notifier.delivered.isEmpty && tryState(store).notificationStatus == "denied", "denied notification permission is visible without bypass")

        let second = ResetCredit(id: "synthetic-second", expiresAt: expiry.addingTimeInterval(10))
        now = expiry.addingTimeInterval(-1100)
        engine = try reset(); service.fallback = snapshot(credits: [credit, second]); service.failConsume = true
        try engine.tick(active: true)
        let pendingKey = service.calls.first!.1
        now = now.addingTimeInterval(60); service.failConsume = false
        engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).attempts[second.id] == nil,
              "retry delay blocks another credit's new consumption after restart")
        check(tryState(store).attempts[credit.id]?.key == pendingKey && tryState(store).lastError == "resultUnknown",
              "deferred pending intent preserves its key and review warning")
        check(tryState(store).reminders[second.id]?.contains(1200) == true,
              "pending recovery does not suppress another credit's expiry reminder")
        now = now.addingTimeInterval(121); service.outcome = "alreadyRedeemed"
        try engine.tick(active: true)
        check(service.calls.count == 2 && service.calls.last!.0 == credit.id && service.calls.last!.1 == pendingKey,
              "eligible recovery retries only the uncertain credit with its original key")
        check(tryState(store).lastError == nil && tryState(store).attempts[credit.id]?.outcome == "alreadyRedeemed",
              "authoritative replay confirmation clears the unresolved warning")
        try engine.tick(active: true)
        check(service.calls.count == 2, "confirmed recovery starts the existing cooldown before another credit")

        now = expiry.addingTimeInterval(-1100)
        engine = try reset(); service.fallback = snapshot(credits: [credit, second]); service.failConsume = true
        try engine.tick(active: true)
        service.failConsume = false; now = now.addingTimeInterval(181)
        service.snapshots = [snapshot(credits: [credit, second]), snapshot(credits: [second])]
        service.fallback = snapshot(credits: [second])
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).phase == "needsReview",
              "uncertain credit disappearing during fresh read blocks new consumption in the same cycle")
        engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).attempts[credit.id]?.outcome == "pending",
              "absence after restart cannot be inferred as successful redemption")

        now = expiry.addingTimeInterval(-1100)
        engine = try reset(); service.fallback = snapshot(credits: [credit, second]); service.failConsume = true
        try engine.tick(active: true)
        service.failConsume = false; now = now.addingTimeInterval(181)
        service.snapshots = [snapshot(credits: [credit, second]), snapshot(primary: 0, credits: [credit, second])]
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).lastError == "resultUnknown",
              "fresh ineligibility preserves pending work and blocks another credit")
        let shifted = ResetCredit(id: credit.id, expiresAt: expiry.addingTimeInterval(30))
        service.fallback = snapshot(credits: [shifted, second])
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).attempts[credit.id]?.expiresAt == expiry,
              "changed expiry cannot replace a pending intent or authorize another credit")
        service.failRead = true
        try engine.tick(active: true)
        check(service.calls.count == 1 && tryState(store).attempts[credit.id]?.outcome == "pending",
              "read timeout cannot discard pending work or consume another credit")

        now = expiry.addingTimeInterval(-1100)
        engine = try reset(); service.fallback = snapshot(credits: [credit, second]); service.outcome = "alreadyRedeemed"
        let third = ResetCredit(id: "synthetic-third", expiresAt: expiry.addingTimeInterval(-10))
        service.fallback = snapshot(credits: [third, credit, second])
        var multiple = try store.state()
        multiple.attempts[credit.id] = Redemption(key: "synthetic-old-A", expiresAt: expiry, attemptedAt: now.addingTimeInterval(-181), outcome: "pending")
        multiple.attempts[second.id] = Redemption(key: "synthetic-old-B", expiresAt: second.expiresAt, attemptedAt: now.addingTimeInterval(-181), outcome: "pending")
        try store.write("state.json", multiple)
        try engine.tick(active: true)
        check(service.calls.count == 1 && service.calls.first!.0 == credit.id && service.calls.first!.1 == "synthetic-old-A",
              "multiple pending intents exclude an earlier-expiring unattempted credit")
        check(tryState(store).lastError == "resultUnknown" && tryState(store).attempts[second.id]?.outcome == "pending",
              "confirming one pending result keeps the remaining uncertainty visible")
        now = now.addingTimeInterval(301)
        engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        try engine.tick(active: true)
        check(service.calls.count == 2 && service.calls.last!.0 == second.id && service.calls.last!.1 == "synthetic-old-B",
              "multiple-intent recovery preserves each stored key across restart and cooldown")

        now = expiry.addingTimeInterval(-1100)
        engine = try reset()
        let loss = ResponseLossResetService(payload: snapshot(credits: [credit, second]))
        engine = ResetEngine(store: store, service: loss, notifier: notifier, clock: { now })
        try engine.tick(active: true)
        now = now.addingTimeInterval(60)
        engine = ResetEngine(store: store, service: loss, notifier: notifier, clock: { now })
        try engine.tick(active: true)
        check(loss.calls.count == 1 && loss.redeemed.count == 1,
              "server reset followed by response timeout does not consume a second credit")
        now = now.addingTimeInterval(121)
        try engine.tick(active: true)
        check(loss.calls.count == 2 && loss.calls[0].1 == loss.calls[1].1 && loss.redeemed.count == 1,
              "response-loss recovery confirms the same logical redemption without a new reset")
        check(tryState(store).attempts[credit.id]?.outcome == "alreadyRedeemed" && tryState(store).attempts[second.id] == nil,
              "fresh read alone is not confirmation; authoritative same-key response resolves pending work")

        // A pending intent may never resolve through inventory alone. Its
        // consumption hold is independent of alerts for other available credits.
        for scenario in ["missing", "expired", "changed"] {
            for autoUse in [false, true] {
                now = expiry.addingTimeInterval(-600)
                engine = try reset()
                try store.updateSettings { $0.autoUse = autoUse }
                let pendingExpiry = scenario == "expired" ? now.addingTimeInterval(-1) : expiry
                let changed = ResetCredit(id: credit.id, expiresAt: scenario == "changed" ? expiry.addingTimeInterval(30) : pendingExpiry)
                let available = ResetCredit(id: "synthetic-alert", expiresAt: now.addingTimeInterval(300))
                service.fallback = snapshot(credits: scenario == "missing" ? [available] : [changed, available])
                var uncertain = try store.state()
                uncertain.attempts[credit.id] = Redemption(key: "synthetic-held", expiresAt: pendingExpiry,
                                                          attemptedAt: now.addingTimeInterval(-181), outcome: "pending")
                try store.write("state.json", uncertain)
                try engine.tick(active: true)
                check(service.calls.isEmpty && tryState(store).attempts[credit.id]?.key == "synthetic-held"
                        && tryState(store).attempts[credit.id]?.outcome == "pending",
                      "\(scenario) pending credit holds all consumption with autoUse=\(autoUse)")
                check(tryState(store).reminders[available.id]?.contains(300) == true,
                      "\(scenario) pending credit allows another available credit's due reminder with autoUse=\(autoUse)")
                let delivered = notifier.delivered.count
                engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
                try engine.tick(active: true)
                check(service.calls.isEmpty && notifier.delivered.count == delivered,
                      "\(scenario) pending hold and reminder deduplication survive restart with autoUse=\(autoUse)")
            }
        }

        now = expiry.addingTimeInterval(-250)
        engine = try reset()
        let alertAfterRead = ResetCredit(id: "synthetic-fresh-alert", expiresAt: now.addingTimeInterval(300))
        var disappearing = try store.state()
        disappearing.attempts[credit.id] = Redemption(key: "synthetic-fresh-held", expiresAt: expiry,
                                                     attemptedAt: now.addingTimeInterval(-181), outcome: "pending")
        try store.write("state.json", disappearing)
        service.snapshots = [snapshot(credits: [credit, alertAfterRead]), snapshot(credits: [alertAfterRead])]
        service.fallback = snapshot(credits: [alertAfterRead])
        try engine.tick(active: true)
        check(service.calls.isEmpty && tryState(store).attempts[credit.id]?.key == "synthetic-fresh-held",
              "pending disappearance during fresh read keeps the saved intent and blocks consumption")
        check(tryState(store).reminders[alertAfterRead.id]?.contains(300) == true,
              "pending disappearance during fresh read still delivers another credit's due reminder")
        let deliveredAfterRead = notifier.delivered.count
        engine = ResetEngine(store: store, service: service, notifier: notifier, clock: { now })
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered.count == deliveredAfterRead && tryState(store).phase == "needsReview",
              "fresh-read disappearance preserves hold and reminder deduplication across restart")
        try store.updateSettings { $0.reminders = false }
        try engine.tick(active: true)
        check(service.calls.isEmpty && notifier.delivered.count == deliveredAfterRead,
              "disabled reminder setting remains respected during the pending hold")

        let lease = try ResetLease(url: root.appendingPathComponent("worker.lock"))
        do { _ = try ResetLease(url: root.appendingPathComponent("worker.lock")); check(false, "second worker lock") }
        catch { check(true, "second worker cannot acquire the execution lease") }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        probe.arguments = ["--lease-probe", root.path]
        try probe.run(); probe.waitUntilExit()
        check(probe.terminationStatus == 0, "separate worker process cannot acquire the held execution lease")
        withExtendedLifetime(lease) {}
        let agent = root.appendingPathComponent("worker.plist")
        try store.write("worker.json", ["label":"test.worker", "executable":"/test/app", "launchAgent":agent.path])
        let legacyAgent: [String: Any] = ["Label":"test.worker", "ProgramArguments":["python3","legacy.py"]]
        try PropertyListSerialization.data(fromPropertyList: legacyAgent, format: .xml, options: 0).write(to: agent)
        let legacyActive = try store.active()
        check(!legacyActive, "staged ownership cannot activate while LaunchAgent still points to legacy code")
        let nativeAgent: [String: Any] = ["Label":"test.worker", "ProgramArguments":["/test/app","--reset-worker"]]
        try PropertyListSerialization.data(fromPropertyList: nativeAgent, format: .xml, options: 0).write(to: agent)
        let nativeActive = try store.active()
        check(nativeActive, "ownership activates only after the same LaunchAgent is repointed")
        print("\(passed) reset engine checks passed")
    }
    static func tryState(_ store: ResetStore) -> ResetEngineState { try! store.state() }
}
