import CoreGraphics
import CoreText
import Foundation

/// A glyph outline as an SVG document, in font units, with y flipped to SVG's downward axis.
public enum GlyphSVG {
    /// The SVG of `glyph` in the face at `faceIndex` of `fileURL`; nil when the face cannot be loaded.
    public static func document(fileURL: URL, faceIndex: Int, glyph: CGGlyph) -> String? {
        FontFile.font(at: fileURL, faceIndex: faceIndex).map { document(font: $0, glyph: glyph) }
    }

    /// The viewBox is the advance wide (the ink's extent for a zero-width glyph such as a combining mark) and
    /// ascent + descent high, with the ascender line at y = 0. A glyph without an outline (a space, a bitmap-only
    /// glyph) has an empty path.
    public static func document(font: CTFont, glyph: CGGlyph) -> String {
        let upem = CGFloat(max(1, CTFontGetUnitsPerEm(font)))
        let unitFont = CTFontCreateCopyWithAttributes(font, upem, nil, nil)
        let ascent = CTFontGetAscent(unitFont)
        let descent = CTFontGetDescent(unitFont)
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(unitFont, .horizontal, &g, &advance, 1)
        let path = CTFontCreatePathForGlyph(unitFont, glyph, nil)
        var minX: CGFloat = 0
        var width = advance.width
        if width <= 0, let path, !path.isEmpty {
            let box = path.boundingBoxOfPath
            minX = box.minX
            width = box.width
        }
        let d = path.map { pathData($0, ascent: ascent) } ?? ""
        let box = [minX, 0, max(0, width), ascent + descent].map { number($0.rounded()) }.joined(separator: " ")
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(box)\">"
            + "<path d=\"\(d)\"/></svg>\n"
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
