import AppKit
import CoreText

/// Fonts are registered only inside this process; no system font installation.
enum PopoverFonts {
    static func register() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
        for name in ["Paperlogy-9Black.ttf", "Pretendard-Bold.otf", "Pretendard-SemiBold.otf", "Pretendard-Black.otf"] {
            CTFontManagerRegisterFontsForURL(root.appendingPathComponent(name) as CFURL, .process, nil)
        }
    }
    static func font(_ size: CGFloat, display: Bool = false, body: Bool = false) -> NSFont {
        NSFont(name: display ? "Paperlogy-9Black" : body ? "Pretendard-SemiBold" : "Pretendard-Bold", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: display ? .black : body ? .semibold : .bold)
    }
}

private enum Palette {
    static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let ink = color(0x171C1B), paper = color(0xF5F2E9), white = color(0xFFFFFA)
    static let lime = color(0xDDFB70), apricot = color(0xFFB074), muted = color(0x53614F)
    static let track = color(0xE6EADC), rule = color(0xDADFD1)
}

/// Real NSButtons provide key-view traversal and accessibility actions over vector artwork.
final class PopoverButton: NSButton {
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onArrow: ((Int) -> Void)?
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func keyDown(with event: NSEvent) {
        if let onArrow {
            if [123, 126].contains(event.keyCode) { onArrow(-1); return }
            if [124, 125].contains(event.keyCode) { onArrow(1); return }
            if [36, 76, 49].contains(event.keyCode) { performClick(nil); return }
        }
        super.keyDown(with: event)
    }
    init(label: String, frame: NSRect) {
        super.init(frame: frame)
        title = label; isBordered = false; bezelStyle = .regularSquare
        target = self; action = #selector(press); focusRingType = .none
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func press() { if isEnabled { onPress?() } }
    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            Palette.apricot.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            path.lineWidth = 2; path.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
}

/// Every observed backing credit gets its own tab. The scroll view clips only
/// the viewport; it never reduces the number of real buttons in this strip.
final class CreditTabStripView: NSView {
    var credits: [(number: Int, credit: ResetCredit)] = [] { didSet { needsDisplay = true } }
    var tabWidth: CGFloat = 224 { didSet { needsDisplay = true } }
    var hoverLift: ((String) -> CGFloat)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let colors = [0xB6C194, 0xCFD8B0, 0xB9D0A3, 0xD7DCAE, 0xAFCB9D]
        for (index, entry) in credits.enumerated() {
            let lift = hoverLift?(entry.credit.id) ?? 0
            let rect = NSRect(x: CGFloat(index) * tabWidth + 1, y: 3 - lift,
                              width: tabWidth - 2, height: 28)
            guard rect.intersects(dirtyRect) else { continue }
            Palette.color(colors[index % colors.count]).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = PopoverPresentation.seoul
            let components = calendar.dateComponents([.month, .day], from: entry.credit.expiresAt)
            let number = localized("#\(entry.number)", "\(entry.number)번")
            let label = tabWidth >= 70
                ? "\(number) · \(components.month ?? 0)/\(components.day ?? 0)" : number
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (label as NSString).draw(in: NSRect(x: rect.minX + 2, y: rect.minY + 6,
                                                width: rect.width - 4, height: 17),
                                     withAttributes: [.font: PopoverFonts.font(10, body: true),
                                                      .foregroundColor: Palette.ink,
                                                      .paragraphStyle: paragraph])
        }
    }
}

