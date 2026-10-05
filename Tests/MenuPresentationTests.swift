import Foundation

@main
enum MenuPresentationTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1893452400)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let settings = ResetSettings(autoUse: true, reminders: true)
        var state = ResetEngineState()
        state.checkedAt = now; state.workerSeenAt = now
        state.availableCount = 2; state.notificationStatus = "authorized"
        state.inventory = [ResetCredit(id: "synthetic-private-credit", expiresAt: now.addingTimeInterval(7200))]
        var passed = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); passed += 1 }
        func menu(_ config: ResetSettings? = nil, active: Bool = true) -> ResetMenuPresentation {
            ResetMenuPresentation.native(state: state, settings: config ?? settings, active: active, now: now, timeZone: zone)
        }
        check(menu().title == localized("Reset credits: 2", "리셋권 2장"), "count stays primary")
        check(menu().expiry?.contains("1/1 10:00 GMT+9") == true, "compact expiry preserves Seoul zone and date")
        check(menu().warnings.isEmpty, "normal monitoring has no status narration")
        state.attempts["synthetic-private-credit"] = Redemption(key: "synthetic-private-key", expiresAt: now,
            attemptedAt: now.addingTimeInterval(-86400), outcome: "reset")
        check(menu().warnings.isEmpty, "old success is not a persistent warning")
        check(!String(describing: menu()).contains("synthetic-private"), "identifiers never enter the presentation")
        state.inventory[0] = ResetCredit(id: "sample", expiresAt: now.addingTimeInterval(300))
        check(menu().warnings.contains(localized("Expires soon · 5 min left", "만료 임박 · 5분 남음")), "expiry urgency is visible")
        state.inventory[0] = ResetCredit(id: "sample", expiresAt: now.addingTimeInterval(-1))
        check(menu().warnings.contains(localized("Expired credit · refresh status", "만료된 권 · 상태 재확인 필요")), "expiry never implies success")
        state.inventory = []; state.availableCount = 0
        check(menu().expiry == nil, "zero credits have no invented expiry")
        state.checkedAt = now.addingTimeInterval(-181)
        check(menu().title == localized("Reset credits: unknown", "리셋권 확인 필요"), "stale count stays unknown")
        state.checkedAt = now.addingTimeInterval(1)
        check(menu().title == localized("Reset credits: unknown", "리셋권 확인 필요"), "future checks are not current")
        state.checkedAt = now; state.lastError = "queryFailed"
        check(menu().title == localized("Reset credits: unknown", "리셋권 확인 필요"), "failed query cannot look current")
        state.lastError = "resultUnknown"
        check(menu().warnings.contains(localized("Reset result unconfirmed · further use paused", "소비 결과 확인 필요 · 추가 사용 보류")), "unknown result remains actionable")
        state.lastError = nil; state.workerSeenAt = now.addingTimeInterval(-181)
        check(menu().warnings.contains(localized("Reset worker has not checked recently", "감시기 최근 확인 없음")), "stale worker is not hidden")
        state.workerSeenAt = now; state.notificationStatus = "denied"
        check(menu().warnings.contains(localized("Allow Mac notifications", "Mac 알림 허용 필요")), "enabled permission failure is visible")
        check(menu(ResetSettings(autoUse: true, reminders: false)).warnings.isEmpty, "disabled reminders do not warn")
        check(menu(active: false).warnings.contains(localized("Reset worker needs setup", "자동 사용 실행기 확인 필요")), "handoff issue is visible")
        let nextYear = Calendar(identifier: .gregorian).date(byAdding: .year, value: 1, to: now)!
        check(ResetMenuPresentation.compactDate(nextYear, now: now, timeZone: zone).hasPrefix("2031/"), "different year is explicit")
        check(UsageMenuWarning.text(for: UsageError.server("not authenticated")) == localized("Codex login required", "Codex 로그인 필요"), "known login requirement is explicit")
        check(UsageMenuWarning.text(for: UsageError.server("synthetic-private-error")) == localized("Usage check failed · refresh to retry", "사용량 조회 실패 · 새로고침 필요"), "raw error does not enter main screen")
        check(UsageMenuWarning.text(for: UsageError.codexNotFound) == localized("Codex CLI needs installation", "Codex CLI 설치 필요"), "missing CLI stays actionable")
        print("\(passed) compact menu checks passed")
    }
}
