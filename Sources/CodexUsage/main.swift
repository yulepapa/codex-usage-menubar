import AppKit
import Darwin
import Foundation

private let appVersion = "1.0.0"

private func localized(_ english: String, _ korean: String) -> String {
    let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
    return language.hasPrefix("ko") ? korean : english
}

struct UsageWindow: Codable {
    let slot: String
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CreditInfo: Codable {
    let availableCount: Int?
    let earliestExpiresAt: Int?
}

struct UsagePayload: Codable {
    let bucketLabel: String?
    let windows: [UsageWindow]
    let credits: CreditInfo
}

enum UsageError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case timeout
    case connectionClosed
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return localized(
                "Codex CLI was not found. Re-run the installer with CODEX_PATH set.",
                "Codex CLI를 찾지 못했습니다. CODEX_PATH를 지정해 설치기를 다시 실행하세요."
            )
        case .launchFailed(let message):
            return localized("Could not start Codex: ", "Codex를 시작하지 못했습니다: ") + message
        case .timeout:
            return localized("The Codex usage request timed out.", "Codex 사용량 조회 시간이 초과됐습니다.")
        case .connectionClosed:
            return localized("Codex closed the connection unexpectedly.", "Codex 연결이 예기치 않게 종료됐습니다.")
        case .invalidResponse:
            return localized("Codex returned an invalid response.", "Codex가 올바르지 않은 응답을 반환했습니다.")
        case .server(let message):
            return message.isEmpty
                ? localized("Codex returned an error.", "Codex가 오류를 반환했습니다.")
                : message
        }
    }
}

enum CodexLocator {
    static func locate(fileManager: FileManager = .default) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path

        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["CODEX_PATH"] {
            candidates.append(expandHome(configured, home: home))
        }

        let configPath = home + "/Library/Application Support/CodexUsage/codex-path"
        if let configured = try? String(contentsOfFile: configPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(expandHome(configured, home: home))
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append(String(directory) + "/codex")
            }
        }

        candidates.append(contentsOf: [
            home + "/.local/bin/codex",
            home + "/.volta/bin/codex",
            home + "/.bun/bin/codex",
            home + "/.asdf/shims/codex",
            home + "/.local/share/mise/shims/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ])

        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                candidates.append(nvmRoot + "/" + version + "/bin/codex")
            }
        }

        var seen = Set<String>()
        return candidates.first { candidate in
            guard candidate.hasPrefix("/"), seen.insert(candidate).inserted else { return false }
            return fileManager.isExecutableFile(atPath: candidate)
        }
    }

    private static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }
}

private final class FileDescriptorLineReader {
    private let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func readLine(deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw UsageError.timeout }
            let timeoutMilliseconds = Int32(min(Double(Int32.max), max(1, remaining * 1_000)))
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = withUnsafeMutablePointer(to: &descriptorState) {
                Darwin.poll($0, 1, timeoutMilliseconds)
            }

            if pollResult == 0 { throw UsageError.timeout }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw UsageError.connectionClosed
            }
            if descriptorState.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw UsageError.connectionClosed
            }

            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = chunk.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                if !buffer.isEmpty {
                    let line = buffer
                    buffer.removeAll(keepingCapacity: false)
                    return line
                }
                throw UsageError.connectionClosed
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw UsageError.connectionClosed
            }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}

