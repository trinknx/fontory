import CoreGraphics
import CoreText
import Foundation

public enum CompareMode: String, Codable, Sendable, CaseIterable { case overlay, sideBySide }
public enum CompareSizeRule: String, Codable, Sendable, CaseIterable { case sameSize, matchXHeight, matchCapHeight }

public struct CompareOptions: Sendable, Equatable {
    public var mode: CompareMode
    public var sizeRule: CompareSizeRule
    public var outlines: Bool
    public var guides: Bool

    public init(mode: CompareMode = .overlay, sizeRule: CompareSizeRule = .sameSize, outlines: Bool = false, guides: Bool = true) {
        self.mode = mode
        self.sizeRule = sizeRule
        self.outlines = outlines
        self.guides = guides
    }
}

/// Readout numbers for one side. Vertical metrics and bearings are fractions of the font's own em.
public struct CompareMetrics: Sendable, Equatable {
    public var xHeight: Double
    public var capHeight: Double
    public var ascender: Double
    public var descender: Double
    /// Points at the drawn size, after scale.
    public var lineWidth: Double
    /// Glyph mode only.
    public var advance: Double?
    public var leftBearing: Double?
    public var rightBearing: Double?
}

/// `path` is an immutable CGPath, never mutated after the scene is built.
public struct CompareSide: @unchecked Sendable {
    public var font: ResolvedFont?
    public var label: String
    /// Offline, unresolved or unloadable.
    public var isMissing: Bool
    public var metrics: CompareMetrics?
    public var missingCharacters: Int
    /// In canvas coordinates (y up); nil when missing.
    public var path: CGPath?
}

public struct CompareScene: Sendable {
    public var canvas: CGSize
    public var pointSize: CGFloat
    /// 1 for sameSize.
    public var scaleB: Double
    public var isGlyphMode: Bool
    public var a: CompareSide
    public var b: CompareSide
    /// One (overlay) or two (side by side: A then B).
    public var baselines: [CGFloat]
}

/// Shapes two fonts over the same text and draws them on top of each other or one above the other.
public enum CompareRenderer {
    private static let refSize: CGFloat = 100
    private static let margin = 0.05
    private static let capLimit = 0.6
    private static let glyphFill = 0.7

    /// A side shaped at `refSize` with the baseline at y 0 and the line starting at x 0.
    private struct Shaped {
        var font: CTFont
        var path: CGPath
        var width: Double
        var missing: Int
        var xHeight: Double, capHeight: Double, ascender: Double, descender: Double   // fractions of em
        var ink: CGRect                                                              // at refSize
    }

    // MARK: Scene

