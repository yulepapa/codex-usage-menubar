import Foundation

struct ResetMenuPresentation {
    var title: String
    var expiry: String?
    var warnings: [String] = []

    static func compactDate(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "M/d HH:mm zzz" : "yyyy/M/d HH:mm zzz"
        return formatter.string(from: date)
    }

    static func native(state: ResetEngineState, settings: ResetSettings, active: Bool, now: Date,
                       timeZone: TimeZone = .current) -> ResetMenuPresentation {
        let recent = state.checkedAt.map { (0...180).contains(now.timeIntervalSince($0)) } == true
        let credits = recent && state.lastError != "queryFailed" ? state.availableCount : nil
        var value = summary(count: credits, expiry: state.inventory.map(\.expiresAt).min(), now: now, timeZone: timeZone)
        if !active {
            value.warnings.append(localized("Reset worker needs setup", "자동 사용 실행기 확인 필요"))
        } else if (settings.autoUse || settings.reminders)
                    && state.workerSeenAt.map({ (0...180).contains(now.timeIntervalSince($0)) }) != true {
            value.warnings.append(localized("Reset worker has not checked recently", "감시기 최근 확인 없음"))
        }
        if state.lastError == "resultUnknown" || state.phase == "needsReview" {
            value.warnings.append(localized("Reset result unconfirmed · further use paused", "소비 결과 확인 필요 · 추가 사용 보류"))
        } else if state.lastError == "refreshFailed" {
            value.warnings.append(localized("Latest reset result needs refresh", "최근 처리 결과 재확인 필요"))
        } else if state.phase == "nothingToReset" {
            value.warnings.append(localized("Service: no eligible usage to reset", "서버에 초기화할 사용량 없음"))
        }
        if settings.reminders {
            switch state.notificationStatus {
            case "denied", "notDetermined":
                value.warnings.append(localized("Allow Mac notifications", "Mac 알림 허용 필요"))
            case "deliveryFailed":
                value.warnings.append(localized("Expiry notification delivery failed", "만료 알림 전달 실패"))
            case "unknown":
                value.warnings.append(localized("Check notification permission", "알림 권한 확인 필요"))
            default: break
            }
        }
        return value
    }

    static func legacy(credits: CreditInfo?, watcher: ResetWatcherSnapshot, now: Date,
                       timeZone: TimeZone = .current) -> ResetMenuPresentation {
        let expiry = credits?.earliestExpiresAt.map { Date(timeIntervalSince1970: Double($0)) }
        var value = summary(count: credits?.availableCount, expiry: expiry, now: now, timeZone: timeZone)
        switch watcher.health(at: now) {
        case .failed: value.warnings.append(localized("Reset watcher query failed", "리셋 감시기 조회 실패"))
        case .stale: value.warnings.append(localized("Reset watcher has not checked recently", "감시기 최근 확인 없음"))
        case .unknown where watcher.isPresent:
            value.warnings.append(localized("Check the reset watcher", "리셋 감시기 확인 필요"))
        default: break
        }
        if let result = watcher.lastAttempt, [.failed, .expired, .unknown].contains(result.outcome) {
            value.warnings.append(localized("Reset result needs verification", "자동 사용 결과 확인 필요"))
        }
        if watcher.notificationFailure != nil {
            value.warnings.append(localized("Expiry notification delivery failed", "만료 알림 전달 실패"))
        }
        return value
    }

    private static func summary(count: Int?, expiry: Date?, now: Date, timeZone: TimeZone) -> ResetMenuPresentation {
        guard let count, count >= 0 else {
            return ResetMenuPresentation(title: localized("Reset credits: unknown", "리셋권 확인 필요"))
        }
        var value = ResetMenuPresentation(title: localized("Reset credits: \(count)", "리셋권 \(count)장"))
        guard count > 0 else { return value }
        guard let expiry else {
            value.expiry = localized("Expiry: unknown", "만료 확인 필요")
            return value
        }
        value.expiry = localized("Expires ", "만료 ") + compactDate(expiry, now: now, timeZone: timeZone)
        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 {
            value.warnings.append(localized("Expired credit · refresh status", "만료된 권 · 상태 재확인 필요"))
        } else if remaining <= 3600 {
            let minutes = max(1, Int(ceil(remaining / 60)))
            value.warnings.append(localized("Expires soon · \(minutes) min left", "만료 임박 · \(minutes)분 남음"))
        }
        return value
    }
}

enum UsageMenuWarning {
    static func text(for error: Error) -> String {
        if let error = error as? UsageError {
            switch error {
            case .codexNotFound: return localized("Codex CLI needs installation", "Codex CLI 설치 필요")
            case .server(let message):
                let value = message.lowercased()
                if ["unauthorized", "authentication required", "not authenticated", "not logged in", "please log in", "sign in", "login required", "로그인"].contains(where: value.contains) {
                    return localized("Codex login required", "Codex 로그인 필요")
                }
            default: break
            }
        }
        return localized("Usage check failed · refresh to retry", "사용량 조회 실패 · 새로고침 필요")
    }
}
