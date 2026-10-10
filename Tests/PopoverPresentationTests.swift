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
        // Individual credits are observed IDs, never synthesized from a count.
        state.attempts = [:]; state.availableCount = 3; state.checkedAt = now; state.lastError = nil
        let a = ResetCredit(id: "a", expiresAt: now.addingTimeInterval(600))
        let b = ResetCredit(id: "b", expiresAt: now.addingTimeInterval(1200))
        let c = ResetCredit(id: "c", expiresAt: now.addingTimeInterval(1200))
        state.inventory = [c, b, a, b]
        check(model().individualCredits.map(\.id) == ["a", "b", "c"], "expiry sort, ID tie-break and duplicate removal")
        var selection = CreditStackSelection()
        var cards = model().individualCredits
        check(selection.front(in: cards)?.id == "a", "default is earliest")
        selection.select("c", in: cards)
        check(selection.selectedID == "c" && selection.front(in: cards)?.id == "c", "explicit identity selects front")
        let earlier = ResetCredit(id: "new", expiresAt: now.addingTimeInterval(60))
        cards.insert(earlier, at: 0); selection.reconcile(cards)
        check(selection.front(in: cards)?.id == "c", "new earliest cannot replace explicit selection")
        selection.select("c", in: cards)
        check(selection.selectedID == nil && selection.front(in: cards)?.id == "new", "reclick selected returns current earliest")
        let newest = ResetCredit(id: "newest", expiresAt: now.addingTimeInterval(30))
        cards.insert(newest, at: 0); selection.reconcile(cards)
        check(selection.front(in: cards)?.id == "newest", "unselected default follows new earliest")
        selection.select("b", in: cards)
        cards.removeAll { $0.id == "b" }; selection.reconcile(cards)
        check(selection.selectedID == nil && selection.front(in: cards)?.id == "newest", "vanished selection resets to default")
        selection.select("c", in: cards)
        cards[cards.count - 1] = ResetCredit(id: "c", expiresAt: now.addingTimeInterval(45))
        cards.sort { $0.expiresAt < $1.expiresAt }; selection.reconcile(cards)
        check(selection.front(in: cards)?.id == "c" && selection.front(in: cards)?.expiresAt == now.addingTimeInterval(45), "changed expiry reconciles by identity")
        selection.select("missing", in: cards)
        check(selection.front(in: cards)?.id == "c", "unobserved IDs cannot be selected")
        selection.reconcile([])
        check(selection.front(in: []) == nil && selection.visible(in: []).isEmpty, "empty inventory clears selection")
        state.inventory = []
        check(model().individualCredits.isEmpty, "count-only never creates cards")
        state.inventory = [a, b, c]; state.availableCount = 2
        check(model().individualCredits.count == 3 && model().warnings.contains(localized("Credit count differs from details · refresh needed", "보유 수·개별 정보 불일치 · 새로고침 필요")), "mismatch retains known cards with explicit warning")
        state.availableCount = 0
        check(model().individualCredits.count == 3 && model().status == .noCredit, "conflicting inventory cannot override authoritative no-credit status")
        state.availableCount = nil
        check(model().individualCredits.count == 3 && model().count == nil, "observed cards cannot fabricate an unknown total")
        state.availableCount = 3; state.lastError = "queryFailed"
        check(model().individualCredits.isEmpty, "failed query cannot present cached cards as current")
        state.lastError = nil; state.checkedAt = now.addingTimeInterval(-181)
        check(model().individualCredits.isEmpty, "stale inventory cannot present current cards")
        state.checkedAt = now.addingTimeInterval(1)
        check(model().individualCredits.isEmpty, "future checked time is invalid")
        state.checkedAt = now; state.inventory = [a, ResetCredit(id: "", expiresAt: c.expiresAt), ResetCredit(id: "expired", expiresAt: now)]
        check(model().individualCredits.map(\.id) == ["a"], "invalid identity and expired credits are excluded")
        cards = (0..<100).map { ResetCredit(id: "card-\($0)", expiresAt: now.addingTimeInterval(Double(60 + $0))) }
        selection = CreditStackSelection()
        for index in 0..<100 {
            check(selection.index(in: cards) == index && selection.visible(in: cards).count == cards.count,
                  "every observed card remains individually visible at \(index)")
            selection.move(1, in: cards)
        }
        check(selection.index(in: cards) == 99, "next clamps at last card")
        for _ in 0..<100 { selection.move(-1, in: cards) }
        check(selection.index(in: cards) == 0, "previous reaches first card")
        state.inventory = [a, b, c]; state.availableCount = 3
        state.attempts["pending"] = Redemption(key: "private", expiresAt: b.expiresAt, attemptedAt: now, outcome: "pending")
        let pendingModel = model()
        selection.select("c", in: pendingModel.individualCredits)
        check(pendingModel.status == .pending && pendingModel.expiresAt == a.expiresAt, "selection never changes overall pending status or earliest policy expiry")
        check(!pendingModel.readout.joined().contains("private"), "selection never exposes ledger keys")
        // Weekly reference uses the returned interval, on the remaining axis.
        let duration = 10080.0 * 60
        let end = Int(now.timeIntervalSince1970 + duration * 0.4)
        func weekly(_ used: Int = 75, minutes: Int? = 10080, reset: Int? = nil) -> UsageWindow {
            UsageWindow(slot: "primary", usedPercent: used, windowDurationMins: minutes, resetsAt: reset ?? end)
        }
        let timed = weekly()
        let reference = WeeklyUsageReference.make(window: timed, now: now)!
        check(abs(reference.remainingTimeFraction - 0.4) < 0.000001, "reference follows time remaining, not elapsed")
        check(abs(reference.usageDeltaPercentagePoints - 15) < 0.000001, "faster usage is positive in usage percentage points")
        check(abs(WeeklyUsageReference.make(window: weekly(35), now: now)!.usageDeltaPercentagePoints + 25) < 0.000001,
              "slower usage is negative without a warning status")
        for (used, expected) in [(-20, -60.0), (0, -60.0), (100, 40.0), (120, 40.0)] {
            check(abs(WeeklyUsageReference.make(window: weekly(used), now: now)!.usageDeltaPercentagePoints - expected) < 0.000001,
                  "delta uses the same bounded usage as the painted bar")
        }
        check(WeeklyUsageReference.make(window: timed, now: Date(timeIntervalSince1970: Double(end) - duration))!.remainingTimeFraction == 1,
              "start boundary places marker at 100 percent")
        let beforeEnd = WeeklyUsageReference.make(window: timed, now: Date(timeIntervalSince1970: Double(end) - 1))!
        check(beforeEnd.remainingTimeFraction > 0 && beforeEnd.remainingTimeFraction < 1, "last second stays within the track")
        for time in [Double(end), Double(end) + 1, Double(end) - duration - 1] {
            check(WeeklyUsageReference.make(window: timed, now: Date(timeIntervalSince1970: time)) == nil,
                  "expired response and time before the supplied interval cannot show a reference")
        }
        for minutes: Int? in [nil, 0, -1, 300, 1440, Int.max] {
            check(WeeklyUsageReference.make(window: weekly(minutes: minutes), now: now) == nil,
                  "unknown, invalid or nonweekly duration does not assume seven days")
        }
        let missingReset = UsageWindow(slot: "primary", usedPercent: 30, windowDurationMins: 10080, resetsAt: nil)
        check(WeeklyUsageReference.make(window: missingReset, now: now) == nil, "missing reset hides reference")
        func timedModel(checked: Date? = now, failed: Bool = false, resetState: ResetEngineState? = nil,
                        window: UsageWindow = timed) -> PopoverPresentation {
            PopoverPresentation(snapshot: UsagePayload(bucketLabel: "Codex", windows: [window],
                credits: CreditInfo(availableCount: nil, earliestExpiresAt: nil)), checkedAt: checked, now: now,
                usageFailed: failed, reset: ResetMenuPresentation(title: "sample"), state: resetState)
        }
        check(timedModel().weeklyReference(for: timed) != nil, "ordinary returned duration needs no independent start field")
        check(timedModel(checked: nil).weeklyReference(for: timed) == nil, "unmeasured response hides reference")
        check(timedModel(failed: true).weeklyReference(for: timed) == nil, "failed query hides cached reference")
        check(timedModel(checked: now.addingTimeInterval(-390)).weeklyReference(for: timed) != nil, "freshness boundary includes configured grace")
        check(timedModel(checked: now.addingTimeInterval(-391)).weeklyReference(for: timed) == nil, "stale usage hides reference")
        check(timedModel(checked: now.addingTimeInterval(1)).weeklyReference(for: timed) == nil, "future snapshot is invalid")
        var resetState = ResetEngineState()
        resetState.attempts["synthetic-early-reset"] = Redemption(key: "synthetic", expiresAt: now,
            attemptedAt: now.addingTimeInterval(-30), outcome: "reset")
        check(timedModel(checked: now.addingTimeInterval(-60), resetState: resetState).weeklyReference(for: timed) == nil,
              "pre-reset snapshot cannot keep the previous reference")
        let newWindow = weekly(0, reset: Int(now.timeIntervalSince1970 + duration))
        let updated = timedModel(resetState: resetState, window: newWindow).weeklyReference(for: newWindow)!
        check(updated.remainingTimeFraction == 1 && updated.usageDeltaPercentagePoints == 0,
              "fresh early-reset response recomputes from its new returned reset time")
        check(timedModel(resetState: resetState).weeklyReference(for: timed) != nil,
              "fresh post-reset response retaining the old interval uses the actual returned fields")
        resetState.phase = "reset"; resetState.checkedAt = now.addingTimeInterval(-5)
        check(timedModel(checked: now.addingTimeInterval(-10), resetState: resetState).weeklyReference(for: timed) == nil,
              "usage read after intent but before the worker's post-result read is still obsolete")
        check(timedModel(resetState: resetState).weeklyReference(for: timed) != nil,
              "fresh UI read after the worker's post-result read restores the reference")
        let refreshedWindow = weekly(30, reset: Int(now.timeIntervalSince1970 + duration * 0.7))
        check(abs(timedModel(window: refreshedWindow).weeklyReference(for: refreshedWindow)!.remainingTimeFraction - 0.7) < 0.000001,
              "changed reset fields replace the previous marker")
        check(timedModel().readout.contains(where: { $0.contains("10080") && $0.contains(localized("Reference start", "기준 시작")) }),
              "details and accessibility explain the supplied duration and formula")
        print("\(passed) popover model checks passed")
    }
}
