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
    /// The font the editor is styled for.
    var blockFont: FontReference { block.font }
    private var ended = false
    private var block: LayoutBlock
    private var zoom: CGFloat
    private var foreground: NSColor
    /// The block's own font once loaded (any size); nil while the system font stands in.
    private var loadedFont: NSFont?

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
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Uses the block's resolved font (loaded off the main thread) from now on.
    func setLoadedFont(_ font: NSFont) {
        loadedFont = font
        applyStyle()
    }

    /// Follows the block's style and the canvas zoom while editing (⌘+/⌘−, inspector changes); the text typed so
    /// far is kept. A font change drops the loaded font until the owner loads the new one.
    func update(block new: LayoutBlock, document: LayoutDocument, zoom newZoom: CGFloat) {
        var a = block, b = new
        a.text = ""; b.text = ""; a.frame = b.frame
        let color = Self.color(new.color ?? document.foreground) ?? .black
        guard a != b || zoom != newZoom || color != foreground else { return }
        if new.font != block.font { loadedFont = nil }
        block = new
        zoom = newZoom
        foreground = color
        insertionPointColor = color
        backgroundColor = Self.color(document.background) ?? .white
        applyStyle()
    }

    /// Restyles all the text at the block's size × zoom.
    private func applyStyle() {
        let size = max(1, block.size * zoom)
        let font = loadedFont.map { $0.withSize(size) } ?? NSFont.systemFont(ofSize: size)
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
