import CoreGraphics
import CoreText
import Foundation

/// Everything that determines a body-text specimen's layout and look, apart from the font (which carries the size
/// and the OpenType feature settings). Colors are compared by their sRGB components.
public struct BodyTextStyle: Sendable, Hashable {
    public var text: String
    public var pointSize: CGFloat
    /// Distance between baselines as a multiple of the point size.
    public var lineHeight: CGFloat = 1.4
    public var tracking: CGFloat = 0
    public var alignment: CTTextAlignment = .left
    public var columns = 1
    public var showGuides = false
    public var foreground: CGColor { didSet { foregroundComponents = PreviewRequest.components(foreground) } }
    public var background: CGColor { didSet { backgroundComponents = PreviewRequest.components(background) } }
    /// Total width in points, insets included.
    public var width: CGFloat
    /// Margin around the text on every side, in points.
    public var inset: CGFloat = 24
    private var foregroundComponents: [CGFloat]
    private var backgroundComponents: [CGFloat]

    public init(text: String, pointSize: CGFloat, foreground: CGColor, background: CGColor, width: CGFloat) {
        self.text = text; self.pointSize = pointSize
        self.foreground = foreground; self.background = background; self.width = width
        foregroundComponents = PreviewRequest.components(foreground)
        backgroundComponents = PreviewRequest.components(background)
    }

    /// Baseline-to-baseline distance in points.
    public var lineSpacing: CGFloat { max(1, pointSize * lineHeight) }
    /// Space between columns: two ems, at least 16 pt.
    public var columnGap: CGFloat { max(16, pointSize * 2) }
    /// Extra space after each paragraph.
    public var paragraphSpacing: CGFloat { (lineSpacing * 0.6).rounded() }

    public static func == (a: BodyTextStyle, b: BodyTextStyle) -> Bool {
        a.text == b.text && a.pointSize == b.pointSize && a.lineHeight == b.lineHeight && a.tracking == b.tracking
            && a.alignment == b.alignment && a.columns == b.columns && a.showGuides == b.showGuides
            && a.width == b.width && a.inset == b.inset
            && a.foregroundComponents == b.foregroundComponents && a.backgroundComponents == b.backgroundComponents
    }

    public func hash(into h: inout Hasher) {
        h.combine(text); h.combine(pointSize); h.combine(lineHeight); h.combine(tracking)
        h.combine(alignment.rawValue); h.combine(columns); h.combine(showGuides); h.combine(width); h.combine(inset)
        h.combine(foregroundComponents); h.combine(backgroundComponents)
    }
}

/// A laid-out specimen: the text set into balanced columns. Immutable; safe to draw from any one thread at a time.
public struct BodyTextLayout: @unchecked Sendable {
    struct PlacedLine {
        let line: CTLine
        /// Baseline origin in layout coordinates (origin bottom-left, y up).
        let origin: CGPoint
        let column: Int
    }

    public let style: BodyTextStyle
    /// Size in points, insets included.
    public let size: CGSize
    public let columnWidth: CGFloat
    /// Number of column frames (always `style.columns`, clamped to 1...3; later ones may be empty).
    public let columnCount: Int
    /// False when the text could not be fitted (a column narrower than a glyph).
    public let isComplete: Bool
    /// The face at its size, with its features: the one the text is set in.
    public let font: CTFont
    let lines: [PlacedLine]
    /// How far from its baseline a line's ink can reach: strips draw the lines this close to them.
    let drawMargin: CGFloat

    /// Lines in each column. For tests.
    var lineCountsPerColumn: [Int] {
        (0..<columnCount).map { c in lines.count { $0.column == c } }
    }

