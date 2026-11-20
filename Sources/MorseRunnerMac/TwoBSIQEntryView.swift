import AppKit

/// The editor holds the callsign alone. The suffix and TX playhead share its
/// bezel, leaving selection, paste and the IME in the existing AppKit editor.
@MainActor
final class TwoBSIQEntryView: NSView {
    let field = CallInputTextField(string: "")
    private let suffix = NSTextField(labelWithString: "")
    private let remaining = NSTextField(labelWithString: "")
    private let entryFont = NSFont.monospacedSystemFont(ofSize: 17, weight: .medium)
    private var fieldWidth: NSLayoutConstraint!
    var selected = false {
        didSet { if oldValue != selected { needsDisplay = true } }
    }

    var call: String {
        (field.currentEditor()?.string ?? field.stringValue).uppercased()
    }

    init() {
        super.init(frame: .zero)

        field.placeholderString = "Call"
        field.setAccessibilityLabel("Callsign")
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        suffix.textColor = .secondaryLabelColor
        remaining.setAccessibilityLabel("Remaining transmit text")

        for view in [field, suffix, remaining] {
            view.font = entryFont
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        fieldWidth = field.widthAnchor.constraint(equalToConstant: 52)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fieldWidth,
            // A borderless NSTextField reserves a small inset for its caret.
            suffix.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: -9),
            suffix.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            remaining.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            remaining.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
        remaining.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func preview(_ exchangeSuffix: String, draft: String) {
        let textWidth = (draft as NSString).size(withAttributes: [.font: entryFont]).width
        fieldWidth.constant = draft.isEmpty ? 52 : min(245, ceil(textWidth) + 9)
        suffix.stringValue = draft.isEmpty ? "" : exchangeSuffix
        suffix.isHidden = field.isHidden || suffix.stringValue.isEmpty
    }

    func displayTransmission(_ text: String?) {
        if text != nil, field.currentEditor() != nil {
            window?.makeFirstResponder(self)
        }
        let sending = text != nil
        if field.isHidden != sending {
            field.isHidden = sending
            field.isEditable = !sending
            suffix.isHidden = sending || suffix.stringValue.isEmpty
            remaining.isHidden = !sending
        }
        let remainingText = text ?? ""
        if remaining.stringValue != remainingText {
            remaining.stringValue = remainingText
        }
    }

    func clearCall() {
        field.stringValue = ""
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = ""
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func focus() {
        window?.makeFirstResponder(field.isHidden ? self : field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bezel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.textBackgroundColor.setFill()
        bezel.fill()
        (selected ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        bezel.lineWidth = selected ? 2 : 1
        bezel.stroke()
    }
}