final class UsagePopoverView: NSView {
    static let size = NSSize(width: 660, height: 414)
    var model: PopoverPresentation {
        didSet {
            let oldMapping = selection.visible(in: oldValue.individualCredits).map(\.id)
            selection.reconcile(model.individualCredits)
            if oldMapping != visibleCredits.map(\.id) { hoverCard(nil) }
            updateControls()
        }
    }
    var onClose: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onAutoUse: (() -> Void)?
    var onReminders: (() -> Void)?
    var onQuit: (() -> Void)?
    private(set) var selection = CreditStackSelection()
    private(set) var hoveredCardID: String?
    private var hoverLevels: [String: CGFloat] = [:]
    private var hoverStarts: [String: CGFloat] = [:]
    private var hoverBegan = Date.distantPast
    var selectedCredit: ResetCredit? { selection.front(in: model.individualCredits) }
    var visibleCredits: [ResetCredit] { selection.visible(in: model.individualCredits) }
    private(set) var expanded = false
    private(set) var showingDetails = false
    private(set) var ticketProgress: CGFloat = 0
    private(set) var switchProgress: CGFloat = 0
    var forceReducedMotion = false
    private var animationTimer: Timer?
    private var renderedAutoUse = false
    private var ticketStart: CGFloat = 0, switchStart: CGFloat = 0
    private var ticketBegan = Date.distantPast, switchBegan = Date.distantPast
    let closeButton = PopoverButton(label: localized("Close", "닫기"), frame: NSRect(x: 605, y: 16, width: 36, height: 34))
    let ticketButton = PopoverButton(label: localized("Expand credit expiry", "리셋권 만료 상세 펼치기"), frame: NSRect(x: 410, y: 97, width: 224, height: 91))
    private(set) var backCardButtons: [PopoverButton] = []
    private let cardScroll = NSScrollView()
    private let cardStrip = CreditTabStripView()
    let previousCardButton = PopoverButton(label: localized("Previous credit", "이전 리셋권"), frame: NSRect(x: 410, y: 246, width: 28, height: 20))
    let nextCardButton = PopoverButton(label: localized("Next credit", "다음 리셋권"), frame: NSRect(x: 606, y: 246, width: 28, height: 20))
    let autoButton = PopoverButton(label: localized("Automatic credit use", "리셋권 자동 사용"), frame: NSRect(x: 545, y: 268, width: 89, height: 42))
    let statusButton = PopoverButton(label: localized("Reset status details", "리셋 처리 상태 상세"), frame: NSRect(x: 410, y: 325, width: 224, height: 29))
    let refreshButton = PopoverButton(label: localized("Refresh", "새로고침"), frame: NSRect(x: 24, y: 384, width: 88, height: 25))
    let detailsButton = PopoverButton(label: localized("Details & settings", "상세 · 알림 설정"), frame: NSRect(x: 122, y: 384, width: 140, height: 25))
    let quitButton = PopoverButton(label: localized("Quit", "종료"), frame: NSRect(x: 584, y: 384, width: 52, height: 25))
    let reminderButton = NSButton(checkboxWithTitle: localized("Expiry notifications", "만료 전 Mac 알림"), target: nil, action: nil)
    private let scroll = NSScrollView()
    private let detailText = NSTextView()
    private var readableElements: [NSAccessibilityElement] = []

