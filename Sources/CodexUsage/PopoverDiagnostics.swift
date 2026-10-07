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
            host.makeFirstResponder(nil)
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
        // Coordinate-targeted card interactions use this view's actual hit testing.
        let baselineState = state
        var forbiddenCardCallbacks = 0
        view.onAutoUse = { forbiddenCardCallbacks += 1 }
        view.onReminders = { forbiddenCardCallbacks += 1 }
        view.onRefresh = { forbiddenCardCallbacks += 1 }
        state.inventory = []; state.availableCount = 0
        view.model = make([five, week]); try save("stack-zero")
        try check(view.visibleCredits.isEmpty && view.backCardButtons.allSatisfy(\.isHidden) && view.nextCardButton.isHidden, "zero cards have no stack or navigation")
        let first = ResetCredit(id: "synthetic-first", expiresAt: now.addingTimeInterval(720))
        let second = ResetCredit(id: "synthetic-second", expiresAt: now.addingTimeInterval(1920))
        let third = ResetCredit(id: "synthetic-third", expiresAt: now.addingTimeInterval(3600))
        state.inventory = [first]; state.availableCount = 1
        view.model = make([five, week]); try save("stack-one")
        try check(view.visibleCredits.count == 1 && view.nextCardButton.isHidden, "one card has no fake backing or navigation")
        let firstExpiry = PopoverPresentation.date(first.expiresAt)
        try check(view.ticketButton.accessibilityLabel()?.contains(firstExpiry) == true
                      && view.ticketButton.toolTip?.contains(firstExpiry) == true,
                  "collapsed credit exposes its Seoul expiry and action to assistive technology")
        try check(view.refreshButton.accessibilityLabel() == localized("Refresh usage", "사용량 새로고침")
                      && view.refreshButton.toolTip?.contains("⌘R") == true,
                  "icon refresh retains an explicit accessible name and shortcut hint")
        try check(view.autoButton.accessibilityLabel() == localized("Automatic credit use on", "자동 사용 켜짐"),
                  "enabled auto-use states its current setting")
        try check(make([five, week]).details.contains(where: { $0.contains(localized("regardless of remaining usage", "잔여량 무관")) }),
                  "Details explains the usage-independent final-20-minute rule")
        state.inventory = [third, first, second]; state.availableCount = 3
        view.model = make([five, week]); view.setExpanded(false, animated: false)
        try save("stack-three-default")
        func clickAtCenter(_ button: PopoverButton) throws {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view.superview)
            try check(view.hitTest(point) === button, "card coordinate resolves to intended button")
            (view.hitTest(point) as? NSButton)?.performClick(nil)
        }
        func checkCardEdges(_ button: PopoverButton) throws {
            for x in [CGFloat(1), button.bounds.midX, button.bounds.maxX - 1] {
                for y in [CGFloat(1), button.bounds.midY, button.bounds.maxY - 1] {
                    let point = button.convert(NSPoint(x: x, y: y), to: view.superview)
                    try check(view.hitTest(point) === button, "exposed card strip edge hits its own button")
                }
            }
        }
        for button in view.backCardButtons { try checkCardEdges(button) }
        try checkCardEdges(view.ticketButton)
        let back = view.backCardButtons[0]
        let frameBeforeHover = back.frame
        let point = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
        let hoverEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: host.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        back.mouseEntered(with: hoverEvent)
        try save("stack-three-hover")
        for button in view.backCardButtons { try checkCardEdges(button) }
        try checkCardEdges(view.ticketButton)
        try check(view.hoverLift(for: second.id) == 3 && view.selectedCredit?.id == first.id && back.frame == frameBeforeHover,
                  "reduced-motion hover lifts same card instantly without changing selection or hit frame")
        view.backCardButtons[1].mouseEntered(with: hoverEvent)
        back.mouseExited(with: hoverEvent)
        try check(view.hoveredCardID == third.id, "out-of-order old exit cannot clear new card hover")
        view.backCardButtons[1].mouseExited(with: hoverEvent)
        try clickAtCenter(back)
        try check(view.selectedCredit?.id == second.id && view.expanded, "back tab selects its real ID and immediately opens details")
        try save("stack-three-selected")
        try check(view.model.status == .ready && view.model.expiresAt == first.expiresAt, "selected later expiry cannot change overall policy or status")
        try clickAtCenter(view.ticketButton)
        try check(view.selectedCredit?.id == first.id && view.selection.selectedID == nil, "selected card click returns earliest default")
        try clickAtCenter(view.backCardButtons[1])
        try check(view.selectedCredit?.id == third.id, "far tab targets third card, not overlapping neighbor")
        view.backCardButtons[0].mouseEntered(with: hoverEvent)
        // Refresh keeps explicit identity and updates that card's expiry.
        state.inventory = [ResetCredit(id: first.id, expiresAt: now.addingTimeInterval(2400)), ResetCredit(id: third.id, expiresAt: now.addingTimeInterval(600)), second]
        view.model = make([five, week])
        try check(view.selectedCredit?.id == third.id && view.selectedCredit?.expiresAt == now.addingTimeInterval(600), "refresh reconciles changed expiry by identity")
        try check(view.hoveredCardID == nil, "refresh remapping clears hover rather than lifting another slot")
        state.inventory = [first, second]; state.availableCount = 2; view.model = make([five, week])
        try check(view.selectedCredit?.id == first.id && view.selection.selectedID == nil, "removed selection returns earliest")
        state.inventory = [ResetCredit(id: "synthetic-tie-b", expiresAt: second.expiresAt), ResetCredit(id: "synthetic-tie-a", expiresAt: second.expiresAt)]
        view.model = make([five, week]); try save("stack-tied")
        try check(view.selectedCredit?.id == "synthetic-tie-a", "tied expiry orders by stable ID")
        let extra = (4...6).map { ordinal in
            ResetCredit(id: "synthetic-\(ordinal)", expiresAt: now.addingTimeInterval(Double(3600 + ordinal * 1200)))
        }
        for amount in 4...6 {
            state.inventory = [third, first, second] + extra.prefix(amount - 3)
            state.availableCount = amount; view.model = make([five, week])
            if let selected = view.selectedCredit, selected.id != view.model.individualCredits.first?.id {
                view.selectCard(selected.id)
            }
            view.setExpanded(false, animated: false)
            try save("stack-\(amount)-default")
            try check(view.visibleCredits.count == amount && view.backCardButtons.count == amount - 1,
                      "\(amount) individual credits all have native card controls")
            for target in view.model.individualCredits {
                if view.selectedCredit?.id == target.id { continue }
                guard let index = view.visibleCredits.dropFirst().firstIndex(where: { $0.id == target.id }) else {
                    throw NSError(domain: "PopoverDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "card missing from backing strip"])
                }
                let button = view.backCardButtons[index - 1]
                try check(button.frame.width >= 44, "card exposes a 44 pt wide hit target")
                try checkCardEdges(button)
                let original = button.frame
                button.mouseEntered(with: hoverEvent)
                try check(view.hoveredCardID == target.id && view.hoverLift(for: target.id) == 3 && button.frame == original,
                          "every card supports stable direct hover")
                try clickAtCenter(button)
                try check(view.selectedCredit?.id == target.id && view.expanded, "each exposed card selects its own credit")
            }
            try save("stack-\(amount)-selected")
        }
        state.inventory = (0..<12).map { ResetCredit(id: "synthetic-many-\($0)", expiresAt: now.addingTimeInterval(Double(900 + $0 * 120))) }
        state.availableCount = 12; view.model = make([five, week])
        for ordinal in 0..<12 {
            try check(view.selection.index(in: view.model.individualCredits) == ordinal && view.visibleCredits.count == 12,
                      "all many-card positions remain in the same real control strip")
            if ordinal < 11 { try clickAtCenter(view.nextCardButton) }
        }
        try save("stack-many-last")
        try check(!view.nextCardButton.isEnabled && view.previousCardButton.isEnabled, "many-card navigation has honest endpoints")
        view.moveCard(-5); try save("stack-many-selected")
        let farID = view.visibleCredits.last!.id
        let farButton = view.backCardButtons.last!
        try check(farButton.frame.width >= 44 && farButton.scrollToVisible(farButton.bounds),
                  "overflow cards keep a scrollable 44 pt target")
        try clickAtCenter(farButton)
        try check(view.selectedCredit?.id == farID, "last card is directly clickable after scrolling")
        let firstBackingID = view.visibleCredits[1].id
        let firstBackingButton = view.backCardButtons[0]
        try check(firstBackingButton.scrollToVisible(firstBackingButton.bounds), "first tab scrolls back into view")
        try clickAtCenter(firstBackingButton)
        try check(view.selectedCredit?.id == firstBackingID, "first tab remains directly clickable after scrolling back")
        state.availableCount = 2; view.model = make([five, week]); try save("stack-count-mismatch")
        try check(view.model.individualCredits.count == 12 && !view.model.warnings.isEmpty, "mismatched total does not hide observed cards")
        state.checkedAt = now.addingTimeInterval(-181); view.model = make([five, week]); try save("stack-stale")
        try check(view.visibleCredits.isEmpty, "stale inventory removes selectable cards")
        state.checkedAt = now; state.availableCount = 1
        state.inventory = [ResetCredit(id: "synthetic-expired", expiresAt: now.addingTimeInterval(-60))]
        view.model = make([five, week]); try save("stack-expired")
        try check(view.visibleCredits.isEmpty && view.backCardButtons.allSatisfy(\.isHidden),
                  "expired credit does not remain a selectable live card")
        state.checkedAt = now; state.inventory = [first, second, third]; state.availableCount = 3
        state.attempts["synthetic-pending"] = Redemption(key: "synthetic", expiresAt: first.expiresAt, attemptedAt: now, outcome: "pending")
        view.model = make([five, week]); view.selectCard(third.id); try save("stack-pending-selected")
        try check(view.model.status == .pending, "card selection cannot conceal pending outcome")
        try check(forbiddenCardCallbacks == 0, "all card actions call no settings, refresh or consumption callback")
        state.attempts = [:]; view.model = make([five, week]); view.selectCard(third.id)
        view.forceReducedMotion = false
        let animatedCard = view.visibleCredits[1]
        view.hoverCard(animatedCard.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.24))
        try check(view.hoverLift(for: animatedCard.id) == 3, "normal hover animation reaches lift")
        view.hoverCard(nil); RunLoop.current.run(until: Date().addingTimeInterval(0.24))
        try check(view.hoverLift(for: animatedCard.id) == 0, "normal hover animation returns")
        view.forceReducedMotion = true
        state = baselineState; view.model = make([five, week])
        var autoCalls = 0, reminderCalls = 0, refreshCalls = 0, closeCalls = 0
        view.onAutoUse = { autoCalls += 1; settings.autoUse.toggle(); view.model = make([five, week]) }
        view.onReminders = { reminderCalls += 1; settings.reminders.toggle(); view.model = make([five, week]) }
        view.onRefresh = { refreshCalls += 1; view.model = make([week]) }
        view.autoButton.performClick(nil)
        try check(autoCalls == 1 && !view.model.autoUse && view.switchProgress == 0, "mock auto-use toggles model and reduced-motion artwork")
        try check(view.autoButton.accessibilityLabel() == localized("Automatic credit use off", "자동 사용 꺼짐")
                      && view.autoButton.toolTip?.contains(localized("click to turn on", "클릭하면 켬")) == true,
                  "off switch text and tooltip describe the next action")
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
            if cycles == 0 {
                state.inventory = [first, second, third]; state.availableCount = 3
                view.model = make([five, week])
                func key(_ code: UInt16, _ chars: String) -> NSEvent {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: controller.view.window!.windowNumber, context: nil, characters: chars,
                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                }
                view.ticketButton.keyDown(with: key(124, "\u{F703}"))
                try check(view.selectedCredit?.id == second.id, "Right arrow selects next actual credit")
                view.ticketButton.keyDown(with: key(36, "\r"))
                try check(view.selectedCredit?.id == first.id, "Enter on selected returns earliest")
                view.ticketButton.keyDown(with: key(124, "\u{F703}"))
                view.ticketButton.keyDown(with: key(49, " "))
                try check(view.selectedCredit?.id == first.id, "Space on selected returns earliest")
                controller.view.window?.makeFirstResponder(view.ticketButton)
                controller.view.window?.selectNextKeyView(view.ticketButton)
                try check(controller.view.window?.firstResponder === view.backCardButtons[0], "Tab reaches exposed card tab")
                state = baselineState; view.model = make([week])
            }
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
            "programmaticPopoverCycles": cycles, "closeActions": closeCalls, "keyboardTabChecked": true, "creditStackChecks": "passed", "cardActionSettingCallbacks": forbiddenCardCallbacks,
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