    /// Ink-relevant width of each line (trailing white space excluded). For tests.
    var lineWidths: [CGFloat] {
        lines.map { CGFloat(CTLineGetTypographicBounds($0.line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth($0.line)) }
    }

    /// Every glyph of the layout, in order. For tests.
    var glyphs: [CGGlyph] {
        lines.flatMap { placed in
            (CTLineGetGlyphRuns(placed.line) as? [CTRun] ?? []).flatMap { run -> [CGGlyph] in
                var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &g)
                return g
            }
        }
    }
}

/// One horizontal slice of a rendered specimen. `rect` is in points, measured from the top of the layout.
public struct BodyTextStrip: @unchecked Sendable {
    public let image: CGImage
    public let rect: CGRect
}

/// Sets body text into 1–3 balanced columns with a CoreText framesetter and renders it in horizontal strips (so a
/// long text never needs one huge bitmap). Pure functions; call from any thread.
public enum BodyTextRenderer {
    static let maxColumns = 3

    /// The styled text: `font` (size and features), color, tracking, alignment, fixed line spacing and paragraph
    /// spacing. Characters the font lacks fall back to system fonts, as in any text view.
    static func attributedString(font: CTFont, style: BodyTextStyle) -> NSAttributedString {
        var alignment = style.alignment
        var lineSpacing = style.lineSpacing
        var paragraphSpacing = style.paragraphSpacing
        var noLeading: CGFloat = 0
        // Fixed line height (min = max) and no extra leading: baselines are exactly `lineSpacing` apart, whatever
        // the font's own line gap or a fallback font's height.
        let paragraph = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &lineSpacing) { l in
                withUnsafeBytes(of: &paragraphSpacing) { p in
                    withUnsafeBytes(of: &noLeading) { z in
                        let settings = [
                            CTParagraphStyleSetting(spec: .alignment, valueSize: a.count, value: a.baseAddress!),
                            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: l.count, value: l.baseAddress!),
                            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: l.count, value: l.baseAddress!),
                            CTParagraphStyleSetting(spec: .minimumLineSpacing, valueSize: z.count, value: z.baseAddress!),
                            CTParagraphStyleSetting(spec: .maximumLineSpacing, valueSize: z.count, value: z.baseAddress!),
                            CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: p.count, value: p.baseAddress!),
                        ]
                        return CTParagraphStyleCreate(settings, settings.count)
                    }
                }
            }
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): style.foreground,
            .init(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if style.tracking != 0 { attrs[.init(kCTKernAttributeName as String)] = style.tracking }
        return NSAttributedString(string: style.text, attributes: attrs)
    }

    /// Lays `style.text` out in `style.columns` columns of equal width, balanced: the shortest column height that
    /// holds the whole text.
    public static func layout(font: CTFont, style: BodyTextStyle) -> BodyTextLayout {
        let n = min(maxColumns, max(1, style.columns))
        let inset = max(0, style.inset)
        let gap = style.columnGap
        let columnWidth = max(1, ((style.width - 2 * inset - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down))
        let text = attributedString(font: font, style: style)
        let length = text.length
        let framesetter = CTFramesetterCreateWithAttributedString(text)

        func frames(height: CGFloat) -> (frames: [CTFrame], complete: Bool) {
            var start = 0
            var out: [CTFrame] = []
            for i in 0..<n {
                let rect = CGRect(x: inset + CGFloat(i) * (columnWidth + gap), y: inset, width: columnWidth, height: height)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0),
                                                     CGPath(rect: rect, transform: nil), nil)
                out.append(frame)
                start += CTFrameGetVisibleStringRange(frame).length
            }
            return (out, start >= length)
        }

        let step = style.lineSpacing
        let single = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: columnWidth, height: .greatestFiniteMagnitude), nil).height
        // Lower bound: the single-column height spread evenly. Probe upward (doubling) until it fits, then
        // binary-search the smallest fitting height to the point.
        var low = max(step, (single / CGFloat(n)).rounded(.up))
        var best = frames(height: low)
        var height = low
        if !best.complete {
            var delta = step
            var high = low + delta
            var probe = frames(height: high)
            var attempts = 0
            while !probe.complete && attempts < 24 {
                low = high
                delta *= 2
                high = low + delta
                probe = frames(height: high)
                attempts += 1
            }
            best = probe
            height = high
            if probe.complete {
                while high - low > 1 {
                    let mid = ((low + high) / 2).rounded(.down)
                    let attempt = frames(height: mid)
                    if attempt.complete { high = mid; best = attempt } else { low = mid }
                }
                height = high
            }
        }

        var lines: [BodyTextLayout.PlacedLine] = []
        for (column, frame) in best.frames.enumerated() {
            let frameLines = CTFrameGetLines(frame) as? [CTLine] ?? []
            guard !frameLines.isEmpty else { continue }
            var origins = [CGPoint](repeating: .zero, count: frameLines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let x = inset + CGFloat(column) * (columnWidth + gap)
            for (line, origin) in zip(frameLines, origins) {
                lines.append(.init(line: line, origin: CGPoint(x: x + origin.x, y: inset + origin.y), column: column))
            }
        }
        // Tall scripts (Zapfino, stacked marks) can ink above the first line's box or below the last one's: grow the
        // top and bottom margins by the overshoot, so nothing is clipped. Only lines that can reach an edge are
        // measured (glyph-path bounds are costly on long text).
        let box = CTFontGetBoundingBox(font)
        let reachUp = max(box.maxY, style.lineSpacing * 2), reachDown = max(-box.minY, style.lineSpacing * 2)
        let frameTop = inset + height, frameBottom = inset
        var inkTop = frameTop, inkBottom = frameBottom
        for placed in lines where placed.origin.y + reachUp > frameTop || placed.origin.y - reachDown < frameBottom {
            let ink = CTLineGetBoundsWithOptions(placed.line, .useGlyphPathBounds)
            guard !ink.isNull, !ink.isEmpty else { continue }
            inkTop = max(inkTop, placed.origin.y + ink.maxY)
            inkBottom = min(inkBottom, placed.origin.y + ink.minY)
        }
        let extraTop = (inkTop - frameTop).rounded(.up), extraBottom = (frameBottom - inkBottom).rounded(.up)
        if extraBottom > 0 {
            lines = lines.map { .init(line: $0.line, origin: CGPoint(x: $0.origin.x, y: $0.origin.y + extraBottom), column: $0.column) }
        }
        let size = CGSize(width: max(1, style.width), height: (height + 2 * inset + extraTop + extraBottom).rounded(.up))
        return BodyTextLayout(style: style, size: size, columnWidth: columnWidth, columnCount: n,
                              isComplete: best.complete, font: font, lines: lines,
                              drawMargin: max(reachUp, reachDown, style.pointSize * 2))
    }

    /// Renders the whole of `layout` as strips of at most `stripHeight` points, top to bottom. For tests: views draw
    /// only the strips near their viewport (`BodyTextStripCache`).
    static func renderAll(_ layout: BodyTextLayout, scale: CGFloat, stripHeight: CGFloat = 1024,
                          isCancelled: () -> Bool = { false }) -> [BodyTextStrip] {
        let total = layout.size.height
        let stripHeight = max(16, stripHeight)
        var out: [BodyTextStrip] = []
        var top: CGFloat = 0
        while top < total {
            if isCancelled() { return [] }
            let rect = CGRect(x: 0, y: top, width: layout.size.width, height: min(stripHeight, total - top))
            if let image = render(layout, scale: scale, rect: rect) { out.append(BodyTextStrip(image: image, rect: rect)) }
            top = rect.maxY
        }
        return out
    }

    /// Renders the part of `layout` inside `rect` (points, measured from the top).
    public static func render(_ layout: BodyTextLayout, scale: CGFloat, rect: CGRect) -> CGImage? {
        let style = layout.style
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        // An opaque background needs no alpha channel to be kept.
        let alpha: CGImageAlphaInfo = style.background.alpha >= 1 ? .noneSkipLast : .premultipliedLast
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: PreviewRequest.sRGB, bitmapInfo: alpha.rawValue)
        else { return nil }
        ctx.setFillColor(style.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // Layout coordinates are y-up from the bottom of the whole layout; this strip spans [bottom, bottom + height].
        let bottom = layout.size.height - rect.maxY
        ctx.translateBy(x: -rect.minX, y: -bottom)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // Lines whose ink can reach the strip: generous margins for tall accents and deep descenders.
        let margin = layout.drawMargin
        let visible = layout.lines.filter { $0.origin.y > bottom - margin && $0.origin.y < bottom + rect.height + margin }
        if style.showGuides {
            for placed in visible {
                MetricGuides.drawLineGuides(ctx, font: layout.font, x: placed.origin.x, baseline: placed.origin.y,
                                            width: layout.columnWidth, foreground: style.foreground, scale: scale)
            }
        }
        for placed in visible {
            ctx.textPosition = placed.origin
            CTLineDraw(placed.line, ctx)
        }
        return ctx.makeImage()
    }
}

