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

    /// The point size at which a face whose ascent and descent (per em) are given fills `fill` of the cell height.
    public static func pointSize(cellHeight: CGFloat, ascent: CGFloat, descent: CGFloat) -> CGFloat {
        let box = ascent + descent
        guard box > 0.01 else { return cellHeight * fill }
        return max(1, (cellHeight * fill / box * 2).rounded() / 2)   // half-point steps keep the font cache small
    }

    /// Renders `glyph` of `font` (already at the cell's point size). The typographic box is centred vertically; the
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
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baseline = ((size.height / 2 - (ascent - descent) / 2) * style.scale).rounded() / style.scale
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
