import AppKit
import Darwin
import Foundation
import UserNotifications


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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let fetcher = UsageFetcher()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var popoverTimer: Timer?
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var popoverController: UsagePopoverController?
    private var latestSnapshot: UsagePayload?
    private var lastUpdated: Date?
    private var lastError: String?
    private var usageWarning: String?
    private var settingsWarning: String?
    private var isRefreshing = false
    private var watcher = ResetWatcherSnapshot()
    private let previewDirectory: URL?
    private let previewDate: Date?

    init(previewDirectory: URL? = nil, previewDate: Date? = nil) {
        self.previewDirectory = previewDirectory
        self.previewDate = previewDate
        super.init()
    }

    private var displayDate: Date { previewDate ?? Date() }

    private func readWatcher() {
        watcher = ResetWatcherReader.read(directory: previewDirectory ?? ResetWatcherReader.defaultDirectory(), now: displayDate)
    }

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
        statusItem.autosaveName = previewDirectory == nil ? "CodexUsage" : "CodexUsagePreview"
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.title = "…"
        statusItem.button?.toolTip = localized("COCO · Codex remaining usage", "코코 · Codex 남은 사용량")
        statusItem.button?.setAccessibilityLabel(localized("COCO · Codex remaining usage", "코코 · Codex 남은 사용량"))
        statusItem.button?.setAccessibilityValue(localized("Checking usage", "사용량 확인 중"))
        // The status button's image, font, title and accessibility formatting stay unchanged.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = UsagePopoverView.size
        PopoverFonts.register()

        if previewDirectory == nil && (try? ResetStore.standard.settings().reminders) == true
            && FileManager.default.fileExists(atPath: ResetStore.standard.directory.path) {
            requestNotificationPermission()
        }
        readWatcher()
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
        popoverTimer?.invalidate()
        stopOutsideClickMonitor()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        readWatcher()
        rebuildMenu()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if popover.isShown { startOutsideClickMonitor() }
        if lastUpdated.map({ displayDate.timeIntervalSince($0) > 90 }) ?? true { refreshUsage() }
        let tick = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.readWatcher(); self?.rebuildMenu()
        }
        popoverTimer = tick
        RunLoop.main.add(tick, forMode: .common)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverTimer?.invalidate(); popoverTimer = nil
        stopOutsideClickMonitor()
    }

    func menuWillOpen(_ menu: NSMenu) { readWatcher(); rebuildMenu() }

    @objc private func workspaceDidWake() {
        if previewDirectory == nil && FileManager.default.fileExists(atPath: ResetStore.standard.directory.appendingPathComponent("ownership.json").path) {
            try? ResetStore.standard.write("wake.json", ["at": Date().timeIntervalSince1970])
        }
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
        readWatcher()
        if let directory = previewDirectory {
            do {
                latestSnapshot = try UsageParser.parseDocument(Data(contentsOf: directory.appendingPathComponent("usage.json")))
                lastUpdated = displayDate
                lastError = nil
                if let snapshot = latestSnapshot { updateStatusTitle(using: snapshot) }
            } catch { lastError = localized("Preview fixture unavailable", "미리보기 샘플을 읽을 수 없습니다") }
            rebuildMenu()
            return
        }
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
                self.usageWarning = nil
                self.updateStatusTitle(using: snapshot)
            case .failure(let error):
                self.lastError = error.localizedDescription
                self.usageWarning = UsageMenuWarning.text(for: error)
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
        if previewDirectory != nil { addInfoItem(localized("SAMPLE DATA", "샘플 데이터")) }
        let details = NSMenu()
        details.autoenablesItems = false

        if let snapshot = latestSnapshot {
            if let bucket = snapshot.bucketLabel, bucket.caseInsensitiveCompare("codex") != .orderedSame {
                addInfoItem(localized("Limit: ", "한도: ") + bucket)
            }
            let windows = orderedWindows(snapshot.windows)
            if windows.isEmpty { addInfoItem(localized("Usage windows unavailable", "사용량 구간 확인 필요")) }
            for window in windows {
                addInfoItem(windowLabel(window) + localized(" remaining ", " 남음 ")
                    + "\(window.remainingPercent)%", bold: true)
                if let reset = window.resetsAt {
                    addInfoItem(windowLabel(window) + localized(" resets ", " 초기화 ")
                        + formatDate(timestamp: reset) + " · " + relativeTime(timestamp: reset), to: details)
                }
            }
        } else {
            addInfoItem(isRefreshing ? localized("Checking usage…", "사용량 확인 중…")
                : localized("Usage unavailable", "사용량 확인 필요"))
        }

        menu.addItem(.separator())
        let creditsAreFresh = lastError == nil && (lastUpdated.map {
            displayDate.timeIntervalSince($0) <= refreshInterval + 90
        } ?? false)
        let native = previewDirectory == nil && FileManager.default.fileExists(atPath:
            ResetStore.standard.directory.appendingPathComponent("ownership.json").path)
        // One captured reset state drives counts, warnings, controls and detail rows.
        // The worker may atomically publish another state while this view is rebuilt.
        let nativeState = native ? try? ResetStore.standard.state() : nil
        let nativeSettings = native ? try? ResetStore.standard.settings() : nil
        let nativeActive = native ? try? ResetStore.standard.active() : nil
        let reset: ResetMenuPresentation
        if native, let state = nativeState, let settings = nativeSettings, let active = nativeActive {
            reset = ResetMenuPresentation.native(state: state, settings: settings, active: active, now: displayDate)
        } else if native {
            reset = ResetMenuPresentation(title: localized("Reset credits: unknown", "리셋권 확인 필요"),
                warnings: [localized("Reset state unreadable · auto-use blocked", "설정·상태 확인 필요 · 자동 사용 차단")])
        } else {
            reset = ResetMenuPresentation.legacy(credits: creditsAreFresh ? latestSnapshot?.credits : nil,
                                                watcher: watcher, now: displayDate)
        }
        addInfoItem(reset.title, bold: true)
        if let expiry = reset.expiry { addInfoItem(expiry) }

        if native {
            let settings = nativeSettings
            let canEdit = nativeActive == true && nativeState != nil && settings != nil
            addToggle(settings?.autoUse == true ? localized("Auto-use: On", "자동 사용 켜짐")
                : localized("Auto-use: Off", "자동 사용 꺼짐"), checked: settings?.autoUse == true,
                action: #selector(toggleAutoUse), enabled: canEdit)
            addToggle(localized("Expiry notifications", "만료 전 Mac 알림"), checked: settings?.reminders == true,
                action: #selector(toggleReminders), enabled: canEdit, to: details)
            details.addItem(.separator())
            if let state = nativeState, let settings = nativeSettings, let active = nativeActive {
                for row in NativeResetSection.rows(state: state, settings: settings, active: active, now: displayDate) { addInfoItem(row, to: details) }
            } else { addInfoItem(localized("Reset settings/state unreadable; auto-use is blocked", "설정·상태 읽기 실패 · 자동 사용 차단"), to: details) }
        } else {
            addInfoItem(watcher.isPresent ? localized("Auto-use: existing watcher", "자동 사용: 기존 감시기")
                : localized("Auto-use: not configured", "자동 사용: 미설정"))
            details.addItem(.separator())
            for row in ResetSection.rows(credits: creditsAreFresh ? latestSnapshot?.credits : nil,
                                         watcher: watcher, now: displayDate) { addInfoItem(row, to: details) }
        }

        var warnings = reset.warnings
        if let warning = settingsWarning { warnings.insert(warning, at: 0) }
        if let warning = usageWarning { warnings.insert(warning, at: 0) }
        else if lastUpdated.map({ displayDate.timeIntervalSince($0) > refreshInterval + 90 }) == true {
            warnings.insert(localized("Usage data needs refresh", "사용량 최신 확인 필요"), at: 0)
        }
        if !warnings.isEmpty {
            menu.addItem(.separator())
            var seen = Set<String>()
            for warning in warnings where seen.insert(warning).inserted { addInfoItem("⚠︎ " + warning) }
        }

        details.addItem(.separator())
        if lastError != nil { addInfoItem(usageWarning ?? localized("Latest usage check failed", "최근 사용량 조회 실패"), to: details) }
        if let updated = lastUpdated { addInfoItem(localized("Last checked ", "마지막 확인 ") + formatTime(updated), to: details) }
        addInfoItem(localized("Refresh interval: ", "자동 갱신: ") + formatRefreshInterval(refreshInterval), to: details)

        menu.addItem(.separator())
        let detailItem = NSMenuItem(title: localized("Details", "상세"), action: nil, keyEquivalent: "")
        detailItem.submenu = details
        detailItem.isEnabled = true
        menu.addItem(detailItem)
        let refreshItem = NSMenuItem(title: isRefreshing ? localized("Refreshing…", "새로고침 중…")
            : localized("Refresh Now", "새로고침"), action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.keyEquivalentModifierMask = [.command]
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: localized("Quit", "종료"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        updatePopover(reset: reset, native: native, creditsAreFresh: creditsAreFresh, details: details, warnings: warnings,
                      state: nativeState, settings: nativeSettings, active: nativeActive == true)

        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--export-menu-state"), args.indices.contains(index + 1) {
            let payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                          "rows": menuRows(menu), "version": appVersion]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
            }
        }
    }

    private func updatePopover(reset: ResetMenuPresentation, native: Bool, creditsAreFresh: Bool,
                               details: NSMenu, warnings: [String], state: ResetEngineState?,
                               settings: ResetSettings?, active: Bool) {
        var presentation = reset
        presentation.warnings = warnings
        var model = PopoverPresentation(snapshot: latestSnapshot, checkedAt: lastUpdated, now: displayDate,
            refreshing: isRefreshing, usageFailed: lastError != nil, reset: presentation,
            state: state, settings: settings, active: active, native: native,
            legacyCredits: creditsAreFresh ? latestSnapshot?.credits : nil,
            details: details.items.filter { !$0.isSeparatorItem }.map(\.title))
        model.fixture = previewDirectory != nil
        if let controller = popoverController { controller.canvas.model = model }
        else {
            let controller = UsagePopoverController(model: model)
            controller.canvas.onClose = { [weak self] in self?.popover.performClose(nil) }
            controller.canvas.onRefresh = { [weak self] in self?.refreshUsage() }
            controller.canvas.onAutoUse = { [weak self] in self?.toggleAutoUse() }
            controller.canvas.onReminders = { [weak self] in self?.toggleReminders() }
            controller.canvas.onQuit = { [weak self] in self?.quitApp() }
            popoverController = controller
            popover.contentViewController = controller
        }
    }

    private func menuRows(_ target: NSMenu) -> [[String: Any]] {
        target.items.filter { !$0.isSeparatorItem }.map { item in
            var row: [String: Any] = ["title": item.title, "enabled": item.isEnabled,
                                      "checked": item.state == .on, "bold": item.attributedTitle != nil]
            if let submenu = item.submenu { row["submenu"] = menuRows(submenu) }
            return row
        }
    }

    private func addToggle(_ title: String, checked: Bool, action: Selector, enabled: Bool, to target: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.state = checked ? .on : .off; item.isEnabled = enabled
        (target ?? menu).addItem(item)
    }

    @objc private func toggleAutoUse() {
        guard previewDirectory == nil, (try? ResetStore.standard.active()) == true else { return }
        do {
            try ResetStore.standard.updateSettings { $0.autoUse.toggle() }
            try ResetStore.standard.write("wake.json", ["at": Date().timeIntervalSince1970])
            settingsWarning = nil
        }
        catch { settingsWarning = localized("Could not save auto-use setting", "자동 사용 설정 저장 실패") }
        rebuildMenu()
    }

    @objc private func toggleReminders() {
        guard previewDirectory == nil, (try? ResetStore.standard.active()) == true else { return }
        do {
            try ResetStore.standard.updateSettings { $0.reminders.toggle() }
            try ResetStore.standard.write("wake.json", ["at": Date().timeIntervalSince1970])
            if try ResetStore.standard.settings().reminders { requestNotificationPermission() }
            settingsWarning = nil
        } catch { settingsWarning = localized("Could not save notification setting", "알림 설정 저장 실패") }
        rebuildMenu()
    }

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ResetNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }

    private func addInfoItem(_ title: String, bold: Bool = false, to target: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
        (target ?? menu).addItem(item)
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
            relativeTo: displayDate
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
    if arguments.contains("--notification-status") { print(MacResetNotifier().status); return EXIT_SUCCESS }
    if arguments.contains("--reset-worker") { return ResetWorker.run() }
    if arguments.contains("--check-reset-worker") {
        do {
            let snapshot = try LiveResetService().read()
            guard snapshot.isCoreCodex, !snapshot.windows.isEmpty else { return EXIT_FAILURE }
            print("Read-only worker preflight passed")
            return EXIT_SUCCESS
        } catch { writeStandardError("Read-only worker preflight failed"); return EXIT_FAILURE }
    }
    if arguments.contains("--print-native-reset-status") {
        for row in NativeResetSection.rows(store: .standard, now: Date()) { print(row) }
        return EXIT_SUCCESS
    }

    if arguments.contains("--print-reset-status") {
        let now = Date()
        let watcher = ResetWatcherReader.read(now: now)
        let output: [String: Any] = [
            "health": watcher.health(at: now).rawValue,
            "mode": "read-only",
            "rows": ResetSection.rows(credits: nil, watcher: watcher, now: now)
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return EXIT_SUCCESS
        } catch { return EXIT_FAILURE }
    }

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

if let index = CommandLine.arguments.firstIndex(of: "--export-popover-fixtures") {
    guard CommandLine.arguments.indices.contains(index + 1) else {
        writeStandardError("--export-popover-fixtures requires an output directory"); exit(EXIT_FAILURE)
    }
    do {
        try PopoverDiagnostics.export(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch { writeStandardError("Popover fixture export failed: \(error)"); exit(EXIT_FAILURE) }
}

if let exitCode = runCommandLineMode(Array(CommandLine.arguments.dropFirst())) {
    exit(exitCode)
}

let application = NSApplication.shared
let arguments = Array(CommandLine.arguments.dropFirst())
var previewDirectory: URL?
var previewDate: Date?
if let index = arguments.firstIndex(of: "--preview") {
    guard arguments.indices.contains(index + 1) else {
        writeStandardError("--preview requires a fixture directory")
        exit(EXIT_FAILURE)
    }
    previewDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    if let at = arguments.firstIndex(of: "--at"), arguments.indices.contains(at + 1),
       let seconds = Double(arguments[at + 1]), seconds.isFinite {
        previewDate = Date(timeIntervalSince1970: seconds)
    }
}
let delegate = AppDelegate(previewDirectory: previewDirectory, previewDate: previewDate)
application.delegate = delegate
application.run()
