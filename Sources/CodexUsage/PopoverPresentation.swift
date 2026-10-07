import Foundation

/// Read-only display state. Eligibility and all consumption remain in ResetEngine.
struct PopoverPresentation {
    static let seoul = TimeZone(identifier: "Asia/Seoul")!
    var windows: [UsageWindow] = []
    var checkedAt: Date?
    var now: Date
    var refreshing = false
    var usageFailed = false
    var count: Int?
    var expiresAt: Date?
    /// Only observed, distinct, fresh credits. Counts never synthesize cards.
    var individualCredits: [ResetCredit] = []
    var autoUse = false
    var reminders = false
    var canEdit = false
    var status: Status = .unknown
    var warnings: [String] = []
    var details: [String] = []
    var fixture = false

    enum Status: String {
        case pending, failed, nothingToReset, noCredit, unknown, used, off, setup, expired, ready, waiting
        var title: String {
            switch self {
            case .pending: return localized("Result unconfirmed", "결과 확인 · 사용 보류")
            case .failed: return localized("Check failed", "조회·처리 확인 필요")
            case .nothingToReset: return localized("Nothing to reset", "초기화할 사용량 없음")
            case .noCredit: return localized("No reset credits", "보유 리셋권 없음")
            case .unknown: return localized("Check credit details", "리셋권 확인 필요")
            case .used: return localized("Use confirmed", "사용 완료")
            case .off: return localized("Auto-use off", "자동 사용 꺼짐")
            case .setup: return localized("Check worker", "실행기 확인 필요")
            case .expired: return localized("Refresh expiry", "만료 정보 재확인")
            case .ready: return localized("Attempt window", "사용 시도 대상")
            case .waiting: return localized("Waiting for expiry", "만료 전 대기")
            }
        }
    }

    init(snapshot: UsagePayload?, checkedAt: Date?, now: Date, refreshing: Bool = false,
         usageFailed: Bool = false, reset: ResetMenuPresentation,
         state: ResetEngineState? = nil, settings: ResetSettings? = nil, active: Bool = false,
         native: Bool = false, legacyCredits: CreditInfo? = nil, details: [String] = []) {
        self.windows = (snapshot?.windows ?? []).sorted {
            ($0.windowDurationMins ?? Int.max, $0.slot) < ($1.windowDurationMins ?? Int.max, $1.slot)
        }
        self.checkedAt = checkedAt; self.now = now; self.refreshing = refreshing
        self.usageFailed = usageFailed; self.warnings = reset.warnings; self.details = details
        self.autoUse = settings?.autoUse == true; self.reminders = settings?.reminders == true
        self.canEdit = native && active && settings != nil && state != nil
        if native {
            let fresh = state?.checkedAt.map { (0...180).contains(now.timeIntervalSince($0)) } == true
            count = fresh && state?.lastError != "queryFailed" ? state?.availableCount : nil
            expiresAt = count.map { $0 > 0 } == true ? state?.inventory.map(\.expiresAt).min() : nil
        } else {
            count = legacyCredits?.availableCount
            expiresAt = count.map { $0 > 0 } == true ? legacyCredits?.earliestExpiresAt.map {
                Date(timeIntervalSince1970: Double($0))
            } : nil
        }
        if let value = count, value < 0 { count = nil; expiresAt = nil }
        let inventoryFresh = native
            ? state?.checkedAt.map { (0...180).contains(now.timeIntervalSince($0)) } == true && state?.lastError != "queryFailed"
            : checkedAt.map { (0...180).contains(now.timeIntervalSince($0)) } == true && !usageFailed && legacyCredits != nil
        if inventoryFresh {
            var seen = Set<String>()
            individualCredits = (native ? state?.inventory ?? [] : snapshot?.resetCredits ?? [])
                .filter { !$0.id.isEmpty && $0.expiresAt.timeIntervalSince1970.isFinite && $0.expiresAt > now }
                .sorted { $0.expiresAt == $1.expiresAt ? $0.id < $1.id : $0.expiresAt < $1.expiresAt }
                .filter { seen.insert($0.id).inserted }
        }
        if !individualCredits.isEmpty, count != individualCredits.count {
            warnings.insert(localized("Credit count differs from details · refresh needed", "보유 수·개별 정보 불일치 · 새로고침 필요"), at: 0)
        }
        // The compact menu remains the authority for durable no-op warnings.
        // Never infer success from a falling count, an empty inventory, or phase alone.
        let noOp = localized("Service: no eligible usage to reset", "서버에 초기화할 사용량 없음")
        if state?.lastError == "resultUnknown" || state?.phase == "needsReview"
            || state?.attempts.values.contains(where: { $0.outcome == "pending" }) == true {
            status = .pending
        } else if usageFailed || state?.lastError != nil || (native && (state == nil || settings == nil)) { status = .failed
        } else if reset.warnings.contains(noOp) { status = .nothingToReset
        } else if let last = state?.attempts.values.max(by: { $0.attemptedAt < $1.attemptedAt }),
                  (0..<300).contains(now.timeIntervalSince(last.attemptedAt)),
                  ["reset", "alreadyRedeemed"].contains(last.outcome) { status = .used
        } else if let last = state?.attempts.values.max(by: { $0.attemptedAt < $1.attemptedAt }),
                  (0..<180).contains(now.timeIntervalSince(last.attemptedAt)), last.outcome == "noCredit" {
            status = .noCredit
        } else if count == 0 { status = .noCredit
        } else if count == nil { status = .unknown
        } else if native && (!active || state?.workerSeenAt.map({ (0...180).contains(now.timeIntervalSince($0)) }) != true) {
            status = .setup
        } else if !autoUse { status = .off
        } else if let expiry = expiresAt {
            let seconds = expiry.timeIntervalSince(now)
            status = seconds <= 0 ? .expired : seconds <= 1200 ? .ready : .waiting
        } else { status = .unknown }
    }

