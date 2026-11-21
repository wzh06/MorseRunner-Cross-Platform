import AppKit
import MorseRunnerCore

@MainActor
final class TwoBSIQCallCheckView: NSBox {
    static let capacity = 8
    private var buttons: [NSButton] = []
    private var matches: [String] = []
    var didChoose: ((String) -> Void)?
    var allowsSelection = false {
        didSet {
            if allowsSelection != oldValue { updateButtons() }
        }
    }

    init(band: TwoBSIQBand) {
        super.init(frame: .zero)
        title = "Call Check"
        setAccessibilityLabel("\(band.name) Call Check")
        let rows = (0..<2).map { _ in
            let cells = (0..<4).map { _ in
                let button = NSButton(title: "", target: self, action: #selector(choose(_:)))
                button.tag = buttons.count
                button.bezelStyle = .inline
                button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                button.lineBreakMode = .byTruncatingTail
                buttons.append(button)
                return button
            }
            let row = NSStackView(views: cells)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 4
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fillEqually
        stack.spacing = 3
        contentView = stack
        contentViewMargins = NSSize(width: 8, height: 5)
        heightAnchor.constraint(equalToConstant: 73).isActive = true
        updateButtons()
    }

    required init?(coder: NSCoder) { nil }

    func show(_ matches: [String]) {
        guard matches != self.matches else { return }
        self.matches = matches
        for (index, button) in buttons.enumerated() {
            button.title = index < matches.count ? matches[index] : ""
        }
        updateButtons()
    }

    private func updateButtons() {
        for (index, button) in buttons.enumerated() {
            button.isEnabled = allowsSelection && index < matches.count
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard matches.indices.contains(sender.tag) else { return }
        didChoose?(matches[sender.tag])
    }
}

@MainActor
final class TwoBSIQScoreView: NSBox {
    private let metrics = (0..<8).map { _ in NSTextField(labelWithString: "") }

    override init(frame: NSRect) {
        super.init(frame: frame)
        boxType = .custom
        borderWidth = 1
        cornerRadius = 4
        titlePosition = .noTitle
        contentViewMargins = NSSize(width: 12, height: 8)
        for metric in metrics {
            metric.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        let columns = ["Raw", "Verified"].enumerated().map { index, title in
            let header = NSTextField(labelWithString: title)
            header.font = .boldSystemFont(ofSize: 12)
            let stack = NSStackView(views: [header] + Array(metrics[(index * 4)..<(index * 4 + 4)]))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            return stack
        }
        let stack = NSStackView(views: columns)
        stack.orientation = .horizontal
        stack.spacing = 24
        stack.distribution = .fillEqually
        contentView = stack
        widthAnchor.constraint(equalToConstant: 250).isActive = true
        heightAnchor.constraint(equalToConstant: 110).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func show(_ score: TwoBSIQScore) {
        // Only confirmed contacts are entered in the 2BSIQ log.
        let values = ["Qso: \(score.qsos)", "Pts: \(score.points)", "Mult: \(score.multipliers)", "Score: \(score.total)"]
        for (index, metric) in metrics.enumerated() {
            metric.stringValue = values[index % values.count]
        }
    }
}
