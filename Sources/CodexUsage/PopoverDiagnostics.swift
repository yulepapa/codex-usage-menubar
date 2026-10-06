import AppKit

/// An explicit synthetic-only path: no AppDelegate, account client, stores,
/// notification center, settings writes or worker process is created here.
enum PopoverDiagnostics {
    static func export(to directory: URL) throws {
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "PopoverDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("verification.json"))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        PopoverFonts.register()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1791244800)
        let five = UsageWindow(slot: "primary", usedPercent: 82, windowDurationMins: 300, resetsAt: 1791257400)
        let week = UsageWindow(slot: "secondary", usedPercent: 58, windowDurationMins: 10080, resetsAt: 1791590400)
        var state = ResetEngineState()
        state.checkedAt = now; state.workerSeenAt = now; state.availableCount = 2
        state.inventory = [ResetCredit(id: "synthetic-credit", expiresAt: now.addingTimeInterval(1920))]
        state.notificationStatus = "authorized"
        var settings = ResetSettings(autoUse: true, reminders: true)
        func make(_ windows: [UsageWindow], failed: Bool = false) -> PopoverPresentation {
            let snapshot = UsagePayload(bucketLabel: "Codex", windows: windows,
                                        credits: CreditInfo(availableCount: state.availableCount, earliestExpiresAt: nil))
            let reset = ResetMenuPresentation.native(state: state, settings: settings, active: true, now: now, timeZone: PopoverPresentation.seoul)
            var model = PopoverPresentation(snapshot: snapshot, checkedAt: now, now: now,
                usageFailed: failed, reset: reset, state: state, settings: settings, active: true, native: true,
                details: NativeResetSection.rows(state: state, settings: settings, active: true, now: now)
                    + [localized("Synthetic fixture · no account requests", "가상 샘플 · 계정 요청 없음")])
            model.fixture = true
            return model
        }
        let controller = UsagePopoverController(model: make([five, week]))
        let view = controller.canvas
        _ = controller.view
        view.forceReducedMotion = true
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: UsagePopoverView.size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentViewController = controller
        func save(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            try view.png().write(to: directory.appendingPathComponent(name + ".png"))
        }
        try save("two-collapsed")
        view.setExpanded(true, animated: false); try save("two-expanded")
        view.model = make([week]); try save("one-weekly")
        view.model = make([five]); try save("one-five-hour")
        state.availableCount = nil; state.inventory = []
        view.model = make([]); try save("unknown")
        state.lastError = "queryFailed"; view.model = make([], failed: true); try save("failure")
        state.lastError = nil; state.availableCount = 2
        state.inventory = [ResetCredit(id: "synthetic-credit", expiresAt: now.addingTimeInterval(720))]
        state.attempts["synthetic-credit"] = Redemption(key: "synthetic-key", expiresAt: state.inventory[0].expiresAt, attemptedAt: now, outcome: "nothingToReset")
        state.phase = "checking"
        view.model = make([five, week]); try save("nothing-to-reset")
        state.attempts["synthetic-credit"]?.outcome = "pending"
        settings.autoUse = false
        view.model = make([five, week]); try save("pending-auto-off")
        view.setDetails(true); try save("details-pending")
        view.setDetails(false)
        state.attempts = [:]; settings.autoUse = true
        state.inventory[0] = ResetCredit(id: "synthetic-credit", expiresAt: now.addingTimeInterval(1920))
        view.model = make([five, week])
        var autoCalls = 0, reminderCalls = 0, refreshCalls = 0, closeCalls = 0
        view.onAutoUse = { autoCalls += 1; settings.autoUse.toggle(); view.model = make([five, week]) }
        view.onReminders = { reminderCalls += 1; settings.reminders.toggle(); view.model = make([five, week]) }
        view.onRefresh = { refreshCalls += 1; view.model = make([week]) }
        view.autoButton.performClick(nil)
        try check(autoCalls == 1 && !view.model.autoUse && view.switchProgress == 0, "mock auto-use toggles model and reduced-motion artwork")
        view.setDetails(true); view.reminderButton.performClick(nil)
        try check(reminderCalls == 1 && !view.model.reminders, "mock reminder toggle updates model")
        view.setDetails(false); view.refreshButton.performClick(nil)
        try check(refreshCalls == 1 && view.model.windows.count == 1, "mock refresh changes response windows")
        view.setExpanded(false); try check(view.ticketProgress == 0, "reduced motion collapses ticket")
        view.ticketButton.performClick(nil); try check(view.expanded && view.ticketProgress == 1, "ticket click expands immediately under reduce motion")
        try check(view.autoButton.accessibilityValue() as? Int == 0, "automatic-use accessible value matches saved setting")
        try check(view.reminderButton.accessibilityLabel() == localized("Expiry notifications", "만료 전 Mac 알림"), "reminder has accessible label")
        view.model.canEdit = false
        view.autoButton.performClick(nil); try check(autoCalls == 1, "disabled auto-use rejects clicks")
        view.model.canEdit = true
        // A failed save must restore the authoritative model and checkbox state.
        view.onAutoUse = { autoCalls += 1 }
        view.autoButton.performClick(nil)
        try check(!view.model.autoUse && view.autoButton.state == .off && view.switchProgress == 0, "failed auto-use save restores artwork and button")
        view.onReminders = { reminderCalls += 1 }
        view.setDetails(true); view.reminderButton.performClick(nil)
        try check(!view.model.reminders && view.reminderButton.state == .off, "failed reminder save restores button")
        view.setDetails(false)
        view.forceReducedMotion = false
        let normalAnimationExercised = !view.reducedMotion
        view.onAutoUse = { autoCalls += 1; settings.autoUse.toggle(); view.model = make([week]) }
        view.autoButton.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        try check(view.model.autoUse && view.switchProgress == 1, "normal switch animation finishes saved target")
        view.setExpanded(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        try check(!view.expanded && view.ticketProgress == 0, "normal ticket animation finishes target")
        // Exercise real NSPopover lifecycle against this process's temporary status item.
        // This records programmatic AppKit behavior, never a screen capture or physical click.
        host.contentViewController = nil
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.make(); item.button?.title = "UI fixture"
        defer { NSStatusBar.system.removeStatusItem(item) }
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        popover.contentSize = UsagePopoverView.size; popover.contentViewController = controller
        view.onClose = { closeCalls += 1; popover.performClose(nil) }
        func pump(_ seconds: TimeInterval = 0.15) {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) { app.sendEvent(event) }
                app.updateWindows()
            } while Date() < deadline
        }
        app.activate(ignoringOtherApps: true)
        pump(0.3)
        let anchor: [String: Any] = ["buttonFrame": NSStringFromRect(item.button!.frame),
                                    "windowVisible": item.button?.window?.isVisible ?? false,
                                    "appActive": app.isActive]
        try JSONSerialization.data(withJSONObject: anchor, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("anchor.json"))
        var cycles = 0
        for _ in 0..<3 {
            popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
            pump()
            try check(popover.isShown, "popover opens")
            try check(controller.view.bounds.size == UsagePopoverView.size, "popover content has approved size")
            try check(controller.view.window?.makeFirstResponder(view.ticketButton) == true, "ticket accepts keyboard focus")
            controller.view.window?.selectNextKeyView(view.ticketButton)
            try check(controller.view.window?.firstResponder === view.autoButton, "Tab reaches auto-use control")
            view.refreshButton.performClick(nil)
            try check(view.model.windows.count == 1, "refresh while open preserves new model")
            controller.cancelOperation(nil); pump()
            try check(!popover.isShown, "Escape action closes popover")
            cycles += 1
        }
        try check(closeCalls == 3, "three close callbacks")
        let report: [String: Any] = [
            "version": appVersion, "mode": "synthetic-only", "sizePoints": [660, 414],
            "renderPixels": [1320, 828], "screenCapture": false,
            "liveAccountRequests": 0, "settingsWrites": 0, "notificationPermissionRequests": 0,
            "programmaticPopoverCycles": cycles, "closeActions": closeCalls, "keyboardTabChecked": true,
            "mockAutoUseActions": autoCalls, "mockReminderActions": reminderCalls,
            "mockRefreshActions": refreshCalls, "reducedMotionChecked": true, "normalAnimationExercised": normalAnimationExercised,
            "mockSaveFailureRestored": true,
            "fontNames": [PopoverFonts.font(69, display: true).fontName, PopoverFonts.font(25).fontName, PopoverFonts.font(12, body: true).fontName],
            "unverified": ["Physical clicks", "VoiceOver speech", "Actual screen pixels", "Outside-click dismissal", "Live notification delivery"]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("verification.json"))
        print(String(data: data, encoding: .utf8)!)
    }
}
