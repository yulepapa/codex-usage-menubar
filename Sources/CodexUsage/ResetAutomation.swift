import Foundation

// This adapter only reads existing watcher files. It never starts a watcher,
// changes a schedule, sends a notification, or redeems a credit.
struct ResetAttempt {
    enum Outcome: String { case used, noCredit, waiting, failed, expired, unknown }
    let at: Date
    let outcome: Outcome
}

struct ResetWatcherSnapshot {
    enum Health: String { case unlinked, unknown, failed, stale, observed }
    var isPresent = false
    var readFailed = false
    var lastCheck: Date?
    var expectedNextCheck: Date?
    var observedExpiry: Date?
    var consumeBeforeSeconds: TimeInterval?
    var lastAttempt: ResetAttempt?
    var queryFailure: Date?
    var notificationFailure: Date?

    func health(at now: Date) -> Health {
        guard isPresent else { return .unlinked }
        if let failed = queryFailure, failed > (lastCheck ?? .distantPast) { return .failed }
        guard !readFailed, let checked = lastCheck, let next = expectedNextCheck,
              checked <= now.addingTimeInterval(60), next >= checked else { return .unknown }
        return now > next.addingTimeInterval(600) ? .stale : .observed
    }

    func plannedAttempt(credits: CreditInfo?, at now: Date) -> Date? {
        guard health(at: now) == .observed, let lead = consumeBeforeSeconds,
              let count = credits?.availableCount, count > 0,
              let expiry = credits?.earliestExpiresAt, TimeInterval(expiry) > now.timeIntervalSince1970,
              observedExpiry?.timeIntervalSince1970 == TimeInterval(expiry)
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiry) - lead)
    }
}

