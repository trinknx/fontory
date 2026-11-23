import CoreGraphics
import CoreText
import Foundation

/// Loads one face of a font file without registering it.
public enum FontFile {
    /// The face at `faceIndex` of the file at `url`, at `size` points; nil when the file cannot be read or has no
    /// such face.
    public static func font(at url: URL, faceIndex: Int, size: CGFloat = 1) -> CTFont? {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              descs.indices.contains(faceIndex) else { return nil }
        return CTFontCreateWithFontDescriptor(descs[faceIndex], size, nil)
    }
}

/// The dashed metric guides shared by the previews and the glyph cells: baseline (warm accent), and x-height,
/// cap-height, ascender and descender in the text color, faint.
enum MetricGuides {
    static let baselineColor = CGColor(srgbRed: 0.93, green: 0.42, blue: 0.16, alpha: 0.85)

    /// Strokes the guides of `font` (at its point size) across `width` points, around `baseline`.
    static func draw(_ ctx: CGContext, font: CTFont, baseline: CGFloat, width: CGFloat, foreground: CGColor, scale: CGFloat) {
        let neutral = foreground.copy(alpha: 0.28) ?? foreground
        ctx.saveGState()
        ctx.setLineWidth(1 / scale)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        func stroke(_ y: CGFloat, _ color: CGColor) {
            // Snap to the pixel grid so the hairline stays crisp.
            let snapped = ((y * scale).rounded() + 0.5) / scale
            ctx.setStrokeColor(color)
            ctx.strokeLineSegments(between: [CGPoint(x: 0, y: snapped), CGPoint(x: width, y: snapped)])
        }
        for offset in [CTFontGetAscent(font), CTFontGetCapHeight(font), CTFontGetXHeight(font), -CTFontGetDescent(font)]
            where offset != 0 {
            stroke(baseline + offset, neutral)
        }
        stroke(baseline, baselineColor)
        ctx.restoreGState()
    }
}
