import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A glyph rendered to a bitmap, for pasting into raster editors.
public enum GlyphImage {
    public static let emPixels: CGFloat = 2048
    private static let maxSide: CGFloat = 8192

    /// Whether the face draws colour or bitmap glyphs (`COLR`, `SVG `, `sbix`, `CBDT`, or CoreText's colour-glyphs
    /// trait). Such faces may keep plain outlines as a fallback, so exports give a full-colour PNG and no SVG.
    /// Reads only the table directory, never a table's bytes (the emoji `sbix` is huge).
    public static func isColourFace(_ font: CTFont) -> Bool {
        if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return true }
        let colourTags: Set<UInt32> = Set(["COLR", "SVG ", "sbix", "CBDT"].map { tag in
            tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        })
        guard let tables = CTFontCopyAvailableTables(font, []) else { return false }
        for i in 0..<CFArrayGetCount(tables) {
            let raw = UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tables, i)))
            if colourTags.contains(raw) { return true }
        }
        return false
    }

    /// PNG of `glyph` with em = 2048 px, cropped to the ink plus a margin of 2% of the em, transparent background.
    /// Outline glyphs are filled black; colour and bitmap glyphs are drawn in colour (CTFontDrawGlyphs).
    /// nil for a glyph with no ink (space).
    public static func png(font: CTFont, glyph: CGGlyph) -> Data? {
        let big = CTFontCreateCopyWithAttributes(font, emPixels, nil, nil)
        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(big, .horizontal, &g, &bounds, 1)
        guard !bounds.isNull, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width > 0, bounds.height > 0
        else { return nil }
        let margin = emPixels * 0.02
        let minX = (bounds.minX - margin).rounded(.down), minY = (bounds.minY - margin).rounded(.down)
        let width = (bounds.maxX + margin).rounded(.up) - minX
        let height = (bounds.maxY + margin).rounded(.up) - minY
        guard width >= 1, height >= 1, width <= maxSide, height <= maxSide else { return nil }
        guard let ctx = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        var position = CGPoint(x: -minX, y: -minY)
        CTFontDrawGlyphs(big, &g, &position, 1, ctx)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
