import Foundation
import Darwin

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
            ),
            resetCredits: creditRows.compactMap { row in
                guard row["status"] as? String == "available", let id = row["id"] as? String,
                      !id.isEmpty, let expiry = integer(row["expiresAt"]) else { return nil }
                return ResetCredit(id: id, expiresAt: Date(timeIntervalSince1970: TimeInterval(expiry)))
            },
            isCoreCodex: (snapshot["limitId"] as? String == "codex")
                || ((result["rateLimitsByLimitId"] as? [String: Any])?["codex"] != nil)
                || (result["rateLimitsByLimitId"] == nil && snapshot["limitId"] == nil)
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
        try UsageParser.parseResult(request(method: "account/rateLimits/read", params: nil, codexPath: codexPath))
    }

    func consume(creditID: String, key: String) throws -> String {
        let result = try request(method: "account/rateLimitResetCredit/consume",
                                 params: ["creditId": creditID, "idempotencyKey": key])
        guard let outcome = result["outcome"] as? String,
              ["reset", "alreadyRedeemed", "noCredit", "nothingToReset"].contains(outcome) else {
            throw UsageError.invalidResponse
        }
        return outcome
    }

    private func request(method: String, params: [String: Any]?, codexPath: String? = nil) throws -> [String: Any] {
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
                var request: [String: Any] = ["id": 2, "method": method]
                if let params { request["params"] = params }
                try send(request, to: writer)
                usageRequested = true
            } else if responseID == 2 {
                if let error = message["error"] {
                    throw UsageError.server(serverErrorMessage(error))
                }
                guard let result = message["result"] as? [String: Any] else {
                    throw UsageError.invalidResponse
                }
                return result
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