    var expiryValue: String { expiryValue(for: expiresAt) }

    func expiryValue(for date: Date?) -> String {
        guard let date else { return localized("Unknown", "미제공") }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return localized("Expired", "만료됨") }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return localized("\(minutes)m", "\(minutes)분") }
        if minutes < 1440 { return localized("\(Int(ceil(Double(minutes) / 60)))h", "\(Int(ceil(Double(minutes) / 60)))시간") }
        return localized("\(Int(ceil(Double(minutes) / 1440)))d", "\(Int(ceil(Double(minutes) / 1440)))일")
    }

    static func date(_ date: Date, timeOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = seoul
        formatter.dateFormat = timeOnly ? "HH:mm 'KST'" : "MM/dd HH:mm 'KST'"
        return formatter.string(from: date)
    }

    static func label(_ window: UsageWindow) -> String {
        switch window.windowDurationMins {
        case 300: return localized("5-hour left", "5시간 남음")
        case 10080: return localized("Weekly left", "주간 남음")
        case 1440: return localized("Daily left", "일간 남음")
        case .some(let minutes) where minutes % 1440 == 0:
            return localized("\(minutes / 1440)-day left", "\(minutes / 1440)일 남음")
        case .some(let minutes) where minutes % 60 == 0:
            return localized("\(minutes / 60)-hour left", "\(minutes / 60)시간 남음")
        case .some(let minutes): return localized("\(minutes)-min left", "\(minutes)분 남음")
        case nil: return window.slot == "secondary" ? localized("Secondary left", "보조 구간 남음") : localized("Primary left", "기본 구간 남음")
        }
    }

    var readout: [String] {
        var rows = windows.map { window in
            Self.label(window) + " \(window.remainingPercent)% · " + localized("Resets ", "초기화 ")
            + (window.resetsAt.map { Self.date(Date(timeIntervalSince1970: Double($0))) } ?? localized("Unknown", "시각 미제공"))
        }
        if windows.isEmpty { rows.append(usageFailed ? localized("Usage check failed", "사용량 조회 실패") : localized("Usage windows unavailable", "사용량 구간 미제공")) }
        rows.append(status.title)
        if let date = expiresAt { rows.append(localized("Credit expires ", "리셋권 만료 ") + Self.date(date)) }
        rows += warnings + details
        var seen = Set<String>()
        return rows.filter { seen.insert($0).inserted }
    }
}

/// Ephemeral display selection, with no store, settings or service references.
/// nil follows the earliest card; an explicit identity survives refresh/reordering.
struct CreditStackSelection {
    private(set) var selectedID: String?

    mutating func reconcile(_ credits: [ResetCredit]) {
        if let selectedID, !credits.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func front(in credits: [ResetCredit]) -> ResetCredit? {
        credits.first(where: { $0.id == selectedID }) ?? credits.first
    }
    func index(in credits: [ResetCredit]) -> Int? {
        guard let front = front(in: credits) else { return nil }
        return credits.firstIndex(where: { $0.id == front.id })
    }
    func visible(in credits: [ResetCredit]) -> [ResetCredit] {
        guard let index = index(in: credits) else { return [] }
        return [credits[index]] + credits.filter { $0.id != credits[index].id }
    }
    mutating func select(_ id: String, in credits: [ResetCredit]) {
        guard credits.contains(where: { $0.id == id }) else { return }
        selectedID = front(in: credits)?.id == id ? nil : id
    }
    mutating func move(_ delta: Int, in credits: [ResetCredit]) {
        guard let index = index(in: credits) else { return }
        let next = max(0, min(credits.count - 1, index + delta))
        if next != index { selectedID = credits[next].id }
    }
}
