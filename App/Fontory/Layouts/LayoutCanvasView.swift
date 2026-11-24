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
        page.onSelect = { [weak model] id in model?.selectedBlockID = id }
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

/// Draws the page bitmap centred at `zoom`, then the overlay. Flipped, so page and view y both grow downwards.
final class LayoutPageView: NSView {
    private var image: NSImage?
    private var document: LayoutDocument?
    private var zoom: CGFloat = 1
    private var selection: UUID?
    private var missingFontBlocks: Set<String> = []
    var onSelect: ((UUID?) -> Void)?

    override var isFlipped: Bool { true }

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

    func update(image cgImage: CGImage?, document: LayoutDocument?, zoom: CGFloat, selection: UUID?, missingFontBlocks: Set<String>) {
        if cgImage !== currentCGImage {
            currentCGImage = cgImage
            image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
        }
        self.document = document
        self.zoom = zoom
        self.selection = selection
        self.missingFontBlocks = missingFontBlocks
        needsDisplay = true
    }

    private var currentCGImage: CGImage?

    // MARK: Geometry (hit-testing hooks)

    /// A block's frame in view coordinates.
    func viewRect(of block: LayoutBlock) -> CGRect {
        let page = pageRect
        return CGRect(x: page.minX + block.frame.x * zoom, y: page.minY + block.frame.y * zoom,
                      width: block.frame.w * zoom, height: block.frame.h * zoom)
    }

    /// A view point in page points (origin top-left).
    func pagePoint(_ point: CGPoint) -> CGPoint {
        let page = pageRect
        return CGPoint(x: (point.x - page.minX) / zoom, y: (point.y - page.minY) / zoom)
    }

    /// The topmost block under a view point.
    func block(at point: CGPoint) -> LayoutBlock? {
        guard let doc = document else { return nil }
        let p = pagePoint(point)
        return doc.blocks.last { b in
            CGRect(x: b.frame.x, y: b.frame.y, width: b.frame.w, height: b.frame.h).contains(p)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(block(at: convert(event.locationInWindow, from: nil))?.id)
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

    /// Selection and badges, in view points (independent of the page bitmap).
    private func drawOverlay(_ doc: LayoutDocument) {
        for block in doc.blocks {
            let rect = viewRect(of: block)
            if missingFontBlocks.contains(block.id.uuidString) { drawMissingBadge(at: rect) }
            if block.id == selection {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
                path.lineWidth = 1.5
                path.stroke()
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
