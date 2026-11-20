import AppKit
import MorseRunnerCore

@MainActor
final class TwoBSIQWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate {
    private static let separationKey = "TwoBSIQ.StereoSeparation"
    private static let overrideKey = "TwoBSIQ.Zone."
    private static let utcTime = DateFormatter()

    private let defaults: UserDefaults
    private let catalog: TwoBSIQCatalog
    private let ownCall: CallInputTextField
    private let zone = NSPopUpButton()
    private let separation = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let separationValue = NSTextField(labelWithString: "")
    private let runButton = NSButton(title: "Start", target: nil, action: nil)
    private let score = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let entries = [TwoBSIQEntryView(), TwoBSIQEntryView()]
    private let statuses = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    private let callZones = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    private lazy var editor: CallInputFieldEditor = {
        let editor = CallInputFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    private var buttons: [NSButton] = []
    private let actions: [TwoBSIQAction] = [.cq, .exchange, .finish]
    private var keyMonitor: Any?
    private let audio = TwoBSIQAudio()
    private var session: TwoBSIQSession?
    private var selected = TwoBSIQBand.a
    private var draftVersions = [0, 0]
    private var log: [TwoBSIQQSO] = []
    private let wpm: Int
    private let pitch: Int
    private let volume: Float
    var onClose: (() -> Void)?

    init(call: String, wpm: Int, pitch: Int, volume: Float, defaults: UserDefaults = .standard,
         catalog: TwoBSIQCatalog = .bundled) {
        self.defaults = defaults
        self.catalog = catalog
        self.wpm = wpm
        self.pitch = pitch
        self.volume = volume
        ownCall = CallInputTextField(string: TwoBSIQCatalog.normalizedCall(call))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 490),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "2BSIQ — CQ WW CW"
        window.minSize = NSSize(width: 760, height: 390)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        Self.utcTime.locale = Locale(identifier: "en_US_POSIX")
        Self.utcTime.timeZone = TimeZone(secondsFromGMT: 0)
        Self.utcTime.dateFormat = "HH:mm:ss"

        let saved = (defaults.object(forKey: Self.separationKey) as? NSNumber)?.doubleValue ?? 1
        separation.doubleValue = min(1, max(0, saved))
        updateSeparationLabel()
        updateOwnZone()
        refresh()
        installShortcuts()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        audio.stop()
        session = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        editor.restoreInputSource()
        onClose?()
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is CallInputTextField ? editor : nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === editor { editor.useEnglishInputSource() }
    }

    func windowDidResignKey(_ notification: Notification) {
        editor.restoreInputSource()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let band = band(for: notification.object as? NSTextField) {
            select(band, focus: false)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === ownCall {
            updateOwnZone()
        } else if let band = band(for: notification.object as? NSTextField) {
            updatePreview(for: band)
        }
    }

    private func buildContent() -> NSView {
        ownCall.delegate = self
        ownCall.visibleTextChanged = { [weak self] _ in self?.updateOwnZone() }
        ownCall.setAccessibilityLabel("Your callsign")
        ownCall.widthAnchor.constraint(equalToConstant: 105).isActive = true
        zone.addItem(withTitle: "Auto")
        for value in 1...40 {
            zone.addItem(withTitle: String(value))
            zone.lastItem?.tag = value
        }
        zone.target = self
        zone.action = #selector(zoneChanged)
        zone.setAccessibilityLabel("Your CQ zone")
        runButton.target = self
        runButton.action = #selector(toggleRun)
        let setup = row([label("My Call"), ownCall, label("CQ Zone"), zone, runButton])

        separation.target = self
        separation.action = #selector(separationChanged)
        separation.isContinuous = true
        separation.setAccessibilityLabel("Stereo Separation")
        separation.widthAnchor.constraint(equalToConstant: 145).isActive = true
        separationValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        separationValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let audioSettings = row([label("Stereo Separation"), separation, separationValue])

        buttons = ["F1  CQ", "F2  Exchange", "F3  TU"].enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(sendButton(_:)))
            button.tag = index
            return button
        }
        let shortcutHint = label("\\ Switch VFO   Esc Cancel")
        shortcutHint.textColor = .secondaryLabelColor
        let shortcuts = row(buttons + [shortcutHint])
        score.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

