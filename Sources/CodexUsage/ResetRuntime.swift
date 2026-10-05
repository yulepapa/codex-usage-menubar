import Foundation
import UserNotifications
import CryptoKit

final class LiveResetService: ResetService {
    private let client = CodexAppServerClient()
    func read() throws -> UsagePayload { try client.fetch() }
    func consume(credit: ResetCredit, key: String) throws -> String { try client.consume(creditID: credit.id, key: key) }
}

final class MacResetNotifier: ResetNotifier {
    private let center = UNUserNotificationCenter.current()
    var status: String {
        let semaphore = DispatchSemaphore(value: 0)
        var value = "unknown"
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: value = "authorized"
            case .denied: value = "denied"
            case .notDetermined: value = "notDetermined"
            @unknown default: value = "unknown"
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return value
    }
    private func identifier(_ credit: ResetCredit, _ milestone: Int) -> String {
        let digest = SHA256.hash(data: Data(credit.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return "reset-" + digest + "-" + String(milestone)
    }
    func send(credit: ResetCredit, milestone: Int, now: Date) throws {
        let content = UNMutableNotificationContent()
        content.title = localized("Codex reset credit expires soon", "Codex 리셋권 만료 임박")
        let minutes = max(1, Int(ceil(credit.expiresAt.timeIntervalSince(now) / 60)))
        content.body = localized("A tracked reset expires in \(minutes) min. ", "리셋권 만료 시각이 \(minutes)분 뒤입니다. ")
            + ResetSection.formatDate(credit.expiresAt)
            + localized(" · Check auto-use results in the menu bar.", " · 메뉴바에서 자동 사용 결과를 확인하세요.")
        content.sound = .default
        content.threadIdentifier = "codex-reset-expiry"
        let request = UNNotificationRequest(identifier: identifier(credit, milestone), content: content, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        center.add(request) { error in failure = error; semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw ResetStorageError.invalid }
        if let failure { throw failure }
    }
    func clear(credit: ResetCredit) {
        let ids = [3600, 1200, 300].map { identifier(credit, $0) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

final class ResetNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ResetNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum ResetWorker {
    static func run() -> Int32 {
        let store = ResetStore.standard
        do {
            let definition = try store.read("worker.json", as: [String: String].self, fallback: [:])
            guard let label = definition["label"],
                  ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label,
                  definition["executable"] == Bundle.main.executableURL?.path else { return 78 }
            try store.prepare()
            let lease = try ResetLease(url: store.directory.appendingPathComponent("worker.lock"))
            let engine = ResetEngine(store: store, service: LiveResetService(), notifier: MacResetNotifier())
            defer { withExtendedLifetime(lease) {} }
            var lastActive: Bool?
            var lastWake: Double?
            var next = Date.distantPast
            while true {
                let active = try store.active()
                let wake = try store.read("wake.json", as: [String: Double].self, fallback: [:])["at"]
                if Date() >= next || active != lastActive || wake != lastWake {
                    try engine.tick(active: active)
                    lastActive = active
                    lastWake = wake
                    next = Date().addingTimeInterval(active ? 60 : 10)
                }
                // Recheck absolute time and ownership each second. Wake and ownership
                // activation trigger evaluation without depending on a running menu UI.
                Thread.sleep(forTimeInterval: 1)
            }
        } catch ResetStorageError.locked { return 73 }
        catch { return 74 } // No credential-bearing error text is logged.
    }
}

enum NativeResetSection {
    static func rows(store: ResetStore, now: Date) -> [String] {
        do {
            let state = try store.state()
            let active = try store.active()
            var rows: [String] = []
            if !active { rows.append(localized("Worker: staged, awaiting handoff", "실행기: 인계 대기")) }
            else if state.workerSeenAt.map({ now.timeIntervalSince($0) <= 180 }) != true {
                rows.append(localized("Worker: no recent check", "실행기: 최근 확인 없음"))
            } else { rows.append(localized("Worker: background monitoring", "실행기: 백그라운드 감시 중")) }
            if let count = state.availableCount, state.checkedAt.map({ now.timeIntervalSince($0) <= 180 }) == true, state.lastError != "queryFailed" {
                rows.append(localized("Available credits: \(count)", "보유 리셋권: \(count)장"))
                if let next = state.inventory.filter({ $0.expiresAt > now }).min(by: { $0.expiresAt < $1.expiresAt }) {
                    rows.append(localized("Expiry: ", "만료: ") + ResetSection.formatDate(next.expiresAt))
                    if try store.settings().autoUse {
                        let planned = next.expiresAt.addingTimeInterval(-1200)
                        rows.append(planned > now ? localized("Planned attempt: ", "자동 사용 시도: ") + ResetSection.formatDate(planned)
                            : localized("Awaiting eligible usage or result", "사용 조건 또는 처리 결과 확인 중"))
                    }
                }
            } else { rows.append(localized("Credits: unknown", "보유: 확인 불가")) }
            if let last = state.attempts.values.max(by: { $0.attemptedAt < $1.attemptedAt }) {
                let result: String
                switch last.outcome {
                case "reset", "alreadyRedeemed": result = localized("Used", "사용 완료")
                case "noCredit": result = localized("No credit", "사용할 권 없음")
                case "nothingToReset": result = localized("Waiting for eligibility", "사용 조건 대기")
                default: result = localized("Result unconfirmed", "결과 미확인")
                }
                rows.append(localized("Last result: ", "최근 결과: ") + result + " · " + ResetSection.formatDate(last.attemptedAt))
            }
            if let error = state.lastError {
                rows.append(error == "resultUnknown" ? localized("Automatic use paused pending verification", "소비 결과 확인 필요 · 추가 사용 보류")
                            : localized("Latest account check failed", "최근 계정 조회 실패"))
            }
            if ["denied", "notDetermined", "deliveryFailed", "unknown"].contains(state.notificationStatus) {
                rows.append(localized("Notifications need permission or delivery check", "알림 권한 또는 전달 상태 확인 필요"))
            }
            rows.append(localized("Alerts: 1 hr, 20 min, 5 min before expiry", "만료 알림: 1시간 · 20분 · 5분 전"))
            rows.append(localized("Mac must be awake · remaining usage ≤10%", "Mac이 깨어 있어야 함 · 잔여 사용량 10% 이하"))
            return rows
        } catch { return [localized("Reset settings/state unreadable; auto-use is blocked", "설정·상태 읽기 실패 · 자동 사용 차단")] }
    }
}
