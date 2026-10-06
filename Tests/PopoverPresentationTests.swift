import Foundation

@main
enum PopoverPresentationTests {
    static func main() {
        var passed = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); passed += 1 }
        let now = Date(timeIntervalSince1970: 1791244800)
        let five = UsageWindow(slot: "primary", usedPercent: 82, windowDurationMins: 300, resetsAt: nil)
        let week = UsageWindow(slot: "secondary", usedPercent: 58, windowDurationMins: 10080, resetsAt: 1791590400)
        var state = ResetEngineState()
        state.checkedAt = now; state.workerSeenAt = now; state.availableCount = 2
        state.inventory = [ResetCredit(id: "synthetic", expiresAt: now.addingTimeInterval(1200))]
        state.notificationStatus = "authorized"
        var settings = ResetSettings(autoUse: true, reminders: true)
        func model(_ windows: [UsageWindow] = [five, week], failed: Bool = false, active: Bool = true) -> PopoverPresentation {
            let snapshot = UsagePayload(bucketLabel: "Any plan", windows: windows,
                credits: CreditInfo(availableCount: 99, earliestExpiresAt: 0))
            let reset = ResetMenuPresentation.native(state: state, settings: settings, active: active, now: now, timeZone: PopoverPresentation.seoul)
            return PopoverPresentation(snapshot: snapshot, checkedAt: now, now: now, usageFailed: failed,
                reset: reset, state: state, settings: settings, active: active, native: true)
        }
        check(model().windows.count == 2 && model([week]).windows.count == 1 && model([five]).windows.count == 1, "count follows response, not plan")
        check(model([week, five]).windows[0].windowDurationMins == 300, "response order normalized")
        check(model([]).windows.isEmpty, "missing windows stay absent")
        check(model([], failed: true).usageFailed, "failed and empty remain distinguishable")
        check(model().count == 2, "native state overrides unrelated account credit snapshot")
        check(model().autoUse && model().reminders && model().canEdit, "settings originate in input")
        check(model().readout.contains(where: { $0.contains(localized("Unknown", "시각 미제공")) }), "absent reset timestamp stays unknown")
        check(PopoverPresentation.date(now) == "10/06 09:00 KST", "Seoul date across UTC boundary")
        check(PopoverPresentation.date(now.addingTimeInterval(-3600)) == "10/06 08:00 KST", "fixed Seoul zone")
        for remaining in [0, 8, 30, 100] {
            let window = UsageWindow(slot: "primary", usedPercent: 100 - remaining, windowDurationMins: 300, resetsAt: nil)
            check(model([window]).status == .ready, "percent \(remaining) cannot gate eligibility")
        }
        check(model([]).status == .ready, "no windows cannot gate eligibility")
        for (seconds, expected): (Double, PopoverPresentation.Status) in [(1201, .waiting), (1200, .ready), (1199, .ready), (1, .ready), (0, .expired), (-1, .expired)] {
            state.inventory[0] = ResetCredit(id: "synthetic", expiresAt: now.addingTimeInterval(seconds))
            check(model().status == expected, "time-only boundary \(seconds)")
        }
        state.inventory[0] = ResetCredit(id: "synthetic", expiresAt: now.addingTimeInterval(600))
        let expiry = state.inventory[0].expiresAt
        state.attempts["synthetic"] = Redemption(key: "private-key", expiresAt: expiry, attemptedAt: now.addingTimeInterval(-60), outcome: "nothingToReset")
        state.phase = "checking"
        check(model().status == .nothingToReset, "durable warning survives checking phase")
        settings.autoUse = false
        check(model().status == .nothingToReset, "disabled auto-use does not conceal known result")
        state.lastError = "queryFailed"
        check(model().status == .failed && model().count == nil, "query failure is explicit, count unknown")
        check(model().readout.contains(localized("Service: no eligible usage to reset", "서버에 초기화할 사용량 없음")), "prior no-op warning preserved in details on failure")
        state.lastError = "refreshFailed"
        check(model().status == .failed, "refresh failure above no-op")
        state.attempts["pending"] = Redemption(key: "pending-key", expiresAt: expiry, attemptedAt: now, outcome: "pending")
        check(model(failed: true).status == .pending, "pending above all failures and auto-use off")
        check(!model().readout.joined().contains("private-key") && !model().readout.joined().contains("pending-key"), "private ledger keys never rendered")
        state.attempts.removeValue(forKey: "pending"); state.lastError = nil
        state.inventory[0] = ResetCredit(id: "synthetic", expiresAt: expiry.addingTimeInterval(60))
        check(model().status != .nothingToReset, "changed expiry cannot revive prior no-op")
        state.inventory[0] = ResetCredit(id: "synthetic", expiresAt: expiry)
        state.availableCount = 0
        check(model().status == .noCredit && model().expiresAt == nil, "zero credits never have invented expiry")
        state.availableCount = nil
        check(model().status == .unknown, "unknown count never becomes zero")
        state.availableCount = 2; state.attempts = [:]
        for age in [181.0, -1.0] {
            state.checkedAt = now.addingTimeInterval(-age)
            check(model().count == nil && model().expiresAt == nil, "stale or future count is unknown")
        }
        state.checkedAt = now
        check(model().status == .off, "saved off is off")
        settings.autoUse = true; settings.reminders = false
        check(!model().reminders, "saved reminder off is off")
        check(!model(active: false).canEdit && model(active: false).status == .setup, "inactive ownership disables controls")
        state.workerSeenAt = now.addingTimeInterval(-181)
        check(model().status == .setup, "stale worker is not monitoring")
        state.workerSeenAt = now
        state.attempts["old"] = Redemption(key: "synthetic", expiresAt: expiry, attemptedAt: now, outcome: "reset")
        state.availableCount = 0
        check(model().status == .used, "confirmed recent result shown separately from empty inventory")
        state.attempts["old"]?.outcome = "alreadyRedeemed"
        check(model().status == .used, "already-redeemed is a confirmed result")
        state.availableCount = 2; state.attempts["old"]?.outcome = "noCredit"
        check(model().status == .noCredit, "service noCredit stays explicit even before inventory catches up")
        state.availableCount = 0
        state.attempts["old"]?.attemptedAt = now.addingTimeInterval(-301)
        check(model().status == .noCredit, "old success does not imply new use")
        state.availableCount = 2; state.attempts = [:]; state.inventory = []
        check(model().expiresAt == nil && model().status == .unknown, "count alone cannot invent expiry")
        check(model().expiryValue == localized("Unknown", "미제공"), "unknown expiry labeled")
        let unreadable = PopoverPresentation(snapshot: nil, checkedAt: nil, now: now,
            reset: ResetMenuPresentation(title: "Unknown"), native: true)
        check(!unreadable.canEdit && unreadable.count == nil && unreadable.status == .failed, "unreadable state fails closed")
        print("\(passed) popover model checks passed")
    }
}