/// The rendered strips of one layout that a view keeps: at most `limit`, least recently used dropped first, so
/// memory depends on the viewport, not on the length of the text. Strip `i` covers `rect(at: i)`. Not thread-safe:
/// use it from one actor (the view's); render the strips anywhere with `BodyTextRenderer.render(_:scale:rect:)`.
public final class BodyTextStripCache {
    public let size: CGSize
    public let stripHeight: CGFloat
    public let limit: Int
    private var images: [Int: CGImage] = [:]
    /// Least recently used first.
    private var order: [Int] = []

    public init(layoutSize: CGSize, stripHeight: CGFloat = 1024, limit: Int = 6) {
        size = layoutSize
        self.stripHeight = max(16, stripHeight)
        self.limit = max(1, limit)
    }

    public var stripCount: Int { max(0, Int((size.height / stripHeight).rounded(.up))) }
    public var count: Int { images.count }
    /// Bytes of the retained bitmaps.
    public var retainedBytes: Int { images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    /// Strip `i`, in points from the top of the layout.
    public func rect(at i: Int) -> CGRect {
        let top = CGFloat(i) * stripHeight
        return CGRect(x: 0, y: top, width: size.width, height: max(0, min(stripHeight, size.height - top)))
    }

    /// The strips that intersect `visible` (points from the top), plus `margin` strips above and below, capped at
    /// `limit` strips.
    public func indices(near visible: CGRect, margin: Int = 1) -> [Int] {
        guard stripCount > 0 else { return [] }
        let first = Int((max(0, visible.minY) / stripHeight).rounded(.down))
        let last = Int((max(0, visible.maxY - 0.001) / stripHeight).rounded(.down))
        let low = max(0, first - margin), high = min(stripCount - 1, last + margin)
        guard low <= high else { return [] }
        return Array(Array(low...high).prefix(limit))
    }

    public func image(at i: Int) -> CGImage? {
        guard let image = images[i] else { return nil }
        touch(i)
        return image
    }

    /// Stores strip `i`, then drops least recently used strips not in `keeping` while over the limit. Returns the
    /// dropped indices.
    @discardableResult
    public func insert(_ image: CGImage, at i: Int, keeping: Set<Int> = []) -> [Int] {
        images[i] = image
        touch(i)
        var dropped: [Int] = []
        var candidates = order.filter { !keeping.contains($0) && $0 != i }
        while images.count > limit, !candidates.isEmpty {
            let victim = candidates.removeFirst()
            images[victim] = nil
            order.removeAll { $0 == victim }
            dropped.append(victim)
        }
        return dropped
    }

    public func removeAll() {
        images.removeAll()
        order.removeAll()
    }

    private func touch(_ i: Int) {
        order.removeAll { $0 == i }
        order.append(i)
    }
}
