import CoreGraphics
import CoreText
import Foundation

/// How a glyph cell is drawn. Colors are kept as sRGB components so the style can key a cache.
public struct GlyphCellStyle: Sendable, Hashable {
    /// In points; the bitmap is `size * scale` pixels.
    public var size: CGSize
    public var scale: CGFloat
    public var showGuides: Bool
    public let foregroundComponents: [CGFloat]
    public let backgroundComponents: [CGFloat]

    public init(size: CGSize, scale: CGFloat, foreground: CGColor, background: CGColor, showGuides: Bool = true) {
        self.size = size
        self.scale = scale
        self.showGuides = showGuides
        foregroundComponents = PreviewRequest.components(foreground)
        backgroundComponents = PreviewRequest.components(background)
    }

    var foreground: CGColor { Self.color(foregroundComponents) }
    var background: CGColor { Self.color(backgroundComponents) }

    private static func color(_ c: [CGFloat]) -> CGColor {
        switch c.count {
        case 4: CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        case 2: CGColor(gray: c[0], alpha: c[1])
        default: CGColor(gray: 0, alpha: 1)
        }
    }
}

/// The vertical extent of a face's glyph cells, above and below the baseline, per em. One per face, so every cell
/// of the face shares its scale and guides.
public struct GlyphCellBox: Sendable, Hashable {
    public var above: CGFloat
    public var below: CGFloat

    public init(above: CGFloat, below: CGFloat) {
        self.above = above
        self.below = below
    }
}

/// Draws one glyph centred on its face's dashed metric guides. Pure; safe from any thread.
public enum GlyphCellRenderer {
    /// Share of the cell height the face's ascent + descent fill.
    public static let fill: CGFloat = 0.72

    /// The box a face's cells are drawn in (per em), from its metrics, the ink of its mapped glyphs (`mappedInk`)
    /// and the ink of all its glyphs (`allInk`, mapped and unmapped), all per em; empty rects are ignored.
    ///
    /// Normally this is the typographic box. Faces whose box is far taller than their letters (Zapfino: ascent +
    /// descent ≈ 3.4 em) are fitted to their real ink so they are not drawn tiny:
    /// 1. The fitted box, per side, is min(typographic, max(cap-height rule, ink extent)). The cap-height rule is
    ///    1.3 × cap height above and max(0.25 em, 0.35 × cap height) below; the ink extent is the 97th percentile
    ///    of the ink tops and the 3rd percentile of the ink bottoms.
    /// 2. The box then grows from the fitted box toward the typographic one (in 5% steps) until it cuts no glyph,
    ///    mapped or unmapped, that the typographic box shows whole, neither vertically nor horizontally (ink wider
    ///    than the cell; see `clips`), with a margin of `fitMargin`. So no face loses a glyph to the fit; scripts whose marks rise far
    ///    above the cap height (Khmer, Arabic, Myanmar) keep (nearly) their typographic box.
    /// Without a cap height the typographic box is used.
    public static func cellBox(ascent: CGFloat, descent: CGFloat, capHeight: CGFloat, mappedInk: [CGRect],
                               allInk: [CGRect]) -> GlyphCellBox {
        let typographic = GlyphCellBox(above: ascent, below: descent)
        let rects = mappedInk.filter { !$0.isEmpty && $0.height > 0 }
        guard capHeight > 0, !rects.isEmpty else { return typographic }
        let inkTop = percentile(rects.map(\.maxY), 0.97)
        let inkBottom = percentile(rects.map(\.minY), 0.03)
        let fitted = GlyphCellBox(above: min(ascent, max(capHeight * 1.3, inkTop)),
                                  below: min(descent, max(0.25, capHeight * 0.35, -inkBottom)))
        guard fitted != typographic else { return typographic }
        let shownWhole = allInk.filter { !$0.isEmpty && !clips($0, box: typographic) }
        for step in 0..<20 {
            let t = CGFloat(step) / 20
            let box = GlyphCellBox(above: fitted.above + (ascent - fitted.above) * t,
                                   below: fitted.below + (descent - fitted.below) * t)
            // A small margin absorbs measuring differences between sizes and variation instances.
            if !shownWhole.contains(where: { clips($0, box: box, margin: fitMargin) }) { return box }
        }
        return typographic
    }

    /// How far (per em) inside the cell edge a glyph must stay when a fitted box is checked.
    static let fitMargin: CGFloat = 0.005

    /// Whether ink `rect` (per em) is cut by a cell drawn with `box`. The cell is square, (above + below) / `fill`
    /// em on a side, centred vertically on the box. Horizontally a glyph is centred on its ink when it would
    /// overflow (see `render`), so only ink wider than the cell is cut. Ink within 0.001 em of an edge counts as
    /// inside; a positive `margin` moves every edge inward.
    public static func clips(_ rect: CGRect, box: GlyphCellBox, margin: CGFloat = 0) -> Bool {
        let side = (box.above + box.below) / fill - 2 * margin
        let half = side / 2, centre = (box.above - box.below) / 2
        return rect.maxY > centre + half + 0.001 || rect.minY < centre - half - 0.001 || rect.width > side + 0.001
    }

    private static func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// The point size at which `box` (per em) fills `fill` of the cell height.
    public static func pointSize(cellHeight: CGFloat, box: GlyphCellBox) -> CGFloat {
        let height = box.above + box.below
        guard height > 0.01 else { return cellHeight * fill }
        // Half-point steps keep the font cache small; rounding down keeps the box inside the cell.
        return max(1, (cellHeight * fill / height * 2).rounded(.down) / 2)
    }

    /// Renders `glyph` of `font` (already at the cell's point size). The face's `box` (per em) is centred vertically; the
    /// advance is centred horizontally, or the ink when the glyph has no advance or its ink would leave the cell.
    public static func render(font: CTFont, glyph: CGGlyph, style: GlyphCellStyle, box: GlyphCellBox) -> CGImage? {
        let w = Int((style.size.width * style.scale).rounded())
        let h = Int((style.size.height * style.scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: PreviewRequest.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(style.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: style.scale, y: style.scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)

        let size = style.size
        let em = CTFontGetSize(font)
        let baseline = ((size.height / 2 - (box.above - box.below) * em / 2) * style.scale).rounded() / style.scale
        if style.showGuides {
            MetricGuides.draw(ctx, font: font, baseline: baseline, width: size.width, foreground: style.foreground,
                              scale: style.scale)
        }
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, nil, 1)
        var x = (size.width - advance.width) / 2
        if advance.width <= 0 || (!ink.isEmpty && (x + ink.minX < 0 || x + ink.maxX > size.width)) {
            x = size.width / 2 - ink.midX
        }
        ctx.setFillColor(style.foreground)
        var position = CGPoint(x: x, y: baseline)
        CTFontDrawGlyphs(font, &g, &position, 1, ctx)
        return ctx.makeImage()
    }
}