    public static func scene(a: ResolvedFont, aLabel: String, b: ResolvedFont?, bLabel: String,
                             text: String, options: CompareOptions, canvas: CGSize) -> CompareScene {
        let glyphMode = text.count == 1
        let shapedA = shape(a, text: text)
        let shapedB = b.flatMap { shape($0, text: text) }

        var scaleB = 1.0
        if let shapedA, let shapedB {
            let (ma, mb): (Double, Double)
            switch options.sizeRule {
            case .sameSize: (ma, mb) = (1, 1)
            case .matchXHeight: (ma, mb) = (shapedA.xHeight, shapedB.xHeight)
            case .matchCapHeight: (ma, mb) = (shapedA.capHeight, shapedB.capHeight)
            }
            let ratio = ma / mb
            if ratio.isFinite && ratio > 0 { scaleB = ratio }
        }

        let sideBySide = options.mode == .sideBySide
        let bandHeight = Double(canvas.height) / (sideBySide ? 2 : 1)
        let availableWidth = Double(canvas.width) * (1 - 2 * margin)
        var size = Double(refSize)
        let widest = max(shapedA?.width ?? 0, (shapedB?.width ?? 0) * scaleB)
        if widest > 0 { size = Double(refSize) * availableWidth / widest }
        if glyphMode {
            let tallest = max(shapedA?.ink.height ?? 0, (shapedB?.ink.height ?? 0) * scaleB)
            if tallest > 0 { size = min(size, Double(refSize) * glyphFill * bandHeight / tallest) }
        } else if let cap = shapedA?.capHeight, cap > 0 {
            size = min(size, capLimit * bandHeight / cap)
        }
        if !size.isFinite || size <= 0 { size = Double(refSize) }
        let pointSize = CGFloat(size)

        let kA = size / Double(refSize)
        let kB = kA * scaleB

        // Vertical extent above/below the baseline, in points.
        func extent(_ s: Shaped?, _ k: Double) -> (top: Double, bottom: Double)? {
            guard let s else { return nil }
            if glyphMode, !s.ink.isNull, !s.ink.isEmpty { return (Double(s.ink.maxY) * k, -Double(s.ink.minY) * k) }
            return (s.ascender * Double(refSize) * k, s.descender * Double(refSize) * k)
        }
        let extA = extent(shapedA, kA), extB = extent(shapedB, kB)
        func baseline(centre: Double, _ extents: [(top: Double, bottom: Double)?]) -> CGFloat {
            let present = extents.compactMap { $0 }
            guard !present.isEmpty else { return CGFloat(centre) }
            let top = present.map(\.top).max()!, bottom = present.map(\.bottom).max()!
            return CGFloat(centre - (top - bottom) / 2)
        }
        let height = Double(canvas.height)
        let baselines: [CGFloat]
        if sideBySide {
            baselines = [baseline(centre: height * 0.75, [extA]), baseline(centre: height * 0.25, [extB])]
        } else {
            baselines = [baseline(centre: height / 2, [extA, extB])]
        }

        // Outside glyph mode both lines start at one shared left origin (the wider line is centred).
        let sharedOriginX = (Double(canvas.width) - max((shapedA?.width ?? 0) * kA, (shapedB?.width ?? 0) * kB)) / 2

        func side(_ resolved: ResolvedFont?, _ label: String, _ shaped: Shaped?, k: Double, baseline: CGFloat) -> CompareSide {
            guard let shaped else {
                return CompareSide(font: resolved, label: label, isMissing: resolved != nil, metrics: nil,
                                   missingCharacters: 0, path: nil)
            }
            let width = shaped.width * k
            let originX = glyphMode ? (Double(canvas.width) - width) / 2 : sharedOriginX
            var metrics = CompareMetrics(xHeight: shaped.xHeight, capHeight: shaped.capHeight, ascender: shaped.ascender,
                                         descender: shaped.descender, lineWidth: width)
            if glyphMode {
                metrics.advance = shaped.width / Double(refSize)
                metrics.leftBearing = shaped.ink.isNull ? 0 : Double(shaped.ink.minX) / Double(refSize)
                metrics.rightBearing = shaped.ink.isNull ? 0 : (shaped.width - Double(shaped.ink.maxX)) / Double(refSize)
            }
            let transform = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: originX, ty: baseline)
            let path: CGPath? = shaped.path.isEmpty ? nil : shaped.path.copy(using: [transform])
            return CompareSide(font: resolved, label: label, isMissing: false, metrics: metrics,
                               missingCharacters: shaped.missing, path: path)
        }
        let sideA = side(a, aLabel, shapedA, k: kA, baseline: baselines[0])
        let sideB = side(b, bLabel, shapedB, k: kB, baseline: baselines[sideBySide ? 1 : 0])
        return CompareScene(canvas: canvas, pointSize: pointSize, scaleB: scaleB, isGlyphMode: glyphMode,
                            a: sideA, b: sideB, baselines: baselines)
    }

    public static func percentDifference(_ a: Double, _ b: Double) -> Double? {
        guard a != 0 else { return nil }
        let value = (b - a) / a * 100
        return value.isFinite ? value : nil
    }

    // MARK: Shaping

    private static func shape(_ resolved: ResolvedFont, text: String) -> Shaped? {
        guard !resolved.isMissing, let url = resolved.url,
              let font = LayoutRenderer.font(url, resolved.faceIndex, variations: resolved.reference.variations ?? [:], size: refSize)
        else { return nil }

        let coverage = PreviewRenderer.coverage(of: text, in: font)
        var scalar: [UniChar] = [0x25CC]
        var dottedGlyph: [CGGlyph] = [0]
        let hasPlaceholder = CTFontGetGlyphsForCharacters(font, &scalar, &dottedGlyph, 1)

        // Runs of drawable text; a missing character is ◌ when the font has it, else a drawn dotted circle.
        enum Piece { case text(String), dots }
        var pieces: [Piece] = []
        var current = ""
        var missing = 0
        for (character, covered) in zip(text, coverage) {
            if covered { current.append(character); continue }
            missing += 1
            if hasPlaceholder {
                current.append(PreviewRenderer.placeholder)
            } else {
                if !current.isEmpty { pieces.append(.text(current)); current = "" }
                pieces.append(.dots)
            }
        }
        if !current.isEmpty { pieces.append(.text(current)) }

        let path = CGMutablePath()
        var x = 0.0
        let emDot = Double(refSize)
        for piece in pieces {
            switch piece {
            case .text(let string):
                let attributed = NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font])
                let line = CTLineCreateWithAttributedString(attributed)
                appendGlyphs(of: line, font: font, to: path, offsetX: x)
                x += CTLineGetTypographicBounds(line, nil, nil, nil)
            case .dots:
                let centre = CGPoint(x: x + emDot * 0.3, y: emDot * 0.3)
                for i in 0..<8 {
                    let angle = Double(i) * .pi / 4
                    let dot = CGRect(x: centre.x + cos(angle) * emDot * 0.18 - emDot * 0.03,
                                     y: centre.y + sin(angle) * emDot * 0.18 - emDot * 0.03, width: emDot * 0.06, height: emDot * 0.06)
                    path.addEllipse(in: dot)
                }
                x += emDot * 0.6
            }
        }
        let width = x.isFinite ? x : 0
        let size = Double(refSize)
        let ink = path.isEmpty ? CGRect.null : path.boundingBoxOfPath
        return Shaped(font: font, path: path, width: width, missing: missing,
                      xHeight: verticalMetric(CTFontGetXHeight(font), fallback: "x", font: font) / size,
                      capHeight: verticalMetric(CTFontGetCapHeight(font), fallback: "H", font: font) / size,
                      ascender: Double(CTFontGetAscent(font)) / size, descender: Double(CTFontGetDescent(font)) / size,
                      ink: ink)
    }

    private static func appendGlyphs(of line: CTLine, font side: CTFont, to path: CGMutablePath, offsetX: Double) {
        let sideName = CTFontCopyPostScriptName(side) as String
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName as String] else { continue }
            let font = runFont as! CTFont   // swiftlint:disable:this force_cast
            // CoreText font fallback must never draw a glyph the font itself lacks.
            guard CTFontCopyPostScriptName(font) as String == sideName else { continue }
            for (glyph, position) in zip(glyphs, positions) {
                guard let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                path.addPath(glyphPath, transform: CGAffineTransform(translationX: position.x + offsetX, y: position.y))
            }
        }
    }

    /// A font's reported height, or the ink height of a reference letter when it reports 0.
    static func verticalMetric(_ reported: CGFloat, fallback letter: String, font: CTFont) -> Double {
        if reported > 0 { return Double(reported) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letter, attributes: [.init(kCTFontAttributeName as String): font]))
        let height = Double(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).maxY)
        return height.isFinite && height > 0 ? height : 0
    }

    // MARK: Drawing

    public static func draw(_ scene: CompareScene, options: CompareOptions, colorA: CGColor, colorB: CGColor,
                            guideColor: CGColor, in ctx: CGContext) {
        let sideBySide = scene.baselines.count == 2
        if options.guides {
            drawGuides(scene, side: scene.a, scale: 1, baseline: scene.baselines[0], color: colorA, guideColor: guideColor, drawsBaseline: true, in: ctx)
            drawGuides(scene, side: scene.b, scale: scene.scaleB, baseline: scene.baselines[sideBySide ? 1 : 0],
                       color: colorB, guideColor: guideColor, drawsBaseline: sideBySide, in: ctx)
        }
        ctx.saveGState()
        ctx.setLineWidth(1.5)
        ctx.setLineJoin(.round)
        let overlay = !sideBySide
        if let path = scene.a.path {
            ctx.addPath(path)
            if options.outlines {
                ctx.setStrokeColor(colorA)
                ctx.strokePath()
            } else {
                ctx.setFillColor(overlay ? (colorA.copy(alpha: colorA.alpha * 0.3) ?? colorA) : colorA)
                ctx.fillPath()
            }
        }
        if let path = scene.b.path {
            ctx.addPath(path)
            if options.outlines || overlay {
                ctx.setStrokeColor(colorB)
                ctx.strokePath()
            } else {
                ctx.setFillColor(colorB)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    private static func drawGuides(_ scene: CompareScene, side: CompareSide, scale: Double, baseline: CGFloat,
                                   color: CGColor, guideColor: CGColor, drawsBaseline: Bool, in ctx: CGContext) {
        guard let metrics = side.metrics else { return }
        let width = scene.canvas.width
        ctx.saveGState()
        ctx.setLineWidth(0.5)
        if drawsBaseline {
            ctx.setStrokeColor(guideColor)
            ctx.move(to: CGPoint(x: 0, y: baseline))
            ctx.addLine(to: CGPoint(x: width, y: baseline))
            ctx.strokePath()
        }
        ctx.setStrokeColor(color.copy(alpha: color.alpha * 0.6) ?? color)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        let unit = Double(scene.pointSize) * scale
        for offset in [metrics.xHeight, metrics.capHeight, metrics.ascender, -metrics.descender] {
            let y = baseline + CGFloat(offset * unit)
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: width, y: y))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    public static func image(_ scene: CompareScene, options: CompareOptions, colorA: CGColor, colorB: CGColor,
                             guideColor: CGColor, background: CGColor?, scale: CGFloat) -> CGImage? {
        let w = Int((scene.canvas.width * scale).rounded()), h = Int((scene.canvas.height * scale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: scale, y: scale)
        draw(scene, options: options, colorA: colorA, colorB: colorB, guideColor: guideColor, in: ctx)
        return ctx.makeImage()
    }
}
