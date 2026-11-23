import AppKit
import FontoryCore

/// One grid cell: the preview image, the family + style label and the activation dot.
final class FontGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FontGridItem")
    static let labelHeight: CGFloat = 22
    static let padding: CGFloat = 8

    /// The face shown, nil while the cell is a placeholder.
    private(set) var faceID: Int64?
    /// The preview this cell wants; an arriving render is shown only when it matches.
    var wantedKey: PreviewPipeline.Key?

    /// Click on the dot (toggle) and the press-and-hold menu, wired by the grid.
    var onToggleActivation: ((Int64) -> Void)?
    var activationMenu: ((Int64) -> NSMenu?)?

    private let previewLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let dot = ActivationDot()
    private let offlineBadge = NSImageView()

    override func loadView() {
        let root = GridCellView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.borderWidth = 0
        root.layer?.masksToBounds = true

        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        previewLayer.masksToBounds = true
        root.layer?.addSublayer(previewLayer)

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.onClick = { [weak self] in
            guard let self, let id = self.faceID else { return }
            self.onToggleActivation?(id)
        }
        dot.menuProvider = { [weak self] in
            guard let self, let id = self.faceID else { return nil }
            return self.activationMenu?(id)
        }

        offlineBadge.image = NSImage(systemSymbolName: "externaldrive.badge.xmark", accessibilityDescription: "Offline")
        offlineBadge.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        offlineBadge.contentTintColor = .secondaryLabelColor
        offlineBadge.toolTip = "The file’s location is offline"
        offlineBadge.translatesAutoresizingMaskIntoConstraints = false
        offlineBadge.isHidden = true

        for v in [dot, label, offlineBadge] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.padding - 2),
            dot.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
            dot.widthAnchor.constraint(equalToConstant: 18),
            dot.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 3),
            label.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            offlineBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            offlineBadge.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            offlineBadge.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Self.padding),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.onLayout = { [weak self] in self?.layoutPreview() }
        view = root
    }

    /// The preview area in points (the cell minus the label strip and padding).
    static func previewSize(itemSize: CGSize) -> CGSize {
        CGSize(width: max(1, itemSize.width - padding * 2), height: max(1, itemSize.height - labelHeight - padding))
    }

    private func layoutPreview() {
        let b = view.bounds
        let size = Self.previewSize(itemSize: b.size)
        // The view is flipped (collection view items are not by default; GridCellView is), so y grows downward.
        previewLayer.frame = CGRect(x: Self.padding, y: Self.padding, width: size.width, height: size.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faceID = nil
        wantedKey = nil
        previewLayer.contents = nil
        label.stringValue = ""
        dot.state = .placeholder
        offlineBadge.isHidden = true
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    /// Shows `row` (or a placeholder while it loads) on `background`.
    func configure(faceID: Int64, row: FaceRow?, locked: Bool, background: CGColor) {
        if self.faceID != faceID { previewLayer.contents = nil }
        self.faceID = faceID
        view.layer?.backgroundColor = background
        updateSelection()
        guard let row else {
            label.stringValue = ""
            dot.state = .placeholder
            offlineBadge.isHidden = true
            previewLayer.opacity = 1
            view.toolTip = nil
            return
        }
        label.stringValue = row.style.isEmpty ? row.family : "\(row.family) — \(row.style)"
        view.toolTip = row.fullName
        if locked {
            dot.state = .locked
        } else {
            switch row.activation {
            case .off: dot.state = .off
            case .on: dot.state = .on
            case .temporary: dot.state = .temporary
            }
        }
        dot.isOffline = !row.online
        offlineBadge.isHidden = row.online
        previewLayer.opacity = row.online ? 1 : 0.4
    }

    /// Sets the preview image. It may come from another size: the layer scales it to fit.
    func show(image: CGImage?) {
        guard let image else { return }
        previewLayer.contents = image
    }

    var hasImage: Bool { previewLayer.contents != nil }
}

/// Flipped, layer-backed cell root that reports layout passes.
private final class GridCellView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The activation dot. Click toggles; press and hold (0.4 s) opens the activation menu.
final class ActivationDot: NSView {
    enum State { case placeholder, off, on, temporary, locked }

    static let holdDelay: TimeInterval = 0.4

    var state: State = .placeholder { didSet { if state != oldValue { refresh() } } }
    var isOffline = false { didSet { if isOffline != oldValue { refresh() } } }
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let imageView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var isInteractive: Bool { state != .locked && state != .placeholder }

    private func refresh() {
        let symbol: String
        var tint: NSColor
        let help: String
        switch state {
        case .placeholder: symbol = "circle"; tint = .quaternaryLabelColor; help = ""
        case .off: symbol = "circle"; tint = .secondaryLabelColor; help = "Off — click to activate, hold for more"
        case .on: symbol = "circle.fill"; tint = .systemGreen; help = "Active — click to deactivate, hold for more"
        case .temporary: symbol = "circle.lefthalf.filled"; tint = .systemOrange; help = "Temporarily active — click to deactivate, hold for more"
        case .locked: symbol = "lock.fill"; tint = .tertiaryLabelColor; help = "System font — always available"
        }
        if isOffline && state != .locked { tint = .tertiaryLabelColor }
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        imageView.contentTintColor = tint
        toolTip = help.isEmpty ? nil : help
        setAccessibilityLabel(help)
        setAccessibilityEnabled(isInteractive)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Tracks the press: a mouse-up within the hold delay is a click; otherwise the menu opens under the dot.
    override func mouseDown(with event: NSEvent) {
        guard isInteractive, let window else { return }
        let deadline = Date(timeIntervalSinceNow: Self.holdDelay)
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline,
                                              inMode: .eventTracking, dequeue: true) else {
                // Held long enough.
                if let menu = menuProvider?() {
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: self)  // below the dot (not flipped)
                }
                return
            }
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { onClick?() }
                return
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isInteractive else { return false }
        onClick?()
        return true
    }
}
