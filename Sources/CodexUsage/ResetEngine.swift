import Foundation
import Darwin

struct ResetSettings: Codable {
    var autoUse = false
    var reminders = true
}

struct Redemption: Codable {
    var key: String
    var expiresAt: Date
    var attemptedAt: Date
    var outcome: String
}

struct ResetEngineState: Codable {
    var version = 1
    var checkedAt: Date?
    var workerSeenAt: Date?
    var phase = "standby"
    var inventory: [ResetCredit] = []
    var availableCount: Int?
    var attempts: [String: Redemption] = [:]
    var reminders: [String: [Int]] = [:]
    var lastError: String?
    var notificationStatus = "unknown"
    var nextCheckAt: Date?
}

enum ResetStorageError: Error { case locked, invalid, unsafeFile }

final class ResetLease {
    private let descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ResetStorageError.unsafeFile }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ResetStorageError.locked
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

final class ResetStore {
    let directory: URL
    static var standard: ResetStore {
        ResetStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexUsage/reset"))
    }
    init(directory: URL) { self.directory = directory }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    func read<T: Decodable>(_ name: String, as type: T.Type, fallback: T) throws -> T {
        let path = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        let attrs = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
              (attrs.fileSize ?? Int.max) <= 4_194_304 else { throw ResetStorageError.unsafeFile }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: path))
    }
    func write<T: Encodable>(_ name: String, _ value: T) throws {
        try prepare()
        let data = try JSONEncoder().encode(value)
        let path = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { throw ResetStorageError.invalid }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ResetStorageError.invalid }
        let synced = fsync(fd); close(fd)
        guard synced == 0 else { throw ResetStorageError.invalid }
        guard rename(temporary.path, path.path) == 0 else { throw ResetStorageError.invalid }
    }
    func settings() throws -> ResetSettings { try read("settings.json", as: ResetSettings.self, fallback: ResetSettings()) }
    func state() throws -> ResetEngineState { try read("state.json", as: ResetEngineState.self, fallback: ResetEngineState()) }
    func active() throws -> Bool {
        guard try read("ownership.json", as: [String: Bool].self, fallback: [:])["active"] == true else { return false }
        let worker = try read("worker.json", as: [String: String].self, fallback: [:])
        if let path = worker["launchAgent"] {
            guard path.hasSuffix(".plist") else { return false }
            let url = URL(fileURLWithPath: path)
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) < 65_536,
                  let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
                  plist["Label"] as? String == worker["label"],
                  let arguments = plist["ProgramArguments"] as? [String],
                  arguments == [worker["executable"] ?? "", "--reset-worker"] else { return false }
        }
        return true
    }
    func updateSettings(_ change: (inout ResetSettings) -> Void) throws {
        try prepare()
        let lease = try ResetLease(url: directory.appendingPathComponent("settings.lock"))
        defer { withExtendedLifetime(lease) {} }
        var value = try settings(); change(&value); try write("settings.json", value)
    }
}

protocol ResetService {
    func read() throws -> UsagePayload
    func consume(credit: ResetCredit, key: String) throws -> String
}

protocol ResetNotifier {
    var status: String { get }
    func send(credit: ResetCredit, milestone: Int, now: Date) throws
    func clear(credit: ResetCredit)
}

// Only the leased worker calls this engine. UI refreshes never consume.
final class ResetEngine {
    let store: ResetStore
    let service: ResetService
    let notifier: ResetNotifier
    let clock: () -> Date
    var save: (ResetEngineState) throws -> Void
    init(store: ResetStore, service: ResetService, notifier: ResetNotifier, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.service = service; self.notifier = notifier; self.clock = clock
        self.save = { try store.write("state.json", $0) }
    }

