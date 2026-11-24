import AppKit
import FontoryCore
import SwiftUI

/// The page canvas: the rendered page bitmap scaled into a scroll view (fit by default), with the overlay (selection,
/// "Missing font" badges) drawn separately on top in view coordinates.
struct LayoutCanvasView: NSViewRepresentable {
    /// For callbacks (fit, selection); everything drawn comes in as values below, read by the parent's body.
    let model: LayoutsModel
    let image: CGImage?
    let document: LayoutDocument?
    let zoom: CGFloat
    let selection: UUID?
    let missingFontBlocks: Set<String>

    func makeNSView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        let page = LayoutPageView()
        scroll.documentView = page
        scroll.onLayout = { [weak model] fit, backing in
            // Reported after the layout pass, never while SwiftUI updates the view.
            DispatchQueue.main.async { MainActor.assumeIsolated { model?.canvasDidLayout(fitZoom: fit, backingScale: backing) } }
        }
        page.model = model
        return scroll
    }

    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        guard let page = scroll.documentView as? LayoutPageView else { return }
        scroll.pageSize = document.map { CGSize(width: max(1, $0.pageSize.w), height: max(1, $0.pageSize.h)) }
        page.update(image: image, document: document, zoom: zoom, selection: selection, missingFontBlocks: missingFontBlocks)
        scroll.reportFit()
        scroll.layoutPage()
    }

    /// Reports the zoom that fits the page whenever its size changes, and sizes the page view.
    final class CanvasScrollView: NSScrollView {
        static let margin: CGFloat = 24
        var pageSize: CGSize?
        var onLayout: ((CGFloat, CGFloat) -> Void)?
        private var lastReported: (CGFloat, CGFloat)?

        override func layout() {
            super.layout()
            reportFit()
            layoutPage()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            reportFit()
        }

        func reportFit() {
            guard let pageSize else { return }
            let available = contentSize
            let fit = min((available.width - 2 * Self.margin) / pageSize.width,
                          (available.height - 2 * Self.margin) / pageSize.height)
            let value = (max(0.01, fit), window?.backingScaleFactor ?? 2)
            if lastReported.map({ $0 != value }) ?? true {
                lastReported = value
                onLayout?(value.0, value.1)
            }
        }

        /// The page view is at least the visible area, so a small page sits centred.
        func layoutPage() {
            guard let page = documentView as? LayoutPageView else { return }
            let content = page.pageViewSize
            let size = CGSize(width: max(contentSize.width, content.width + 2 * Self.margin),
                              height: max(contentSize.height, content.height + 2 * Self.margin))
            if page.frame.size != size { page.setFrameSize(size) }
        }
    }
}

/// Page points (origin top-left) ↔ page-view points (flipped) at the canvas zoom: the one mapping used for
/// drawing the overlay, hit-testing, dragging, the handles and placing the in-place editor.
struct PageTransform {
    /// Where the page's top-left corner sits in the view.
    var origin: CGPoint
    /// View points per page point.
    var zoom: CGFloat

    func viewRect(_ frame: LayoutFrame) -> CGRect {
        CGRect(x: origin.x + frame.x * zoom, y: origin.y + frame.y * zoom, width: frame.w * zoom, height: frame.h * zoom)
    }

    func pagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / zoom, y: (point.y - origin.y) / zoom)
    }

    /// A view-point distance in whole page points.
    func pageDelta(_ delta: CGSize) -> CGSize {
        CGSize(width: (delta.width / zoom).rounded(), height: (delta.height / zoom).rounded())
    }
}

/// Draws the page bitmap centred at `zoom`, then the overlay (selection, corner handles, "Missing font" badges).
/// Flipped, so page and view y both grow downwards. Click selects, dragging the body moves, a corner handle resizes,
/// double-click edits the text in place, ⌫ deletes the selected block, ←/→ and ↑/↓ cycle families and styles.
final class LayoutPageView: NSView {
    static let handleSize: CGFloat = 8
    /// How far a mouse-down may wander before it counts as a drag.
    static let dragThreshold: CGFloat = 3