enum UsageParser {
    static func parseDocument(_ data: Data) throws -> UsagePayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        let result = (root["result"] as? [String: Any]) ?? root
        return try parseResult(result)
    }

    static func parseResult(_ result: [String: Any]) throws -> UsagePayload {
        let selected = selectRateLimitSnapshot(from: result)
        let snapshot = selected.snapshot
        var windows: [UsageWindow] = []

        for slot in ["primary", "secondary"] {
            guard let window = snapshot[slot] as? [String: Any],
                  let usedPercent = integer(window["usedPercent"]) else { continue }
            windows.append(
                UsageWindow(
                    slot: slot,
                    usedPercent: max(0, min(100, usedPercent)),
                    windowDurationMins: integer(window["windowDurationMins"]),
                    resetsAt: integer(window["resetsAt"])
                )
            )
        }

        let creditsObject = result["rateLimitResetCredits"] as? [String: Any]
        let availableCount = integer(creditsObject?["availableCount"])
        let creditRows = creditsObject?["credits"] as? [[String: Any]] ?? []
        let expirations = creditRows.compactMap { credit -> Int? in
            guard (credit["status"] as? String)?.lowercased() == "available" else { return nil }
            return integer(credit["expiresAt"])
        }

        return UsagePayload(
            bucketLabel: selected.label,
            windows: windows,
            credits: CreditInfo(
                availableCount: availableCount,
                earliestExpiresAt: expirations.min()
            )
        )
    }

    private static func selectRateLimitSnapshot(from result: [String: Any]) -> (snapshot: [String: Any], label: String?) {
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            if let codex = buckets["codex"] as? [String: Any] {
                return (codex, displayLabel(snapshot: codex, fallback: "codex"))
            }
            if buckets.count == 1,
               let pair = buckets.first,
               let snapshot = pair.value as? [String: Any] {
                return (snapshot, displayLabel(snapshot: snapshot, fallback: pair.key))
            }
        }

        let legacy = result["rateLimits"] as? [String: Any] ?? [:]
        return (legacy, displayLabel(snapshot: legacy, fallback: nil))
    }

    private static func displayLabel(snapshot: [String: Any], fallback: String?) -> String? {
        if let name = snapshot["limitName"] as? String, !name.isEmpty { return name }
        if let identifier = snapshot["limitId"] as? String, !identifier.isEmpty { return identifier }
        return fallback
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

final class CodexAppServerClient {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 25) {
        self.timeout = timeout
    }

    func fetch(codexPath: String? = nil) throws -> UsagePayload {
        guard let executable = codexPath ?? CodexLocator.locate() else {
            throw UsageError.codexNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = nullOutput

        do {
            try process.run()
        } catch {
            throw UsageError.launchFailed(error.localizedDescription)
        }

        defer {
            try? inputPipe.fileHandleForWriting.close()
            stop(process)
            try? nullOutput?.close()
        }

        let writer = inputPipe.fileHandleForWriting
        let reader = FileDescriptorLineReader(descriptor: outputPipe.fileHandleForReading.fileDescriptor)
        let deadline = Date().addingTimeInterval(timeout)

        try send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "codex-usage-menubar", "version": appVersion],
                    "capabilities": ["experimentalApi": true]
                ]
            ],
            to: writer
        )

        var usageRequested = false
        while true {
            let line = try reader.readLine(deadline: deadline)
            guard !line.isEmpty,
                  let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            let responseID = (message["id"] as? NSNumber)?.intValue

            if responseID == 1, !usageRequested {
                if let error = message["error"] {
                    throw UsageError.server(serverErrorMessage(error))
                }
                try send(["method": "initialized", "params": [:]], to: writer)
                try send(
                    ["id": 2, "method": "account/rateLimits/read"],
                    to: writer
                )
                usageRequested = true
            } else if responseID == 2 {
                if let error = message["error"] {
                    throw UsageError.server(serverErrorMessage(error))
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw UsageError.invalidResponse
                }
                return try UsageParser.parseResult(result)
            }
        }
    }

    private func send(_ object: [String: Any], to writer: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        do {
            try writer.write(contentsOf: data)
        } catch {
            throw UsageError.connectionClosed
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, deadline.timeIntervalSinceNow > 0 {
            usleep(20_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func serverErrorMessage(_ error: Any) -> String {
        if let object = error as? [String: Any], let message = object["message"] as? String {
            return message
        }
        return localized("Codex app-server returned an error.", "Codex app-server가 오류를 반환했습니다.")
    }
}

final class UsageFetcher {
    private let client = CodexAppServerClient()

    func fetch(completion: @escaping (Result<UsagePayload, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result: Result<UsagePayload, Error>
            do {
                result = .success(try self.client.fetch())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let fetcher = UsageFetcher()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var latestSnapshot: UsagePayload?
    private var lastUpdated: Date?
    private var lastError: String?
    private var isRefreshing = false

    private var refreshInterval: TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["CODEX_USAGE_REFRESH_SECONDS"],
              let value = Double(raw) else { return 5 * 60 }
        return min(3_600, max(60, value))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menu.autoenablesItems = false
        menu.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "CodexUsage"
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.title = "…"
        statusItem.button?.toolTip = localized("Codex remaining usage", "Codex 남은 사용량")
        statusItem.button?.setAccessibilityLabel(localized("Codex remaining usage", "Codex 남은 사용량"))
        statusItem.button?.setAccessibilityValue(localized("Checking usage", "사용량 확인 중"))
        statusItem.menu = menu

        rebuildMenu()
        refreshUsage()

        let refreshTimer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        if lastUpdated.map({ Date().timeIntervalSince($0) > 90 }) ?? true {
            refreshUsage()
        }
    }

    @objc private func workspaceDidWake() {
        refreshUsage()
    }

    @objc private func refreshNow() {
        refreshUsage()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func refreshUsage() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if latestSnapshot == nil {
            statusItem.button?.title = "…"
            statusItem.button?.setAccessibilityValue(localized("Checking usage", "사용량 확인 중"))
        }
        rebuildMenu()

        fetcher.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let snapshot):
                self.latestSnapshot = snapshot
                self.lastUpdated = Date()
                self.lastError = nil
                self.updateStatusTitle(using: snapshot)
            case .failure(let error):
                self.lastError = error.localizedDescription
                if self.latestSnapshot == nil {
                    self.statusItem.button?.title = "!"
                    self.statusItem.button?.setAccessibilityValue(
                        localized("Usage unavailable", "사용량을 불러올 수 없음")
                    )
                }
            }
            self.rebuildMenu()
        }
    }

    private func orderedWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.sorted {
            let left = $0.windowDurationMins ?? Int.max
            let right = $1.windowDurationMins ?? Int.max
            if left == right { return $0.slot < $1.slot }
            return left < right
        }
    }

    private func updateStatusTitle(using snapshot: UsagePayload) {
        let windows = orderedWindows(snapshot.windows)
        guard !windows.isEmpty else {
            statusItem.button?.title = "?"
            statusItem.button?.setAccessibilityValue(
                localized("No usage windows are available", "표시할 사용량 구간이 없음")
            )
            return
        }

        if windows.count == 1, let window = windows.first {
            statusItem.button?.title = "\(window.remainingPercent)%"
        } else {
            let parts = windows.map {
                "\(compactWindowLabel($0)) \($0.remainingPercent)%"
            }
            statusItem.button?.title = parts.joined(separator: " · ")
        }

        let spokenValue = windows.map {
            windowLabel($0) + localized(" remaining ", " 남음 ") + "\($0.remainingPercent)%"
        }.joined(separator: localized(", ", ", "))
        statusItem.button?.setAccessibilityValue(spokenValue)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let heading = NSMenuItem(title: localized("Codex Usage", "Codex 사용량"), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        heading.attributedTitle = NSAttributedString(
            string: localized("Codex Usage", "Codex 사용량"),
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        menu.addItem(heading)
        menu.addItem(.separator())

        if let snapshot = latestSnapshot {
            if let bucket = snapshot.bucketLabel,
               bucket.caseInsensitiveCompare("codex") != .orderedSame {
                addInfoItem(localized("Limit: ", "한도: ") + bucket)
                menu.addItem(.separator())
            }

            let windows = orderedWindows(snapshot.windows)
            if windows.isEmpty {
                addInfoItem(localized("No usage windows are available.", "표시할 사용량 구간이 없습니다."))
            } else {
                for (index, window) in windows.enumerated() {
                    addInfoItem(
                        windowLabel(window) + localized(" remaining ", " 남음 ") + "\(window.remainingPercent)%"
                    )
                    if let reset = window.resetsAt {
                        addInfoItem(
                            localized("  Resets ", "  초기화 ")
                                + formatDate(timestamp: reset)
                                + " · "
                                + relativeTime(timestamp: reset)
                        )
                    }
                    if index < windows.count - 1 { menu.addItem(.separator()) }
                }
            }

            if let creditCount = snapshot.credits.availableCount {
                menu.addItem(.separator())
                addInfoItem(
                    localized("Reset credits: ", "초기화권 ")
                        + "\(creditCount)"
                        + localized("", "장")
                )
                if let expiration = snapshot.credits.earliestExpiresAt, creditCount > 0 {
                    addInfoItem(
                        localized("  Earliest expiry ", "  가장 빠른 만료 ")
                            + formatDate(timestamp: expiration)
                    )
                }
            }
        } else {
            addInfoItem(
                isRefreshing
                    ? localized("Checking usage…", "사용량을 확인하는 중…")
                    : localized("Usage is unavailable.", "사용량을 불러오지 못했습니다.")
            )
        }

        if let error = lastError {
            menu.addItem(.separator())
            addInfoItem(
                localized("Latest error: ", "최근 조회 오류: ") + shortened(error, limit: 90)
            )
        }

        menu.addItem(.separator())
        if let updated = lastUpdated {
            addInfoItem(localized("Last checked ", "마지막 확인 ") + formatTime(updated))
        }
        addInfoItem(
            localized("Refresh interval: ", "자동 갱신: ") + formatRefreshInterval(refreshInterval)
        )

        let refreshItem = NSMenuItem(
            title: isRefreshing
                ? localized("Refreshing…", "새로고침 중…")
                : localized("Refresh Now", "지금 새로고침"),
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: localized("Quit Codex Usage", "Codex 사용량 종료"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }

    private func addInfoItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func windowLabel(_ window: UsageWindow) -> String {
        guard let minutes = window.windowDurationMins else {
            return window.slot == "secondary"
                ? localized("Secondary window", "보조 구간")
                : localized("Primary window", "기본 구간")
        }
        switch minutes {
        case 300:
            return localized("5-hour", "5시간")
        case 1_440:
            return localized("Daily", "일간")
        case 10_080:
            return localized("Weekly", "주간")
        default:
            if minutes % 1_440 == 0 {
                return localized("\(minutes / 1_440)-day window", "\(minutes / 1_440)일 구간")
            }
            if minutes % 60 == 0 {
                return localized("\(minutes / 60)-hour window", "\(minutes / 60)시간 구간")
            }
            return localized("\(minutes)-minute window", "\(minutes)분 구간")
        }
    }

    private func compactWindowLabel(_ window: UsageWindow) -> String {
        guard let minutes = window.windowDurationMins else {
            return window.slot == "secondary" ? "S" : "P"
        }
        switch minutes {
        case 300: return "5h"
        case 1_440: return localized("day", "일")
        case 10_080: return localized("wk", "주")
        default:
            if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
            if minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
    }

    private func formatDate(timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func relativeTime(timestamp: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .full
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            relativeTo: Date()
        )
    }

    private func formatRefreshInterval(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        if minutes < 60 {
            return localized("every \(minutes) min", "\(minutes)분마다")
        }
        let hours = minutes / 60
        return localized("every \(hours) hr", "\(hours)시간마다")
    }

    private func shortened(_ text: String, limit: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}

private func writeStandardError(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func printPayload(_ payload: UsagePayload) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(payload))
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func runCommandLineMode(_ arguments: [String]) -> Int32? {
    if arguments.contains("--version") {
        print(appVersion)
        return EXIT_SUCCESS
    }

    if let index = arguments.firstIndex(of: "--parse-fixture") {
        guard arguments.indices.contains(index + 1) else {
            writeStandardError("--parse-fixture requires a JSON file path")
            return EXIT_FAILURE
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            try printPayload(UsageParser.parseDocument(data))
            return EXIT_SUCCESS
        } catch {
            writeStandardError(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    if arguments.contains("--print-usage") {
        do {
            try printPayload(CodexAppServerClient().fetch())
            return EXIT_SUCCESS
        } catch {
            writeStandardError(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    return nil
}

if let exitCode = runCommandLineMode(Array(CommandLine.arguments.dropFirst())) {
    exit(exitCode)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
