import AppKit

/// A monochrome segmented toggle — replaces NSSegmentedControl, whose selected segment paints the system
/// ACCENT (blue) the app's "no blue" rule forbids and an offscreen snapshot can't reveal. Fixed grays.
final class MonoSegmented: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedSegment = 0 { didSet { restyle() } }
    private var buttons: [NSButton] = []

    init(labels: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.12).cgColor   // the track
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.distribution = .fillEqually
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, label) in labels.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = .labelColor
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Set the selection WITHOUT firing onChange (the programmatic path, mirroring segmentedControl assignment).
    func setSelectedSegment(_ i: Int) { selectedSegment = i }
    func setToolTip(_ tip: String?, forSegment i: Int) { if buttons.indices.contains(i) { buttons[i].toolTip = tip } }
    func performClickForTest(_ i: Int) { if buttons.indices.contains(i) { buttons[i].performClick(nil) } }
    var segmentCountForTest: Int { buttons.count }

    @objc private func tap(_ sender: NSButton) {
        selectedSegment = sender.tag
        onChange?(sender.tag)
    }

    private func restyle() {
        for (i, b) in buttons.enumerated() {
            b.layer?.backgroundColor = i == selectedSegment ? NSColor.gray.withAlphaComponent(0.34).cgColor : nil
            b.font = .systemFont(ofSize: 12, weight: i == selectedSegment ? .semibold : .medium)
        }
    }
}