    weak var model: LayoutsModel?
    private var image: NSImage?
    private var document: LayoutDocument?
    private var zoom: CGFloat = 1
    private var selection: UUID?
    private var missingFontBlocks: Set<String> = []
    private var currentCGImage: CGImage?
    private var editor: BlockTextEditor?

    private enum DragMode { case move, resize(LayoutsModel.Corner) }
    private struct Drag {
        var id: UUID
        var mode: DragMode
        var start: LayoutFrame
        var startPoint: CGPoint
        var began = false
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The page at the current zoom, in view points.
    var pageViewSize: CGSize {
        guard let doc = document else { return .zero }
        return CGSize(width: doc.pageSize.w * zoom, height: doc.pageSize.h * zoom)
    }

    /// Where the page sits in the view.
    var pageRect: CGRect {
        let size = pageViewSize
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    var transform: PageTransform { PageTransform(origin: pageRect.origin, zoom: zoom) }

    func update(image cgImage: CGImage?, document: LayoutDocument?, zoom: CGFloat, selection: UUID?, missingFontBlocks: Set<String>) {
        if cgImage !== currentCGImage {
            currentCGImage = cgImage
            image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
        }
        self.document = document
        self.zoom = zoom
        self.selection = selection
        self.missingFontBlocks = missingFontBlocks
        positionEditor()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The window is closing (or the canvas leaving it): the typed text goes into the layout first.
        if newWindow == nil { endEditing(refocus: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionEditor()
    }

    private func block(_ id: UUID?) -> LayoutBlock? {
        guard let id else { return nil }
        return document?.blocks.first { $0.id == id }
    }

    // MARK: Hit-testing

    /// The selected block's corner handles, in view points.
    private func handleRects(for block: LayoutBlock) -> [(LayoutsModel.Corner, CGRect)] {
        let r = transform.viewRect(block.frame)
        let s = Self.handleSize
        func square(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s) }
        return [(.topLeft, square(r.minX, r.minY)), (.topRight, square(r.maxX, r.minY)),
                (.bottomLeft, square(r.minX, r.maxY)), (.bottomRight, square(r.maxX, r.maxY))]
    }

    private func corner(at point: CGPoint) -> LayoutsModel.Corner? {
        guard editor == nil, let selected = block(selection) else { return nil }
        // A little larger than drawn, so the handle is easy to grab.
        return handleRects(for: selected).first { $0.1.insetBy(dx: -3, dy: -3).contains(point) }?.0
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // A click outside the in-place editor ends editing (clicks inside go to the editor itself).
        endEditing(refocus: false)
        window?.makeFirstResponder(self)
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let corner = corner(at: point), let selected = block(selection) {
            drag = Drag(id: selected.id, mode: .resize(corner), start: selected.frame, startPoint: point)
            return
        }
        let id = model.blockID(atPage: transform.pagePoint(point))
        model.select(id)
        selection = id
        needsDisplay = true
        guard let id, let hit = block(id) else { return }
        if event.clickCount >= 2 {
            beginEditing(hit)
            return
        }
        drag = Drag(id: id, mode: .move, start: hit.frame, startPoint: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let viewDelta = CGSize(width: point.x - current.startPoint.x, height: point.y - current.startPoint.y)
        if !current.began {
            guard hypot(viewDelta.width, viewDelta.height) >= Self.dragThreshold else { return }
            model.beginLiveEdit()
            current.began = true
            drag = current
        }
        let delta = transform.pageDelta(viewDelta)
        switch current.mode {
        case .move: model.moveBlock(current.id, from: current.start, by: delta)
        case .resize(let corner): model.resizeBlock(current.id, from: current.start, corner: corner, by: delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if drag?.began == true { model?.endLiveEdit() }
        drag = nil
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        // ⌫ and ⌦ delete the selected block.
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117, let model, model.selectedBlockID != nil {
            model.deleteSelectedBlock()
            return
        }
        // ←/→ cycle the candidate families and ↑/↓ the family's styles on the selected block (not while editing:
        // the editor has first responder then).
        if mods.isEmpty, editor == nil, let model, model.selectedBlockID != nil, !model.isEditingText,
           let key = LayoutsModel.cycleKey(keyCode: event.keyCode) {
            switch key {
            case .family(let step): model.cycleFamily(step: step)
            case .style(let step): model.cycleStyle(step: step)
            case .referenceStyle: break
            }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: In-place editor

    private func beginEditing(_ block: LayoutBlock) {
        guard let model, let doc = document else { return }
        endEditing(refocus: false)
        let editor = BlockTextEditor(block: block, document: doc, zoom: zoom, frame: transform.viewRect(block.frame))
        editor.onEnd = { [weak self, weak editor, weak model] text, refocus in
            // Applied to the document the editor was opened on: the model calls the commit hook before it saves or
            // replaces that document.
            model?.commitPendingTextEdit = nil
            model?.isEditingText = false
            guard let editor else { return }
            model?.setText(text, for: editor.blockID)
            guard let self else { editor.removeFromSuperview(); return }
            if self.editor === editor { self.editor = nil }
            self.needsDisplay = true
            // Removed after the current event: this may run inside the editor's resignFirstResponder.
            DispatchQueue.main.async { [weak self, weak editor] in
                editor?.removeFromSuperview()
                if refocus, let self { self.window?.makeFirstResponder(self) }
            }
        }
        self.editor = editor
        model.commitPendingTextEdit = { [weak editor] in editor?.finish(refocus: false) }
        model.isEditingText = true
        addSubview(editor)
        window?.makeFirstResponder(editor)
        editor.selectAll(nil)
        needsDisplay = true
        loadEditorFont(for: block)
    }

    /// Loads the block's font for the editor off the main thread (again after the font changes).
    private func loadEditorFont(for block: LayoutBlock) {
        guard let model, let editor else { return }
        Task { @MainActor [weak editor] in
            guard let font = await model.editorFont(for: block, size: max(1, block.size * zoom)),
                  let editor, editor.superview != nil, editor.blockFont == block.font else { return }
            editor.setLoadedFont(font)
        }
    }

    private func endEditing(refocus: Bool) {
        editor?.finish(refocus: refocus)
    }

    /// Keeps the editor over its block (zoom, resize); ends editing if the block is gone.
    private func positionEditor() {
        guard let editor else { return }
        guard let edited = block(editor.blockID) else {
            endEditing(refocus: false)
            return
        }
        let rect = transform.viewRect(edited.frame)
        if editor.frame != rect { editor.frame = rect }
        guard let doc = document else { return }
        let fontChanged = editor.blockFont != edited.font
        editor.update(block: edited, document: doc, zoom: zoom)
        if fontChanged { loadEditorFont(for: edited) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let doc = document else { return }
        let page = pageRect
        // Page shadow and fallback fill while the first render runs.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        (LayoutColor.cgColor(doc.background).flatMap { NSColor(cgColor: $0) } ?? .white).setFill()
        page.fill()
        NSGraphicsContext.restoreGraphicsState()

        if let image {
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: page, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawOverlay(doc)
    }

    /// Selection, handles and badges, in view points (independent of the page bitmap).
    private func drawOverlay(_ doc: LayoutDocument) {
        let transform = transform
        for block in doc.blocks {
            let rect = transform.viewRect(block.frame)
            if missingFontBlocks.contains(block.id.uuidString) { drawMissingBadge(at: rect) }
            if block.id == selection {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
                path.lineWidth = 1.5
                path.stroke()
                if editor == nil {
                    for (_, handle) in handleRects(for: block) {
                        NSColor.white.setFill()
                        handle.fill()
                        NSColor.controlAccentColor.setStroke()
                        let border = NSBezierPath(rect: handle.insetBy(dx: 0.5, dy: 0.5))
                        border.lineWidth = 1
                        border.stroke()
                    }
                }
            }
        }
    }
    private func drawMissingBadge(at rect: CGRect) {
        let text = NSAttributedString(string: "Missing font", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let badge = CGRect(x: rect.minX + 4, y: rect.minY + 4, width: size.width + 10, height: size.height + 4)
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 2))
    }
}
