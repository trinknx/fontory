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

/// Draws one glyph centred on its face's dashed metric guides. Pure; safe from any thread.
public enum GlyphCellRenderer {
    /// Share of the cell height the face's ascent + descent fill.
    public static let fill: CGFloat = 0.72

    /// The vertical extent a cell fits, above and below the baseline, in the units of the arguments (per em, or
    /// points). Normally the typographic box (ascent, descent). Faces whose box is far taller than their letters
    /// (Zapfino: ascent + descent ≈ 3.4 em) are fitted to their typical ink instead, so they are not drawn tiny:
    /// at most 1.3 × the cap height above and max(0.25 em, 0.35 × cap height) below. Without a cap height the box
    /// is used. Guides beyond the reference box fall outside the cell; baseline, x-height and cap height stay.
    public static func referenceBox(ascent: CGFloat, descent: CGFloat, capHeight: CGFloat, em: CGFloat = 1)
        -> (above: CGFloat, below: CGFloat) {
        guard capHeight > 0 else { return (ascent, descent) }
        return (min(ascent, capHeight * 1.3), min(descent, max(0.25 * em, capHeight * 0.35)))
    }

    /// The point size at which a face whose metrics (per em) are given fills `fill` of the cell height with its
    /// reference box.
    public static func pointSize(cellHeight: CGFloat, ascent: CGFloat, descent: CGFloat, capHeight: CGFloat) -> CGFloat {
        let ref = referenceBox(ascent: ascent, descent: descent, capHeight: capHeight)
        let box = ref.above + ref.below
        guard box > 0.01 else { return cellHeight * fill }
        return max(1, (cellHeight * fill / box * 2).rounded() / 2)   // half-point steps keep the font cache small
    }

    /// Renders `glyph` of `font` (already at the cell's point size). The reference box is centred vertically; the
    /// advance is centred horizontally, or the ink when the glyph has no advance or its ink would leave the cell.
    public static func render(font: CTFont, glyph: CGGlyph, style: GlyphCellStyle) -> CGImage? {
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
        let ref = referenceBox(ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
                               capHeight: CTFontGetCapHeight(font), em: CTFontGetSize(font))
        let baseline = ((size.height / 2 - (ref.above - ref.below) / 2) * style.scale).rounded() / style.scale
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