enum ResetWatcherReader {
    private static let dateLock = NSLock()
    private static let isoFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_USAGE_RESET_WATCHER_DIR"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let codexHome: URL
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") {
            codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("automations/codex", isDirectory: true)
    }

    static func read(directory: URL = defaultDirectory(), now: Date = Date()) -> ResetWatcherSnapshot {
        var snapshot = ResetWatcherSnapshot()
        let names = ["reset_credit_watcher.py", "reset_credit_watcher_state.json", "reset_credit_watcher.log"]
        snapshot.isPresent = names.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard snapshot.isPresent else { return snapshot }
        let policy = readFile(directory.appendingPathComponent(names[0]), limit: 131_072)
        // Parse only a literal seconds value or a multiplication of two integers.
        // An unfamiliar expression remains unknown; Python is never evaluated.
        if let data = policy.data, let source = String(data: data, encoding: .utf8) {
            snapshot.consumeBeforeSeconds = numericConstant("CONSUME_BEFORE_SECONDS", in: source)
        }
        let state = readFile(directory.appendingPathComponent(names[1]), limit: 1_048_576)
        let log = readFile(directory.appendingPathComponent(names[2]), limit: 262_144, tail: true)
        snapshot.readFailed = policy.failed || state.failed || log.failed
        if let data = state.data {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                snapshot.readFailed = true
                parseLog(log.data, into: &snapshot, now: now, policy: policy.data)
                return snapshot
            }
            parseState(root, into: &snapshot, now: now)
        }
        parseLog(log.data, into: &snapshot, now: now, policy: policy.data)
        return snapshot
    }

    private static func readFile(_ url: URL, limit: Int, tail: Bool = false) -> (data: Data?, failed: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, false) }
        do {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return (nil, true) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if !tail && size > UInt64(limit) { return (nil, true) }
            let offset = tail && size > UInt64(limit) ? size - UInt64(limit) : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: limit) ?? Data()
            // A tail may begin halfway through a JSON line (or a UTF-8 character).
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return (nil, true) }
                data.removeSubrange(...newline)
            }
            return (data, false)
        } catch { return (nil, true) }
    }

    static func numericConstant(_ name: String, in source: String) -> TimeInterval? {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let assignments = try? NSRegularExpression(pattern: "(?m)^" + NSRegularExpression.escapedPattern(for: name) + "[ \\t]*=")
        guard assignments?.numberOfMatches(in: source, range: range) == 1 else { return nil }
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: name)
            + "[ \\t]*=[ \\t]*([0-9]+)(?:[ \\t]*\\*[ \\t]*([0-9]+))?[ \\t]*(?:#[^\\n]*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: source, range: range)
        guard matches.count == 1, let match = matches.first,
              let first = Range(match.range(at: 1), in: source), let value = Double(source[first]) else { return nil }
        var seconds = value
        if let second = Range(match.range(at: 2), in: source), let factor = Double(source[second]) { seconds *= factor }
        return seconds > 0 && seconds <= 604_800 ? seconds : nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        dateLock.lock()
        defer { dateLock.unlock() }
        return isoFormatter.date(from: string) ?? fractionalFormatter.date(from: string)
    }

    private static func record(_ attempt: ResetAttempt, into snapshot: inout ResetWatcherSnapshot, now: Date) {
        guard attempt.at <= now.addingTimeInterval(60) else { return }
        if snapshot.lastAttempt?.at == attempt.at, snapshot.lastAttempt?.outcome == .used { return }
        if attempt.at >= (snapshot.lastAttempt?.at ?? .distantPast) { snapshot.lastAttempt = attempt }
    }

    private static func parseState(_ root: [String: Any], into snapshot: inout ResetWatcherSnapshot, now: Date) {
        if let records = root["consume"] as? [String: Any] {
            for value in records.values {
                guard let row = value as? [String: Any] else { continue }
                let attempted = date(row["lastAttemptAt"])
                let checked = date(row["lastCheckedAt"])
                guard let at = [attempted, checked].compactMap({ $0 }).max() else { continue }
                let outcome: ResetAttempt.Outcome
                // Successful outcomes take precedence over errors retained by the watcher.
                switch row["outcome"] as? String {
                case "reset", "alreadyRedeemed": outcome = .used
                case "noCredit": outcome = .noCredit
                case "nothingToReset": outcome = .waiting
                case "dry-run": continue
                default:
                    if checked != nil && checked == at,
                       row["lastOutcome"] as? String == "waiting-for-eligible-usage" { outcome = .waiting }
                    else if row["lastError"] != nil { outcome = .failed }
                    else if ["nothingToReset", "waiting-for-eligible-usage"].contains(row["lastOutcome"] as? String ?? "") { outcome = .waiting }
                    else { outcome = .unknown }
                }
                record(ResetAttempt(at: at, outcome: outcome), into: &snapshot, now: now)
            }
        }
        if let missed = root["missed"] as? [String: Any] {
            for value in missed.values {
                if let at = date(value) { record(ResetAttempt(at: at, outcome: .expired), into: &snapshot, now: now) }
            }
        }
    }

    private static func parseLog(_ data: Data?, into snapshot: inout ResetWatcherSnapshot, now: Date, policy: Data?) {
        guard let data, let text = String(data: data, encoding: .utf8) else { return }
        var alerts: [String: (Date, Bool)] = [:]
        let source = policy.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  row["dryRun"] as? Bool != true,
                  let at = date(row["time"]), at <= now.addingTimeInterval(60),
                  let message = row["message"] as? String else { continue }
            switch message {
            case "watch cycle complete", "no available reset credits":
                guard at >= (snapshot.lastCheck ?? .distantPast) else { continue }
                snapshot.lastCheck = at
                snapshot.observedExpiry = message == "watch cycle complete" ? date(row["expiresAt"]) : nil
                var delay: Double?
                if let value = row["nextCheckSeconds"] as? NSNumber,
                   CFGetTypeID(value) != CFBooleanGetTypeID() { delay = value.doubleValue }
                if message == "no available reset credits" { delay = numericConstant("MAX_DISCOVERY_SLEEP_SECONDS", in: source) }
                snapshot.expectedNextCheck = delay.flatMap { $0 >= 0 && $0 <= 86_400 ? at.addingTimeInterval($0) : nil }
            case "watch cycle failed":
                snapshot.queryFailure = max(snapshot.queryFailure ?? .distantPast, at)
            case "consume attempt failed":
                record(ResetAttempt(at: at, outcome: .failed), into: &snapshot, now: now)
            case "thread notification failed", "thread report turn completed", "local notification failed", "local notification delivered":
                let channel = message.hasPrefix("thread") ? "thread" : "local"
                if at >= (alerts[channel]?.0 ?? .distantPast) { alerts[channel] = (at, message.hasSuffix("failed")) }
            default: break // Never expose raw errors, prompts, credit IDs, or idempotency keys.
            }
        }
        snapshot.notificationFailure = alerts.values.filter { $0.1 }.map { $0.0 }.max()
    }
}