    init(model: PopoverPresentation) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        appearance = NSAppearance(named: .aqua)
        switchProgress = model.autoUse ? 1 : 0
        renderedAutoUse = model.autoUse
        setAccessibilityElement(false)
        closeButton.onPress = { [weak self] in self?.onClose?() }
        ticketButton.onPress = { [weak self] in self?.clickFrontCard() }
        ticketButton.onHover = { [weak self] entered in
            guard let self else { return }; self.trackCardHover(self.selectedCredit?.id, entered: entered)
        }
        ticketButton.onArrow = { [weak self] delta in self?.moveCard(delta) }
        previousCardButton.onPress = { [weak self] in self?.moveCard(-1) }
        nextCardButton.onPress = { [weak self] in self?.moveCard(1) }
        cardScroll.frame = NSRect(x: 410, y: 74, width: 224, height: 31)
        cardScroll.drawsBackground = false; cardScroll.contentView.drawsBackground = false
        // The strip scrolls with a trackpad; an overlay scroller would cover
        // the small tab hit targets while it is visible.
        cardScroll.borderType = .noBorder; cardScroll.hasHorizontalScroller = false
        cardStrip.frame = NSRect(x: 0, y: 0, width: 224, height: 31)
        cardStrip.hoverLift = { [weak self] id in self?.hoverLift(for: id) ?? 0 }
        cardScroll.documentView = cardStrip; addSubview(cardScroll)
        autoButton.onPress = { [weak self] in self?.onAutoUse?(); self?.updateControls() }
        statusButton.onPress = { [weak self] in self?.setDetails(true) }
        refreshButton.onPress = { [weak self] in self?.onRefresh?() }
        detailsButton.onPress = { [weak self] in self?.setDetails(!(self?.showingDetails ?? false)) }
        quitButton.onPress = { [weak self] in self?.onQuit?() }
        autoButton.setButtonType(.switch)
        for button in [ticketButton, previousCardButton, nextCardButton, autoButton, statusButton, refreshButton, detailsButton, quitButton, closeButton] { addSubview(button) }
        scroll.frame = NSRect(x: 28, y: 142, width: 606, height: 218)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        detailText.isEditable = false; detailText.isSelectable = true; detailText.drawsBackground = false
        detailText.font = PopoverFonts.font(14, body: true); detailText.textColor = Palette.ink
        detailText.textContainerInset = NSSize(width: 2, height: 4)
        detailText.autoresizingMask = [.width]; detailText.isVerticallyResizable = true
        detailText.textContainer?.widthTracksTextView = true
        detailText.frame = NSRect(x: 0, y: 0, width: 588, height: 218)
        detailText.setAccessibilityLabel(localized("Usage and reset details", "사용량·리셋권 상세"))
        scroll.documentView = detailText; addSubview(scroll)
        reminderButton.frame = NSRect(x: 28, y: 98, width: 500, height: 28)
        reminderButton.font = PopoverFonts.font(16); reminderButton.target = self
        reminderButton.action = #selector(toggleReminder)
        reminderButton.setAccessibilityLabel(localized("Expiry notifications", "만료 전 Mac 알림"))
        addSubview(reminderButton)
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { animationTimer?.invalidate() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "r" { if !model.refreshing { onRefresh?() }; return true }
            if event.charactersIgnoringModifiers == "q" { onQuit?(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func toggleReminder() { onReminders?(); updateControls() }

    func selectCard(_ id: String) {
        selection.select(id, in: model.individualCredits)
        hoverCard(nil)
        setExpanded(true)
        window?.makeFirstResponder(ticketButton)
    }
    private func clickFrontCard() {
        if let selectedCredit, selectedCredit.id != model.individualCredits.first?.id {
            selectCard(selectedCredit.id)
        } else {
            if let selectedCredit { selection.select(selectedCredit.id, in: model.individualCredits) }
            setExpanded(!expanded)
        }
    }
    func moveCard(_ delta: Int) {
        selection.move(delta, in: model.individualCredits)
        hoverCard(nil); setExpanded(true)
        window?.makeFirstResponder(ticketButton)
    }
    private func trackCardHover(_ id: String?, entered: Bool) {
        if entered { hoverCard(id) }
        else if hoveredCardID == id { hoverCard(nil) }
    }
    func hoverCard(_ id: String?) {
        let valid = id.flatMap { candidate in visibleCredits.contains(where: { $0.id == candidate }) ? candidate : nil }
        guard valid != hoveredCardID else { return }
        hoveredCardID = valid; hoverStarts = hoverLevels; hoverBegan = Date()
        if reducedMotion {
            hoverLevels = valid.map { [$0: 1] } ?? [:]; cardStrip.needsDisplay = true; needsDisplay = true
        } else { startAnimation() }
    }
    func hoverLift(for id: String) -> CGFloat { 3 * (hoverLevels[id] ?? 0) }
    private func cardLabel(_ credit: ResetCredit) -> String {
        let position = (model.individualCredits.firstIndex(where: { $0.id == credit.id }) ?? 0) + 1
        return localized("Credit \(position) of \(model.individualCredits.count)", "리셋권 \(position) / \(model.individualCredits.count)")
            + " · " + PopoverPresentation.date(credit.expiresAt)
    }

    func setExpanded(_ value: Bool, animated: Bool = true) {
        ticketStart = ticketProgress; ticketBegan = Date(); expanded = value
        if !animated || reducedMotion { ticketProgress = value ? 1 : 0 }
        else { startAnimation() }
        updateControls()
    }
    func setDetails(_ value: Bool) {
        showingDetails = value; updateControls()
        window?.makeFirstResponder(value ? reminderButton : detailsButton)
    }
    var reducedMotion: Bool { forceReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.animate() }
        animationTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func animate() {
        func ease(_ elapsed: Double, _ duration: Double) -> CGFloat {
            let t = reducedMotion ? 1 : min(1, max(0, elapsed / duration))
            return CGFloat(t * t * (3 - 2 * t))
        }
        let ticket = ease(Date().timeIntervalSince(ticketBegan), 0.4)
        let toggle = ease(Date().timeIntervalSince(switchBegan), 0.25)
        ticketProgress = ticketStart + ((expanded ? 1 : 0) - ticketStart) * ticket
        switchProgress = switchStart + ((model.autoUse ? 1 : 0) - switchStart) * toggle
        let hover = ease(Date().timeIntervalSince(hoverBegan), 0.18)
        for id in Set(hoverStarts.keys).union(hoveredCardID.map { [$0] } ?? []) {
            let start = hoverStarts[id] ?? 0
            hoverLevels[id] = start + ((hoveredCardID == id ? 1 : 0) - start) * hover
        }
        cardStrip.needsDisplay = true; needsDisplay = true
        if ticket == 1 && toggle == 1 && hover == 1 {
            hoverLevels = hoveredCardID.map { [$0: 1] } ?? [:]
            animationTimer?.invalidate(); animationTimer = nil
        }
    }
    private func updateControls() {
        selection.reconcile(model.individualCredits)
        if let hoveredCardID, !visibleCredits.contains(where: { $0.id == hoveredCardID }) { hoverCard(nil) }
        let target: CGFloat = model.autoUse ? 1 : 0
        if renderedAutoUse != model.autoUse {
            renderedAutoUse = model.autoUse
            switchStart = switchProgress; switchBegan = Date()
            if reducedMotion { switchProgress = target } else { startAnimation() }
        }
        autoButton.state = model.autoUse ? .on : .off
        autoButton.setAccessibilityValue(model.autoUse ? 1 : 0)
        autoButton.isEnabled = model.canEdit
        autoButton.toolTip = model.canEdit ? localized("Change automatic credit use", "자동 사용 설정 변경") : localized("Worker/settings unavailable", "실행기·설정 확인 필요")
        reminderButton.state = model.reminders ? .on : .off; reminderButton.isEnabled = model.canEdit
        refreshButton.isEnabled = !model.refreshing
        ticketButton.frame = NSRect(x: 410, y: 105, width: 224, height: expanded ? 139 : 83)
        let returnToDefault = selectedCredit != nil && selectedCredit?.id != model.individualCredits.first?.id
        ticketButton.setAccessibilityLabel(returnToDefault ? localized("Return to earliest credit", "가장 먼저 만료되는 리셋권으로 돌아가기")
            : expanded ? localized("Collapse credit expiry", "리셋권 만료 상세 접기") : localized("Expand credit expiry", "리셋권 만료 상세 펼치기"))
        ticketButton.setAccessibilityExpanded(expanded)
        ticketButton.setAccessibilityValue(selectedCredit.map(cardLabel) ?? localized("Individual credit information unavailable", "개별 리셋권 정보 미제공"))
        ticketButton.toolTip = (selectedCredit.map(cardLabel) ?? localized("No individual credit details", "개별 리셋권 정보 없음"))
            + localized(" · Selection only · Left/Right to browse", " · 정보 선택만 · 좌우 화살표로 이동")
        let backing = Array(visibleCredits.dropFirst())
        while backCardButtons.count < backing.count {
            let index = backCardButtons.count
            let button = PopoverButton(label: localized("Choose credit", "리셋권 선택"), frame: .zero)
            button.onPress = { [weak self] in
                guard let self, self.visibleCredits.indices.contains(index + 1) else { return }
                self.selectCard(self.visibleCredits[index + 1].id)
            }
            button.onHover = { [weak self] entered in
                guard let self, self.visibleCredits.indices.contains(index + 1) else { return }
                self.trackCardHover(self.visibleCredits[index + 1].id, entered: entered)
            }
            button.onArrow = { [weak self] delta in self?.moveCard(delta) }
            cardStrip.addSubview(button); backCardButtons.append(button)
        }
        while backCardButtons.count > backing.count { backCardButtons.removeLast().removeFromSuperview() }
        // Five backing tabs fit side by side. Past that, each retains a 44 pt
        // hit target and the native scroll view exposes the rest on demand.
        let width = max(44, 224 / CGFloat(max(1, backing.count)))
        let contentWidth = max(224, width * CGFloat(backing.count))
        cardStrip.setFrameSize(NSSize(width: contentWidth, height: 31))
        cardStrip.tabWidth = width
        cardStrip.credits = backing.map { card in
            ((model.individualCredits.firstIndex(where: { $0.id == card.id }) ?? 0) + 1, card)
        }
        cardScroll.isHidden = showingDetails || backing.isEmpty
        for (index, button) in backCardButtons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * width, y: 3, width: width, height: 28)
            button.isHidden = showingDetails
            button.setAccessibilityLabel(cardLabel(backing[index]))
            button.toolTip = cardLabel(backing[index])
        }
        let ordinal = selection.index(in: model.individualCredits) ?? 0
        previousCardButton.isHidden = showingDetails || model.individualCredits.count < 2
        nextCardButton.isHidden = previousCardButton.isHidden
        previousCardButton.isEnabled = ordinal > 0
        nextCardButton.isEnabled = ordinal + 1 < model.individualCredits.count
        statusButton.setAccessibilityValue(model.status.title + (model.warnings.isEmpty ? "" : " · " + model.warnings.joined(separator: " · ")))
        statusButton.toolTip = model.readout.joined(separator: "\n")
        detailsButton.setAccessibilityLabel(showingDetails ? localized("Back to usage", "사용량으로 돌아가기") : localized("Details & settings", "상세 · 알림 설정"))
        scroll.isHidden = !showingDetails; reminderButton.isHidden = !showingDetails
        for button in [ticketButton, autoButton, statusButton] { button.isHidden = showingDetails }
        let selectedDetail = selectedCredit.map { [localized("Selected for display: ", "표시 중인 권: ") + cardLabel($0)] } ?? []
        let detail = (selectedDetail + model.readout).joined(separator: "\n\n")
        if detailText.string != detail { detailText.string = detail }
        detailText.layoutManager?.ensureLayout(for: detailText.textContainer!)
        let height = detailText.layoutManager?.usedRect(for: detailText.textContainer!).height ?? 218
        detailText.setFrameSize(NSSize(width: 588, height: max(218, height + 16)))
        readableElements = model.readout.prefix(model.windows.count + 1).map { text in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText); element.setAccessibilityLabel(text)
            element.setAccessibilityParent(self)
            return element
        }
        let cardControls = [ticketButton] + backCardButtons.filter { !$0.isHidden }
            + [previousCardButton, nextCardButton].filter { !$0.isHidden }
        let visible: [Any] = showingDetails ? [closeButton, reminderButton, scroll, refreshButton, detailsButton, quitButton]
            : readableElements + [closeButton] + cardControls + [autoButton, statusButton, refreshButton, detailsButton, quitButton]
        setAccessibilityChildren(visible)
        let keyViews: [NSView] = showingDetails
            ? [reminderButton, detailText, refreshButton, detailsButton, quitButton, closeButton]
            : cardControls + [autoButton, statusButton, refreshButton, detailsButton, quitButton, closeButton]
        for index in keyViews.indices { keyViews[index].nextKeyView = keyViews[(index + 1) % keyViews.count] }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(NSRect(origin: .zero, size: Self.size), radius: 22, color: Palette.white)
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
        Palette.color(0xD7DCCF).setStroke(); edge.lineWidth = 1; edge.stroke()
        text(showingDetails ? localized("Details & settings", "상세 · 알림 설정") : "Codex Usage", x: 25, y: 23, size: 25)
        let subtitle: String
        if !model.warnings.isEmpty { subtitle = "⚠ " + model.warnings[0] + (model.warnings.count > 1 ? " · +\(model.warnings.count - 1)" : "") }
        else if model.usageFailed { subtitle = localized("Latest check failed · previous values", "최근 조회 실패 · 이전 확인 값") }
        else if model.refreshing { subtitle = localized("Refreshing…", "새로고침 중…") }
        else { subtitle = (model.fixture ? localized("Sample · ", "샘플 · ") : localized("Checked · ", "확인 · ")) + (model.checkedAt.map { PopoverPresentation.date($0, timeOnly: true) } ?? localized("Waiting for data", "조회 대기")) }
        text(subtitle, x: 27, y: 59, size: 12, color: Palette.muted, body: true, maxWidth: 580)
        line((617, 27), (629, 39), Palette.muted, 1.6); line((629, 27), (617, 39), Palette.muted, 1.6)
        line((24, 378), (636, 378), Palette.rule, 1)
        text(model.refreshing ? localized("Refreshing…", "새로고침 중…") : localized("Refresh", "새로고침"), x: 28, y: 392, size: 11, color: Palette.muted, body: true)
        text(showingDetails ? localized("← Usage", "← 사용량") : localized("Details · alerts", "상세 · 알림 설정") + (model.warnings.isEmpty ? "" : " •"), x: 128, y: 392, size: 11, color: Palette.muted, body: true)
        text("v" + appVersion, x: 540, y: 392, size: 11, color: Palette.muted, body: true, right: true)
        text(localized("Quit", "종료"), x: 629, y: 392, size: 11, color: Palette.muted, body: true, right: true)
        guard !showingDetails else { return }
        line((390, 96), (390, 360), Palette.rule, 1.1)
        drawUsage(); drawTicket(); drawSwitch()
    }

