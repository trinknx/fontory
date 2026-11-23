import AppKit
import FontoryCore

/// The list's columns. The raw value is the column identifier, so it must stay stable: the column order and
/// widths are autosaved under it.
enum ListColumn: String, CaseIterable {
    case preview, name, family, style, weight, format, foundry, version, glyphs, status, lastActivated, location

    var title: String {
        switch self {
        case .preview: "Preview"
        case .name: "Name"
        case .family: "Family"
        case .style: "Style"
        case .weight: "Weight"
        case .format: "Format"
        case .foundry: "Foundry"
        case .version: "Version"
        case .glyphs: "Glyphs"
        case .status: "Status"
        case .lastActivated: "Last Activated"
        case .location: "Location"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .preview: 320
        case .name: 220
        case .family: 150
        case .style: 110
        case .weight, .format, .glyphs: 64
        case .foundry, .version: 90
        case .status: 100
        case .lastActivated: 130
        case .location: 220
        }
    }

    /// The query sort a header click on this column selects; nil for the columns sorted in memory.
    var querySort: LibraryQuery.Sort? {
        switch self {
        case .name: .name
        case .family: .family
        case .weight: .weight
        case .lastActivated: .lastActivated
        default: nil
        }
    }

    static func forQuerySort(_ sort: LibraryQuery.Sort) -> ListColumn? {
        allCases.first { $0.querySort == sort }
    }

    /// Sorted in memory, within the current family list.
    var sortsInMemory: Bool { querySort == nil && self != .preview }

    var isNumeric: Bool { self == .weight || self == .glyphs }

    /// The outline column (it carries the disclosure triangles), so it cannot be hidden.
    var canHide: Bool { self != .name }

    static let defaultHidden: Set<ListColumn> = [.version, .glyphs, .location]
}

/// A text column cell: one vertically centered, truncating label.
final class ListTextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ListTextCell")

    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The preview column cell: a layer showing the rendered preview, scaled to fit.
final class ListPreviewCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ListPreviewCell")
    static let inset: CGFloat = 2

    private(set) var faceID: Int64?
    /// The preview this cell wants; an arriving render is shown only when it matches.
    var wantedKey: PreviewPipeline.Key?
    private let previewLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        previewLayer.masksToBounds = true
        previewLayer.cornerRadius = 3
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    /// The preview area in points for a cell of `size`.
    static func previewSize(cellSize: CGSize) -> CGSize {
        CGSize(width: max(1, floor(cellSize.width - inset * 2)), height: max(1, floor(cellSize.height - inset * 2)))
    }

    func configure(faceID: Int64, online: Bool, background: CGColor) {
        if self.faceID != faceID { previewLayer.contents = nil }
        self.faceID = faceID
        previewLayer.backgroundColor = background
        previewLayer.opacity = online ? 1 : 0.4
    }

    /// Sets the preview image. It may come from another size: the layer scales it to fit.
    func show(image: CGImage?) {
        guard let image else { return }
        previewLayer.contents = image
    }

    var hasImage: Bool { previewLayer.contents != nil }
}

/// The status column cell: the activation dot (click toggles, hold for the menu) and a short label.
final class ListStatusCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ListStatusCell")

    let dot = ActivationDot()
    let label = NSTextField(labelWithString: "")
    var faceID: Int64?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 18),
            dot.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the state of `row`, or nothing (a family row, or a face whose row is still loading).
    func configure(faceID: Int64?, row: FaceRow?, locked: Bool) {
        self.faceID = faceID
        guard let row else {
            dot.isHidden = faceID == nil
            dot.state = .placeholder
            dot.isOffline = false
            label.stringValue = ""
            return
        }
        dot.isHidden = false
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
        label.stringValue = FontListController.statusText(row, locked: locked)
    }
}

/// The list's outline view: Space, type-to-scroll, pinch zoom and the context menu.
final class FontOutlineView: NSOutlineView {
    weak var controller: FontListController?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function])
        guard mods.isEmpty, let chars = event.characters, !chars.isEmpty else { return super.keyDown(with: event) }
        if chars == " ", controller?.isTypeSelecting != true {
            controller?.toggleSelectionActivation()
        } else if chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) {
            controller?.typeSelect(chars)
        } else {
            // Arrows included: ← and → collapse and expand.
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        controller?.magnify(by: event.magnification, phase: event.phase, at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.settingsChanged()
    }
}