enum ResetSection {
    static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }

    static func rows(credits: CreditInfo?, watcher: ResetWatcherSnapshot, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        func date(_ value: Date) -> String { formatDate(value, timeZone: timeZone) }
        var rows: [String] = []
        if let count = credits?.availableCount, count >= 0 {
            rows.append(count == 0 ? localized("Credits: none available", "보유: 없음") : localized("Credits: \(count) available", "보유: \(count)장"))
            if count > 0, let expiry = credits?.earliestExpiresAt {
                rows.append(localized("Earliest expiry: ", "가장 빠른 만료: ") + date(Date(timeIntervalSince1970: TimeInterval(expiry))))
            } else if count > 0 { rows.append(localized("Expiry: unknown", "만료: 확인 불가")) }
        } else { rows.append(localized("Credits: unknown", "보유: 확인 불가")) }

        switch watcher.health(at: now) {
        case .unlinked: rows.append(localized("Auto-use: watcher not linked", "자동 사용: 감시기 연결 안 됨"))
        case .unknown: rows.append(localized("Watcher status: unknown", "감시 상태: 확인 불가"))
        case .failed: rows.append(localized("Watcher: latest check failed", "감시 상태: 최근 조회 실패"))
        case .stale: rows.append(localized("Watcher: check record is stale", "감시 상태: 확인 기록 오래됨"))
        case .observed: rows.append(localized("Auto-use: local watcher record found", "자동 사용: 기존 감시기 기록 확인"))
        }
        if let next = watcher.plannedAttempt(credits: credits, at: now) {
            rows.append(next > now
                ? localized("Planned attempt: ", "다음 시도 예정: ") + date(next)
                : localized("Attempt window open · awaiting result", "시도 시간 도달 · 결과 확인 필요"))
        } else if watcher.isPresent {
            rows.append(credits?.availableCount == 0
                ? localized("Next attempt: no available credit", "다음 시도: 사용 가능한 권 없음")
                : localized("Next attempt: unknown", "다음 시도: 확인 불가"))
        }
        if let result = watcher.lastAttempt {
            let label: String
            switch result.outcome {
            case .used: label = localized("Used", "사용 완료")
            case .noCredit: label = localized("No credit", "사용할 권 없음")
            case .waiting: label = localized("Waiting for eligibility", "사용 조건 대기")
            case .failed: label = localized("Failed", "사용 시도 실패")
            case .expired: label = localized("Expired · success unconfirmed", "만료 · 성공 미확인")
            case .unknown: label = localized("Unknown", "확인 불가")
            }
            rows.append(localized("Last result: ", "최근 결과: ") + label + " · " + date(result.at))
        } else if watcher.isPresent { rows.append(localized("Last result: no record", "최근 결과: 기록 없음")) }
        if let failure = watcher.notificationFailure {
            rows.append(localized("Notification failed: ", "알림 전달 실패: ") + date(failure))
        }
        if let checked = watcher.lastCheck {
            rows.append(localized("Watcher checked: ", "감시 확인: ") + date(checked))
        }
        if watcher.isPresent { rows.append(localized("Mac must be awake · use depends on eligibility", "Mac이 깨어 있어야 함 · 사용 조건 충족 시 시도")) }
        return rows
    }
}