    private func drawUsage() {
        let windows = model.windows
        if windows.isEmpty {
            text(model.refreshing ? localized("Checking", "확인 중") : model.usageFailed ? localized("Check needed", "확인 필요") : localized("No data", "정보 미제공"), x: 28, y: 116, size: 39, display: true, maxWidth: 346)
            text(model.usageFailed ? localized("Usage check failed.", "조회에 실패했어요.") : localized("No usage windows provided.", "사용량 구간이 없어요."), x: 28, y: 182, size: 19, color: Palette.muted, maxWidth: 346)
            text(localized("Not zero or unlimited.", "0%나 무제한을 뜻하지 않습니다."), x: 28, y: 220, size: 14, color: Palette.muted, body: true)
            fill(NSRect(x: 28, y: 287, width: 346, height: 27), radius: 13.5, color: Palette.track)
            text("—", x: 368, y: 335, size: 28, color: Palette.muted, right: true)
            return
        }
        let single = windows.count == 1
        for (index, window) in windows.prefix(2).enumerated() {
            let y: CGFloat = 106 + CGFloat(single ? 0 : index * 128)
            text(PopoverPresentation.label(window), x: 28, y: y, size: single || index == 0 ? 29 : 24, display: true, maxWidth: single ? 346 : 174)
            let size: CGFloat = single ? 122 : index == 0 ? 69 : 56
            text("\(window.remainingPercent)%", x: 368, y: single ? 219 : y + 19, size: size, display: true, right: true, middle: true, maxWidth: single ? 346 : 180)
            let gy: CGFloat = single ? 286 : y + 54
            fill(NSRect(x: 28, y: gy, width: 346, height: 27), radius: 13.5, color: Palette.track)
            let width = 346 * CGFloat(window.remainingPercent) / 100
            if width > 0 {
                fill(NSRect(x: 28, y: gy, width: width, height: 27), radius: min(13.5, width / 2), color: window.windowDurationMins == 300 ? Palette.lime : Palette.color(0xB7C784))
                dot(28 + width, gy + 13.5, 2.6, Palette.ink)
            }
            let reset = window.resetsAt.map { PopoverPresentation.date(Date(timeIntervalSince1970: Double($0))) } ?? localized("Time unavailable", "시각 미제공")
            text(localized("Resets ", "초기화 ") + reset, x: 28, y: gy + 43, size: 12, color: Palette.muted, body: true, maxWidth: 346)
        }
    }
    private func drawTicket() {
        NSGraphicsContext.saveGraphicsState()
        let lift = selectedCredit.map { hoverLift(for: $0.id) } ?? 0
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: -lift)
        drawFrontTicket()
        NSGraphicsContext.restoreGraphicsState()
        if model.individualCredits.count > 1 {
            let ordinal = (selection.index(in: model.individualCredits) ?? 0) + 1
            text("‹", x: 424, y: 254, size: 20, color: previousCardButton.isEnabled ? Palette.ink : Palette.rule, middle: true, center: true)
            text("›", x: 620, y: 254, size: 20, color: nextCardButton.isEnabled ? Palette.ink : Palette.rule, middle: true, center: true)
            let count = model.count.map(String.init) ?? "?"
            let caption = model.count == model.individualCredits.count
                ? model.individualCredits.count > 6
                    ? localized("\(ordinal) / \(model.individualCredits.count) · scroll tabs", "선택 \(ordinal) / \(model.individualCredits.count) · 좌우 스크롤")
                    : localized("\(ordinal) / \(model.individualCredits.count) · expiry order", "선택 \(ordinal) / \(model.individualCredits.count) · 만료순")
                : localized("\(ordinal)/\(model.individualCredits.count) details · total \(count)", "정보 \(ordinal)/\(model.individualCredits.count) · 보유 \(count)")
            text(caption, x: 522, y: 252, size: 10, color: Palette.muted, body: true, center: true, maxWidth: 166)
        } else if model.count != model.individualCredits.count, model.count != 0 {
            text(model.individualCredits.isEmpty ? localized("Individual details unavailable", "개별 리셋권 정보 미제공")
                 : localized("1 credit detailed · total \(model.count.map(String.init) ?? "?")", "개별 정보 1장 · 보유 \(model.count.map(String.init) ?? "?")장"),
                 x: 410, y: 252, size: 10, color: Palette.muted, body: true, maxWidth: 224)
        }
    }
    private func drawFrontTicket() {
        let q = ticketProgress, known = model.count.map { $0 > 0 } == true
        let color = known ? Palette.lime.blended(withFraction: q, of: Palette.apricot)! : Palette.color(0xE9EBDD)
        fill(NSRect(x: 410, y: 105, width: 224, height: 83 + 56 * q), radius: 12, color: color)
        dot(410, 151, 5.6, Palette.white); dot(634, 151, 5.6, Palette.white)
        text(localized("Credits", "리셋권"), x: 424, y: 118, size: 26, display: true, maxWidth: 120)
        text(model.count.map { localized("\($0)", "\($0)장") } ?? "—", x: 620, y: 134, size: 34, display: true, right: true, middle: true, maxWidth: 91)
        for x in stride(from: 421, to: 624, by: 9) { line((CGFloat(x), 152), (CGFloat(x + 4), 152), Palette.color(0x8A744C), 0.75) }
        let ordinal = selection.index(in: model.individualCredits).map { $0 + 1 }
        if q < 1 {
            let label = ordinal.map { localized("Credit \($0) · view expiry", "\($0)번 · 만료 확인") }
                ?? (known ? localized("View earliest expiry", "첫 만료 확인") : localized("Check details", "정보 확인"))
            text(label, x: 424, y: 164, size: 17, color: Palette.ink.withAlphaComponent(1 - q), maxWidth: 194)
        }
        if q > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(q)
            let expiry = selectedCredit?.expiresAt ?? model.expiresAt
            text(ordinal.map { localized("#\($0) expires in", "\($0)번 만료까지") } ?? localized("Expires in", "만료까지"),
                 x: 424, y: 166, size: ordinal == nil ? 17 : 13, maxWidth: 100)
            text(model.expiryValue(for: expiry), x: 620, y: 183, size: expiry == nil ? 26 : 36, display: true, right: true, middle: true, maxWidth: 114)
            if let date = expiry {
                line((426, 208), (618, 208), Palette.ink, 2.6); dot(426, 208, 4.5, Palette.ink); dot(618, 208, 4.5, Palette.ink)
                text(localized("Now", "지금"), x: 424, y: 218, size: 13, body: true)
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = PopoverPresentation.seoul
                text(PopoverPresentation.date(date, timeOnly: calendar.isDate(date, inSameDayAs: model.now)), x: 620, y: 218, size: 13, body: true, right: true, maxWidth: 150)
            } else { text(localized("Latest information needed", "최신 정보 확인 필요"), x: 424, y: 217, size: 13, color: Palette.muted, body: true, maxWidth: 196) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func drawSwitch() {
        text(localized("Auto-use", "자동 사용"), x: 410, y: 277, size: 25, display: true, maxWidth: 127)
        let color = Palette.color(0xADB4AA).blended(withFraction: switchProgress, of: Palette.lime)!
        fill(NSRect(x: 545, y: 268, width: 89, height: 42), radius: 21, color: color)
        let cx = 566 + 47 * switchProgress
        dot(cx, 289, 16.6, Palette.white)
        if switchProgress > 0.5 { line((cx, 284), (cx, 294), Palette.ink, 3) }
        line((588, 312), (588, 324), Palette.muted, 1.5)
        fill(NSRect(x: 410, y: 325, width: 224, height: 29), radius: 14.5, color: Palette.ink)
        dot(425, 339.5, 3, Palette.apricot)
        text(model.status.title, x: 527, y: 339.5, size: 18, color: Palette.lime, display: true, middle: true, center: true, maxWidth: 186)
        text(localized("Final 20 min · any usage level", "만료 20분 이내 · 잔여량 무관"), x: 410, y: 362, size: 12, color: Palette.muted, maxWidth: 224)
    }
    private func fill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    private func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: NSColor) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
    }
    private func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), _ color: NSColor, _ width: CGFloat) {
        let path = NSBezierPath(); path.move(to: NSPoint(x: a.0, y: a.1)); path.line(to: NSPoint(x: b.0, y: b.1)); path.lineWidth = width; color.setStroke(); path.stroke()
    }
    // Place real font glyph outlines at the same ink anchors as the approved artwork.
    private func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = Palette.ink,
                      display: Bool = false, body: Bool = false, right: Bool = false, middle: Bool = false,
                      center: Bool = false, maxWidth: CGFloat? = nil) {
        var font = PopoverFonts.font(size, display: display, body: body)
        func makeLine() -> CTLine { CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])) }
        var line = makeLine(); var box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if let width = maxWidth, box.width > width {
            font = PopoverFonts.font(size * width / box.width, display: display, body: body)
            line = makeLine(); box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: x - box.minX - (right ? box.width : center ? box.width / 2 : 0), y: y + box.maxY - (middle ? box.height / 2 : 0))
        context.scaleBy(x: 1, y: -1); context.textPosition = .zero; CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Render this very same view at Retina scale; this is not a screenshot.
    func png() throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 828,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.size = Self.size
        guard let context = NSGraphicsContext(bitmapImageRep: image) else { throw ResetStorageError.invalid }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        displayIgnoringOpacity(bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = image.representation(using: .png, properties: [:]) else { throw ResetStorageError.invalid }
        return data
    }
}

final class UsagePopoverController: NSViewController {
    let canvas: UsagePopoverView
    init(model: PopoverPresentation) { canvas = UsagePopoverView(model: model); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = canvas }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.autorecalculatesKeyViewLoop = false
        view.window?.makeFirstResponder(canvas.ticketButton)
    }
    override func viewWillDisappear() { super.viewWillDisappear(); canvas.hoverCard(nil) }
    override func cancelOperation(_ sender: Any?) { canvas.onClose?() }
}