        let bands = TwoBSIQBand.allCases.map { band in
            let index = band.rawValue
            let entry = entries[index]
            entry.field.setAccessibilityLabel("\(band.name) Callsign")
            entry.field.delegate = self
            entry.field.visibleTextChanged = { [weak self] _ in self?.updatePreview(for: band) }
            let title = label("\(band.name) · \(band.meters) m")
            title.font = .boldSystemFont(ofSize: 13)
            statuses[index].textColor = .secondaryLabelColor
            callZones[index].textColor = .secondaryLabelColor
            let header = row([title, spacer(), callZones[index]])
            let lane = column([header, entry, statuses[index]])
            header.widthAnchor.constraint(equalTo: lane.widthAnchor).isActive = true
            entry.widthAnchor.constraint(equalTo: lane.widthAnchor).isActive = true
            return lane
        }
        let inputs = row(bands)
        inputs.distribution = .fillEqually

        for (identifier, title, width) in [("utc", "UTC", 90.0), ("band", "Band", 75.0),
                                          ("call", "Call", 150.0), ("rst", "RST", 65.0),
                                          ("zone", "CQ Zone", 90.0), ("points", "Points", 85.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        notice.textColor = .secondaryLabelColor
        let top = row([setup, spacer(), audioSettings])
        let content = column([top, shortcuts, score, inputs, scroll, notice])
        content.spacing = 10

        let root = NSView()
        root.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            top.widthAnchor.constraint(equalTo: content.widthAnchor),
            inputs.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        return root
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func spacer() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }

    private var operatorCall: String {
        TwoBSIQCatalog.normalizedCall(ownCall.currentEditor()?.string ?? ownCall.stringValue)
    }

    private var operatorZone: Int? {
        let manual = zone.selectedTag()
        return manual > 0 ? manual : catalog.zone(for: operatorCall)
    }

    private func updateOwnZone() {
        let call = operatorCall
        let automatic = catalog.zone(for: call)
        zone.item(at: 0)?.title = automatic.map { "Auto (\($0))" } ?? "Auto (—)"
        let manual = defaults.integer(forKey: Self.overrideKey + call)
        zone.selectItem(withTag: (1...40).contains(manual) ? manual : 0)
        for band in TwoBSIQBand.allCases { updatePreview(for: band) }
    }

    @objc private func zoneChanged() {
        let call = operatorCall
        if TwoBSIQCatalog.isCall(call) {
            let key = Self.overrideKey + call
            if zone.selectedTag() > 0 {
                defaults.set(zone.selectedTag(), forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        notice.stringValue = ""
        for band in TwoBSIQBand.allCases { updatePreview(for: band) }
    }

    @objc private func separationChanged() {
        defaults.set(separation.doubleValue, forKey: Self.separationKey)
        session?.separation = separation.floatValue
        updateSeparationLabel()
    }

    private func updateSeparationLabel() {
        separationValue.stringValue = "\(Int((100 * separation.doubleValue).rounded()))%"
    }

    private func updatePreview(for band: TwoBSIQBand) {
        let index = band.rawValue
        let draft = entries[index].call
        let suffix = operatorZone.map(TwoBSIQSession.exchangeSuffix) ?? ""
        entries[index].preview(suffix, draft: draft)
        callZones[index].stringValue = catalog.zone(for: draft).map { "CQ Zone \($0)" } ?? ""
    }

    @objc private func toggleRun() {
        if session != nil {
            audio.stop()
            session = nil
            notice.stringValue = ""
            for band in TwoBSIQBand.allCases {
                let entry = entries[band.rawValue]
                entry.displayTransmission(nil)
                entry.clearCall()
                updatePreview(for: band)
            }
            window?.makeFirstResponder(ownCall)
        } else {
            (ownCall.currentEditor() as? CallInputFieldEditor)?.confirmMarkedInput()
            let call = operatorCall
            guard TwoBSIQCatalog.isCall(call) else {
                notice.stringValue = "Enter your callsign to start."
                window?.makeFirstResponder(ownCall)
                return
            }
            guard let operatorZone else {
                notice.stringValue = "Choose your transmitter’s CQ zone to start."
                window?.makeFirstResponder(zone)
                return
            }
            guard !catalog.isEmpty else {
                notice.stringValue = "CQ WW station data is unavailable."
                return
            }
            let newSession = TwoBSIQSession(call: call, zone: operatorZone, wpm: wpm, pitch: pitch, catalog: catalog)
            newSession.separation = separation.floatValue
            session = newSession
            draftVersions = [0, 0]
            log = []
            table.reloadData()
            notice.stringValue = ""
            refresh()
            select(.a, focus: true)
            if !audio.start(session: newSession, volume: volume, didAdvance: { [weak self] in self?.refresh() }) {
                notice.stringValue = "Audio output unavailable. The practice clock is running silently."
            }
        }
        refresh()
    }

    @objc private func sendButton(_ sender: NSButton) {
        send(actions[sender.tag])
    }

    private func send(_ action: TwoBSIQAction) {
        guard let session else { return }
        let band = focusedBand ?? selected
        let entry = entries[band.rawValue]
        (entry.field.currentEditor() as? CallInputFieldEditor)?.confirmMarkedInput()
        selected = band
        session.send(action, on: band, enteredCall: entry.call)
        refresh()
    }

    private func band(for field: NSTextField?) -> TwoBSIQBand? {
        TwoBSIQBand.allCases.first { entries[$0.rawValue].field === field }
    }

    private var focusedBand: TwoBSIQBand? {
        band(for: (window?.firstResponder as? NSTextView)?.delegate as? NSTextField)
    }

    private func select(_ band: TwoBSIQBand, focus: Bool) {
        selected = band
        if focus {
            let field = entries[band.rawValue].field
            window?.makeFirstResponder(field.isHidden ? nil : field)
        }
        for band in TwoBSIQBand.allCases {
            entries[band.rawValue].selected = session != nil && band == selected
        }
    }

    private func installShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleShortcut(event)
        }
    }

    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        guard let session,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        let band = focusedBand ?? selected
        if event.charactersIgnoringModifiers == "\\" {
            if !event.isARepeat { select(band == .a ? .b : .a, focus: true) }
            return nil
        }
        let action: TwoBSIQAction?
        switch event.keyCode {
        case 122: action = .cq
        case 120: action = .exchange
        case 99: action = .finish
        case 36, 76: action = session.suggestedAction(for: band)
        case 53:
            if !event.isARepeat {
                session.cancel(selected: band)
                refresh()
            }
            return nil
        default: return event
        }
        if let action, !event.isARepeat { send(action) }
        return nil
    }

    private func refresh() {
        let running = session != nil
        let runTitle = running ? "Stop" : "Start"
        if runButton.title != runTitle {
            runButton.title = runTitle
            ownCall.isEditable = !running
            zone.isEnabled = !running
        }
        selected = focusedBand ?? selected
        for band in TwoBSIQBand.allCases {
            let index = band.rawValue
            let entry = entries[index]
            let state = session?.display(for: band)
            let wasHidden = entry.field.isHidden
            entry.displayTransmission(state?.transmission)
            if let state, state.draftVersion != draftVersions[index] {
                draftVersions[index] = state.draftVersion
                entry.clearCall()
                updatePreview(for: band)
            }
            if entry.field.isEnabled != running { entry.field.isEnabled = running }
            entry.selected = running && band == selected
            if wasHidden && !entry.field.isHidden && entry.selected && focusedBand == nil {
                window?.makeFirstResponder(entry.field)
            }
            setString(statuses[index], laneStatus(state))
        }

        let state = session?.display(for: selected)
        let action = state?.transmission == nil ? session?.suggestedAction(for: selected) : nil
        for (index, button) in buttons.enumerated() {
            let enabled = actions[index] == action
            if button.isEnabled != enabled { button.isEnabled = enabled }
        }
        if let session, session.log.count != log.count {
            log = session.log
            table.reloadData()
            table.scrollRowToVisible(log.count - 1)
        }
        let result = session?.score
        if let result {
            setString(score, "\(result.qsos) QSO     \(result.points) Pts     \(result.multipliers) Mult     Score \(result.total)")
        } else if log.isEmpty {
            setString(score, "0 QSO     0 Pts     0 Mult     Score 0")
        }
    }

    private func setString(_ field: NSTextField, _ value: String) {
        if field.stringValue != value { field.stringValue = value }
    }

    private func laneStatus(_ state: TwoBSIQLaneDisplay?) -> String {
        guard let state else { return "Stopped" }
        if state.queued { return "Queued" }
        if state.transmission != nil { return "TX" }
        if let status = state.status { return status }
        switch state.stage {
        case .idle: return "Ready to CQ"
        case .receivingCall: return "Listening for a call"
        case .awaitingExchange: return "Send exchange"
        case .receivingReport: return "Listening for report"
        case .awaitingTU: return "Send TU"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { log.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let contact = log[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "utc": value = Self.utcTime.string(from: contact.time)
        case "band": value = "\(contact.band.meters) m"
        case "call": value = contact.call
        case "rst": value = "599"
        case "zone": value = String(contact.zone)
        case "points": value = String(contact.points)
        default: return nil
        }
        return label(value)
    }
}
