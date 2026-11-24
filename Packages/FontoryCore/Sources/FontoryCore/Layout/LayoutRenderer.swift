import CoreGraphics
import CoreText
import Foundation

/// What a render found: blocks drawn in the system font because their font is unresolved, offline or unreadable,
/// and how many characters of each block its font lacks. Keys are block ids (`UUID.uuidString`).
public struct LayoutRenderReport: Sendable, Equatable {
    public var missingFontBlockIDs: Set<String>
    /// Block id → number of characters the block's font lacks (counted whether or not `showMissing` is on).
    public var missingCharacters: [String: Int]
    /// Block id → lines drawn (text lines, waterfall sizes, charset rows). For tests.
    var lineCounts: [String: Int] = [:]

    public init(missingFontBlockIDs: Set<String> = [], missingCharacters: [String: Int] = [:]) {
        self.missingFontBlockIDs = missingFontBlockIDs
        self.missingCharacters = missingCharacters
    }
}

public enum LayoutRenderError: Error, Equatable {
    case cannotCreatePDF(URL)
}

/// Draws a `LayoutDocument` into any CGContext (screen bitmap, PDF, print) with CoreText. Pure and thread-safe:
/// call it off the main thread. Fonts load from their files, without activation, through a shared LRU cache.
public enum LayoutRenderer {
    // MARK: Drawing