    func tick(active: Bool) throws {
        var state = try store.state() // Corruption fails closed; never reset the ledger.
        let settings = try store.settings()
        let now = clock()
        state.workerSeenAt = now
        state.phase = active ? "checking" : "standby"
        state.nextCheckAt = now.addingTimeInterval(60)
        let snapshot: UsagePayload
        do { snapshot = try service.read() }
        catch {
            state.lastError = "queryFailed"; state.phase = "queryFailed"; try save(state); return
        }
        state.checkedAt = clock(); state.lastError = nil
        state.availableCount = snapshot.credits.availableCount
        let previousInventory = state.inventory
        state.inventory = snapshot.resetCredits.sorted { $0.expiresAt < $1.expiresAt }
        let availableIDs = Set(state.inventory.map { $0.id })
        for old in previousInventory where !availableIDs.contains(old.id) { notifier.clear(credit: old) }
        for old in state.attempts where !availableIDs.contains(old.key) {
            notifier.clear(credit: ResetCredit(id: old.key, expiresAt: old.value.expiresAt))
        }
        try save(state)
        guard active else { return }

        let coolingDown = state.attempts.values.contains {
            ["reset", "alreadyRedeemed"].contains($0.outcome) && clock().timeIntervalSince($0.attemptedAt) < 300
        }
        if coolingDown { state.phase = "cooldown" }
        if settings.reminders { state.notificationStatus = notifier.status }

        // A previous uncertain result must be reconciled with the same key.
        // Missing credits never become assumed success or a new use.
        let unresolved = state.attempts.filter { $0.value.outcome == "pending" }
        if !unresolved.isEmpty {
            state.phase = "needsReview"; state.lastError = "resultUnknown"
        }
        if unresolved.contains(where: { entry in
            entry.value.expiresAt <= clock() || !state.inventory.contains(where: {
                $0.id == entry.key && $0.expiresAt == entry.value.expiresAt
            })
        }) {
            state.phase = "needsReview"; state.lastError = "resultUnknown"
            try remindAvailableInventory(settings: settings, state: &state); return
        }
        for credit in state.inventory {
            let remaining = credit.expiresAt.timeIntervalSince(clock())
            guard remaining > 0 else { continue }
            if let attempt = state.attempts[credit.id], ["reset", "alreadyRedeemed", "noCredit"].contains(attempt.outcome) {
                notifier.clear(credit: credit); continue
            }
            // Until uncertain work is reconciled, only retry a recorded intent.
            // Waiting for its 180-second retry must not fall through to a new credit.
            let mayAttempt = unresolved.isEmpty
                || (unresolved[credit.id] != nil && state.attempts[credit.id]?.outcome == "pending")
            if mayAttempt && settings.autoUse && !coolingDown && remaining <= 1200 {
                // Refresh immediately before redemption, independently of UI/notification work.
                let fresh: UsagePayload
                do { fresh = try service.read() }
                catch { state.phase = "queryFailed"; state.lastError = "queryFailed"; try save(state); return }
                guard fresh.resetCredits.contains(where: { $0.id == credit.id }) else {
                    notifier.clear(credit: credit)
                    state.inventory = fresh.resetCredits; state.availableCount = fresh.credits.availableCount
                    if unresolved[credit.id] != nil {
                        state.phase = "needsReview"; state.lastError = "resultUnknown"
                        try remindAvailableInventory(settings: settings, state: &state); return
                    }
                    continue
                }
                // Usage percentages are display-only. The service decides whether
                // a reset can be applied; never infer eligibility or success here.
                if let current = fresh.resetCredits.first(where: { $0.id == credit.id && $0.expiresAt == credit.expiresAt }),
                   (fresh.credits.availableCount ?? 0) > 0,
                   current.expiresAt > clock(), current.expiresAt.timeIntervalSince(clock()) <= 1200,
                   try store.settings().autoUse, try store.active() {
                    let prior = state.attempts[credit.id]
                    let key = prior?.outcome == "pending" ? prior!.key : UUID().uuidString
                    if let prior, clock().timeIntervalSince(prior.attemptedAt) < 180 {
                        // Each tick starts in checking. Keep the service's known
                        // no-op visible while this verified credit awaits retry.
                        if prior.outcome == "nothingToReset", prior.expiresAt == current.expiresAt {
                            state.phase = "nothingToReset"
                        }
                        try remind(credit, settings: settings, state: &state)
                        continue
                    }
                    state.attempts[credit.id] = Redemption(key: key, expiresAt: credit.expiresAt,
                                                          attemptedAt: clock(), outcome: "pending")
                    state.phase = "attempting"
                    try save(state) // Durable intent must succeed before the external call.
                    let outcome: String
                    do { outcome = try service.consume(credit: current, key: key) }
                    catch {
                        state.phase = "needsReview"; state.lastError = "resultUnknown"
                        try remind(credit, settings: settings, state: &state)
                        try save(state); return
                    }
                    guard ["reset", "alreadyRedeemed", "noCredit", "nothingToReset"].contains(outcome) else {
                        state.phase = "needsReview"; state.lastError = "resultUnknown"; try save(state); return
                    }
                    state.attempts[credit.id]?.outcome = outcome
                    state.phase = outcome
                    if state.attempts.values.contains(where: { $0.outcome == "pending" }) {
                        state.phase = "needsReview"; state.lastError = "resultUnknown"
                    } else { state.lastError = nil }
                    try save(state)
                    if ["reset", "alreadyRedeemed", "noCredit"].contains(outcome) {
                        notifier.clear(credit: credit)
                        do {
                            let updated = try service.read()
                            state.inventory = updated.resetCredits; state.availableCount = updated.credits.availableCount
                            state.checkedAt = clock()
                        } catch { state.lastError = "refreshFailed" }
                        try save(state)
                        return // At most one logical redemption in a cycle.
                    }
                } else {
                    // A successful fresh read supersedes the first snapshot even
                    // when it invalidates eligibility. Keep that knowledge durable.
                    state.inventory = fresh.resetCredits
                    state.availableCount = fresh.credits.availableCount
                    state.checkedAt = clock()
                    state.phase = "waitingForCredit"
                }
            }
            try remind(credit, settings: settings, state: &state)
        }
        if state.phase == "checking" { state.phase = settings.autoUse ? "monitoring" : "autoUseOff" }
        try save(state)
    }

    // Holding uncertain consumption must not suppress reminders for available
    // credits. This path never performs a consume or changes a saved intent.
    private func remindAvailableInventory(settings: ResetSettings, state: inout ResetEngineState) throws {
        for credit in state.inventory {
            if let attempt = state.attempts[credit.id], ["reset", "alreadyRedeemed", "noCredit"].contains(attempt.outcome) {
                notifier.clear(credit: credit); continue
            }
            try remind(credit, settings: settings, state: &state)
        }
        try save(state)
    }

    private func remind(_ credit: ResetCredit, settings: ResetSettings, state: inout ResetEngineState) throws {
        guard settings.reminders else { notifier.clear(credit: credit); return }
        let remaining = credit.expiresAt.timeIntervalSince(clock())
        guard remaining > 0 else { return }
        let due = [3600, 1200, 300].filter { remaining <= Double($0) }
        if let milestone = due.min(), !(state.reminders[credit.id] ?? []).contains(milestone), state.notificationStatus == "authorized" {
            state.reminders[credit.id] = Array(Set((state.reminders[credit.id] ?? []) + due))
            try save(state)
            do { try notifier.send(credit: credit, milestone: milestone, now: clock()) }
            catch { state.notificationStatus = "deliveryFailed" }
        }
    }
}
