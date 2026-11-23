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
    let font: CTFont
    let lines: [PlacedLine]

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
        let size = CGSize(width: max(1, style.width), height: (height + 2 * inset).rounded(.up))
        return BodyTextLayout(style: style, size: size, columnWidth: columnWidth, columnCount: n,
                              isComplete: best.complete, font: font, lines: lines)
    }

    /// Renders `layout` as strips of at most `stripHeight` points, top to bottom.
    public static func render(_ layout: BodyTextLayout, scale: CGFloat, stripHeight: CGFloat = 1024,
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
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: PreviewRequest.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
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
        let margin = max(style.pointSize * 2, style.lineSpacing * 2)
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