    /// Draws `doc` into `pageRect` of `ctx` (CoreGraphics coordinates, y up). The page is scaled to fill
    /// `pageRect`; block frames are page points with the origin top-left, and each block is clipped to its frame.
    @discardableResult
    public static func draw(_ doc: LayoutDocument, fonts: [FontReference: ResolvedFont], in ctx: CGContext,
                            pageRect: CGRect) -> LayoutRenderReport {
        var report = LayoutRenderReport()
        let page = CGSize(width: max(1, doc.pageSize.w), height: max(1, doc.pageSize.h))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: pageRect.minX, y: pageRect.minY)
        ctx.scaleBy(x: pageRect.width / page.width, y: pageRect.height / page.height)
        ctx.setFillColor(LayoutColor.cgColor(doc.background) ?? CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: page))
        ctx.textMatrix = .identity
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)

        let foreground = LayoutColor.cgColor(doc.foreground) ?? CGColor(gray: 0, alpha: 1)
        for block in doc.blocks {
            let id = block.id.uuidString
            // Top-left frame → y-up rect on the page.
            let rect = CGRect(x: block.frame.x, y: page.height - block.frame.y - block.frame.h,
                              width: max(0, block.frame.w), height: max(0, block.frame.h))
            guard rect.width > 0, rect.height > 0 else { continue }
            let color = block.color.flatMap(LayoutColor.cgColor) ?? foreground
            let resolved = fonts[block.font]
            var fontMissing = resolved == nil || resolved?.isMissing == true || resolved?.url == nil
            let fontAt: (CGFloat) -> CTFont = { size in
                if !fontMissing, let r = resolved, let url = r.url,
                   let f = font(url, r.faceIndex, variations: block.font.variations ?? [:], size: size) {
                    return f
                }
                fontMissing = true
                return systemFont(size: size)
            }
            ctx.saveGState()
            ctx.clip(to: rect)
            let drawn: (lines: Int, missing: Int)
            switch block.kind {
            case .text: drawn = drawText(block, rect: rect, fontAt: fontAt, color: color, showMissing: doc.showMissing, ctx: ctx)
            case .waterfall: drawn = drawWaterfall(block, rect: rect, fontAt: fontAt, color: color, showMissing: doc.showMissing, ctx: ctx)
            case .charset: drawn = drawCharset(block, rect: rect, fontAt: fontAt, color: color, showMissing: doc.showMissing, ctx: ctx)
            }
            ctx.restoreGState()
            if fontMissing { report.missingFontBlockIDs.insert(id) }
            if drawn.missing > 0 { report.missingCharacters[id] = drawn.missing }
            report.lineCounts[id] = drawn.lines
        }
        return report
    }

    /// The page as a bitmap at `scale` pixels per point (for the canvas), with the render report.
    public static func renderImage(_ doc: LayoutDocument, fonts: [FontReference: ResolvedFont],
                                   scale: CGFloat) -> (image: CGImage?, report: LayoutRenderReport) {
        let size = CGSize(width: max(1, doc.pageSize.w), height: max(1, doc.pageSize.h))
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard scale > 0, w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: PreviewRequest.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (nil, LayoutRenderReport()) }
        let report = draw(doc, fonts: fonts, in: ctx, pageRect: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx.makeImage(), report)
    }

    /// The page as a bitmap at `scale` pixels per point (for the canvas).
    public static func image(_ doc: LayoutDocument, fonts: [FontReference: ResolvedFont], scale: CGFloat) -> CGImage? {
        renderImage(doc, fonts: fonts, scale: scale).image
    }

    /// Writes a vector PDF with one page per document, each at its `pageSize`. The file is replaced atomically.
    /// `shouldContinue(pageIndex, pageCount)` is asked before each page; when it returns false nothing is written
    /// and `CancellationError` is thrown (progress and Cancel for long exports).
    public static func pdf(_ docs: [LayoutDocument], fonts: [FontReference: ResolvedFont], to url: URL,
                           shouldContinue: ((_ pageIndex: Int, _ pageCount: Int) -> Bool)? = nil) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard let ctx = CGContext(temp as CFURL, mediaBox: nil, nil) else { throw LayoutRenderError.cannotCreatePDF(url) }
        for (index, doc) in docs.enumerated() {
            if let shouldContinue, !shouldContinue(index, docs.count) {
                ctx.closePDF()
                try? FileManager.default.removeItem(at: temp)
                throw CancellationError()
            }
            var box = CGRect(x: 0, y: 0, width: max(1, doc.pageSize.w), height: max(1, doc.pageSize.h))
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            draw(doc, fonts: fonts, in: ctx, pageRect: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// One document per candidate family (deduplicated by family, lowercased), in order. Every block's font is
    /// replaced by that family's closest style to the block's current style (`PairingCycler.closestStyle`).
    /// `styles` returns the styles of a reference's family; it is called once per family.
    public static func documentsForEachCandidate(_ doc: LayoutDocument,
                                                 styles: (FontReference) -> [PairingStyle]) -> [LayoutDocument] {
        var memo: [String: [PairingStyle]] = [:]
        func stylesOf(_ ref: FontReference) -> [PairingStyle] {
            let key = ref.family.lowercased()
            if let cached = memo[key] { return cached }
            let out = styles(ref)
            memo[key] = out
            return out
        }
        func current(_ ref: FontReference) -> PairingStyle {
            let own = stylesOf(ref)
            return own.first { $0.reference == ref }
                ?? own.first { $0.reference.postScriptName == ref.postScriptName }
                ?? PairingStyle(reference: ref, name: "", weight: 400, width: 5, isItalic: false)
        }
        var seen = Set<String>()
        var out: [LayoutDocument] = []
        for candidate in doc.candidates where seen.insert(candidate.family.lowercased()).inserted {
            let family = stylesOf(candidate)
            var page = doc
            page.name = "\(doc.name) — \(candidate.family)"
            for i in page.blocks.indices {
                page.blocks[i].font = family.isEmpty ? candidate
                    : PairingCycler.closestStyle(to: current(doc.blocks[i].font), in: family)
            }
            out.append(page)
        }
        return out
    }

    // MARK: Blocks

    private static func drawText(_ block: LayoutBlock, rect: CGRect, fontAt: (CGFloat) -> CTFont, color: CGColor,
                                 showMissing: Bool, ctx: CGContext) -> (lines: Int, missing: Int) {
        let size = CGFloat(max(1, block.size))
        let font = fontAt(size)
        let paragraph = paragraphStyle(alignment: ctAlignment(block.alignment),
                                       lineSpacing: max(1, size * CGFloat(block.lineHeight)))
        let (text, missing) = attributedText(block.text, font: font, size: size, color: color, showMissing: showMissing,
                                             paragraph: paragraph, kern: kern(block, size: size))
        guard text.length > 0 else { return (0, missing) }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return (CFArrayGetCount(CTFrameGetLines(frame)), missing)
    }

    /// One line per size (the block's size when the list is empty), top to bottom, `lineHeight × size` apart.
    private static func drawWaterfall(_ block: LayoutBlock, rect: CGRect, fontAt: (CGFloat) -> CTFont, color: CGColor,
                                      showMissing: Bool, ctx: CGContext) -> (lines: Int, missing: Int) {
        let string = block.text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let sizes = (block.sizes.isEmpty ? [block.size] : block.sizes).map { CGFloat(max(1, $0)) }
        var top: CGFloat = 0
        var lines = 0, missing = 0
        for size in sizes {
            guard top < rect.height else { break }
            let font = fontAt(size)
            let (text, lineMissing) = attributedText(string, font: font, size: size, color: color,
                                                     showMissing: showMissing, paragraph: nil, kern: kern(block, size: size))
            if lines == 0 { missing = lineMissing }   // the same text on every line: count it once
            let line = CTLineCreateWithAttributedString(text)
            let lineHeight = max(1, size * CGFloat(block.lineHeight))
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            let baselineFromTop = top + ascent + (lineHeight - ascent - descent) / 2
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let x: CGFloat = switch block.alignment {
            case .left, .justified: 0
            case .center: (rect.width - width) / 2
            case .right: rect.width - width
            }
            ctx.textPosition = CGPoint(x: rect.minX + x, y: rect.maxY - baselineFromTop)
            CTLineDraw(line, ctx)
            lines += 1
            top += lineHeight
        }
        return (lines, missing)
    }

    /// Columns of a charset grid: max(4, round(width / (size × 1.6))).
    static func charsetColumns(width: Double, size: Double) -> Int {
        max(4, Int((width / (max(1, size) * 1.6)).rounded()))
    }

    /// One character per cell, centred; cells are `width / columns` wide and `size × 1.6` tall. White space only
    /// separates groups in the stored text and takes no cell.
    private static func drawCharset(_ block: LayoutBlock, rect: CGRect, fontAt: (CGFloat) -> CTFont, color: CGColor,
                                    showMissing: Bool, ctx: CGContext) -> (lines: Int, missing: Int) {
        let size = CGFloat(max(1, block.size))
        let font = fontAt(size)
        let characters = block.text.filter { !$0.isWhitespace }
        let columns = charsetColumns(width: rect.width, size: size)
        let cellWidth = rect.width / CGFloat(columns), cellHeight = size * 1.6
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        var missing = 0, rows = 0
        for (i, character) in characters.enumerated() {
            let row = i / columns, column = i % columns
            let cellTop = CGFloat(row) * cellHeight
            let (text, charMissing) = attributedText(String(character), font: font, size: size, color: color,
                                                     showMissing: showMissing, paragraph: nil, kern: 0)
            missing += charMissing
            guard cellTop < rect.height else { continue }   // keep counting missing characters below the frame
            rows = max(rows, row + 1)
            let line = CTLineCreateWithAttributedString(text)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let centreY = rect.maxY - cellTop - cellHeight / 2
            ctx.textPosition = CGPoint(x: rect.minX + CGFloat(column) * cellWidth + (cellWidth - width) / 2,
                                       y: centreY - (ascent - descent) / 2)
            CTLineDraw(line, ctx)
        }
        return (rows, missing)
    }

    // MARK: Text

    /// Tracking in 1/1000 em as a kern in points.
    private static func kern(_ block: LayoutBlock, size: CGFloat) -> CGFloat {
        CGFloat(block.tracking) / 1000 * size
    }

    private static func ctAlignment(_ a: LayoutAlignment) -> CTTextAlignment {
        switch a {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    /// Alignment and a fixed line height: baselines exactly `lineSpacing` apart, whatever the fonts' own gaps.
    private static func paragraphStyle(alignment: CTTextAlignment, lineSpacing: CGFloat) -> CTParagraphStyle {
        var alignment = alignment
        var lineSpacing = lineSpacing
        var zero: CGFloat = 0
        return withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &lineSpacing) { l in
                withUnsafeBytes(of: &zero) { z in
                    let settings = [
                        CTParagraphStyleSetting(spec: .alignment, valueSize: a.count, value: a.baseAddress!),
                        CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: l.count, value: l.baseAddress!),
                        CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: l.count, value: l.baseAddress!),
                        CTParagraphStyleSetting(spec: .minimumLineSpacing, valueSize: z.count, value: z.baseAddress!),
                        CTParagraphStyleSetting(spec: .maximumLineSpacing, valueSize: z.count, value: z.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    /// The styled text and how many characters `font` lacks. With `showMissing`, each missing character is set as
    /// ◌ in the system font at `size` (faint), so CoreText has nothing left to substitute from a fallback font —
    /// the same rule as the previews (`PreviewRenderer.coverage`).
    static func attributedText(_ string: String, font: CTFont, size: CGFloat, color: CGColor, showMissing: Bool,
                               paragraph: CTParagraphStyle?, kern: CGFloat) -> (text: NSAttributedString, missing: Int) {
        var attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]
        if let paragraph { attrs[.init(kCTParagraphStyleAttributeName as String)] = paragraph }
        if kern != 0 { attrs[.init(kCTKernAttributeName as String)] = kern }
        let coverage = PreviewRenderer.coverage(of: string, in: font)
        let missing = coverage.count { !$0 }
        guard showMissing, missing > 0 else { return (NSAttributedString(string: string, attributes: attrs), missing) }
        var placeholderAttrs = attrs
        placeholderAttrs[.init(kCTFontAttributeName as String)] = systemFont(size: size)
        placeholderAttrs[.init(kCTForegroundColorAttributeName as String)] = color.copy(alpha: color.alpha * 0.4) ?? color
        let out = NSMutableAttributedString()
        var covered = ""
        for (character, isCovered) in zip(string, coverage) {
            if isCovered {
                covered.append(character)
            } else {
                if !covered.isEmpty { out.append(NSAttributedString(string: covered, attributes: attrs)); covered = "" }
                out.append(NSAttributedString(string: PreviewRenderer.placeholder, attributes: placeholderAttrs))
            }
        }
        if !covered.isEmpty { out.append(NSAttributedString(string: covered, attributes: attrs)) }
        return (out, missing)
    }

    // MARK: Fonts

    private struct FaceKey: Hashable, Sendable {
        let url: URL
        let faceIndex: Int
    }

    private struct SizedKey: Hashable, Sendable {
        let face: FaceKey
        let variations: [String: Double]
        let size: CGFloat
    }

    private static let baseFonts = LRUCache<FaceKey, CTFont>(limit: 256)
    /// Faces whose file could not be loaded: not re-parsed on every render.
    private static let failedFaces = LRUCache<FaceKey, Bool>(limit: 1024)
    private static let sizedFonts = LRUCache<SizedKey, CTFont>(limit: 1024)
    private static let systemFonts = LRUCache<CGFloat, CTFont>(limit: 64)

    /// Drops every cached font and load failure (e.g. after files were replaced).
    public static func forgetFonts() {
        baseFonts.removeAll()
        failedFaces.removeAll()
        sizedFonts.removeAll()
    }

    /// The face at `size` with `variations` (axis tag → value) applied; nil when the file cannot be loaded.
    static func font(_ url: URL, _ faceIndex: Int, variations: [String: Double], size: CGFloat) -> CTFont? {
        let face = FaceKey(url: url, faceIndex: faceIndex)
        let key = SizedKey(face: face, variations: variations, size: size)
        if let cached = sizedFonts[key] { return cached }
        let base: CTFont
        if let cached = baseFonts[face] {
            base = cached
        } else {
            if failedFaces[face] != nil { return nil }
            guard let loaded = FontFile.font(at: url, faceIndex: faceIndex) else {
                failedFaces[face] = true
                return nil
            }
            baseFonts[face] = loaded
            base = loaded
        }
        var attributes: CTFontDescriptor?
        if !variations.isEmpty {
            let values = Dictionary(variations.map { (NSNumber(value: VariationInfo.code($0.key)), NSNumber(value: $0.value)) },
                                    uniquingKeysWith: { a, _ in a })
            attributes = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: values] as CFDictionary)
        }
        let font = CTFontCreateCopyWithAttributes(base, size, nil, attributes)
        sizedFonts[key] = font
        return font
    }

    static func systemFont(size: CGFloat) -> CTFont {
        if let cached = systemFonts[size] { return cached }
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        systemFonts[size] = font
        return font
    }
}
