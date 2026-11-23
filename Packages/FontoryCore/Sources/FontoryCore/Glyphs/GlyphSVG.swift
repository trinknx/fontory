import CoreGraphics
import CoreText
import Foundation

/// A glyph outline as an SVG document, in font units, with y flipped to SVG's downward axis.
public enum GlyphSVG {
    /// The SVG of `glyph` in the face at `faceIndex` of `fileURL`; nil when the face cannot be loaded or the glyph has
    /// no outline.
    public static func document(fileURL: URL, faceIndex: Int, glyph: CGGlyph) -> String? {
        FontFile.font(at: fileURL, faceIndex: faceIndex).flatMap { document(font: $0, glyph: glyph) }
    }

    /// Whether `glyph` has a vector outline. Spaces, and bitmap or colour glyphs (sbix, emoji), have none.
    public static func hasOutline(font: CTFont, glyph: CGGlyph) -> Bool {
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return false }
        return !path.isEmpty
    }

    /// The outline in font units, or nil when the glyph has none (see `hasOutline`).
    ///
    /// The viewBox is the union of the advance × (ascent + descent) box, with the ascender line at y = 0, and the
    /// ink's bounds, so negative side bearings, swashes and tall accents are not clipped.
    public static func document(font: CTFont, glyph: CGGlyph) -> String? {
        let upem = CGFloat(max(1, CTFontGetUnitsPerEm(font)))
        let unitFont = CTFontCreateCopyWithAttributes(font, upem, nil, nil)
        guard let path = CTFontCreatePathForGlyph(unitFont, glyph, nil), !path.isEmpty else { return nil }
        let ascent = CTFontGetAscent(unitFont)
        let descent = CTFontGetDescent(unitFont)
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(unitFont, .horizontal, &g, &advance, 1)
        // In SVG coordinates (y down from the ascender).
        let ink = path.boundingBoxOfPath
        let inkBox = CGRect(x: ink.minX, y: ascent - ink.maxY, width: ink.width, height: ink.height)
        let typographic = CGRect(x: 0, y: 0, width: max(0, advance.width), height: ascent + descent)
        let union = typographic.union(inkBox)
        let minX = union.minX.rounded(.down), minY = union.minY.rounded(.down)
        let box = [minX, minY, union.maxX.rounded(.up) - minX, union.maxY.rounded(.up) - minY].map(number)
            .joined(separator: " ")
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(box)\">"
            + "<path d=\"\(pathData(path, ascent: ascent))\"/></svg>\n"
    }

    /// SVG path data for `path`, flipping y around the ascender (y' = ascent − y).
    public static func pathData(_ path: CGPath, ascent: CGFloat) -> String {
        var parts: [String] = []
        func pt(_ p: CGPoint) -> String { number(p.x) + " " + number(ascent - p.y) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: parts.append("M" + pt(e.points[0]))
            case .addLineToPoint: parts.append("L" + pt(e.points[0]))
            case .addQuadCurveToPoint: parts.append("Q" + pt(e.points[0]) + " " + pt(e.points[1]))
            case .addCurveToPoint: parts.append("C" + pt(e.points[0]) + " " + pt(e.points[1]) + " " + pt(e.points[2]))
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined()
    }

    /// At most two decimals, no trailing zeros, no "-0".
    static func number(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        let rounded = (v * 100).rounded() / 100
        if rounded == 0 { return "0" }
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var s = String(format: "%.2f", Double(rounded))
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}
