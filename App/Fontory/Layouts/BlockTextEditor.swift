import AppKit
import FontoryCore

/// The in-place text editor: a plain-text NSTextView laid over a block's frame on the canvas, styled like the
/// block (its font at the canvas zoom, size, line height, tracking, alignment and colour) over the page background,
/// so the text roughly matches the render beneath. Esc, a click elsewhere or losing focus ends editing; the
/// owner then applies the text as one undo step. ⌘Z inside it is the text view's own undo.
final class BlockTextEditor: NSTextView {
    /// Called once with the final text. `refocus` is true when editing ended from the keyboard (Esc), so the
    /// canvas takes the focus back; when focus moved elsewhere it is left there.
    var onEnd: ((_ text: String, _ refocus: Bool) -> Void)?
    let blockID: UUID
    private var ended = false
    private var block: LayoutBlock
    private var zoom: CGFloat
    private var foreground: NSColor

    init(block: LayoutBlock, document: LayoutDocument, zoom: CGFloat, frame: CGRect) {
        blockID = block.id
        self.block = block
        self.zoom = zoom
        foreground = Self.color(block.color ?? document.foreground) ?? .black
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        drawsBackground = true
        backgroundColor = Self.color(document.background) ?? .white
        insertionPointColor = foreground
        string = block.text
        applyStyle(font: NSFont.systemFont(ofSize: max(1, block.size * zoom)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Restyles the text with `font` (the block's resolved font once it has loaded).
    func applyStyle(font: NSFont) {
        let size = max(1, block.size * zoom)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch block.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        let lineHeight = max(1, block.lineHeight * size)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph,
        ]
        if block.tracking != 0 { attributes[.kern] = block.tracking / 1000 * size }
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Ends editing (idempotent).
    func finish(refocus: Bool) {
        guard !ended else { return }
        ended = true
        onEnd?(string, refocus)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        if event.keyCode == 53, mods.isEmpty {
            finish(refocus: true)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(refocus: true)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finish(refocus: false) }
        return resigned
    }

    private static func color(_ hex: String) -> NSColor? {
        LayoutColor.cgColor(hex).flatMap { NSColor(cgColor: $0) }
    }
}
