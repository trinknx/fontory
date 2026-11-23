import CoreGraphics
import CoreText
import Foundation

/// Renders single-line font previews with CoreText. Safe to call concurrently from many threads.
public final class PreviewRenderer: Sendable {
    private struct FontKey: Hashable, Sendable {
        let url: URL
        let faceIndex: Int
    }

    private let fonts: LRUCache<FontKey, CTFont>
    /// Faces whose file could not be loaded (junk, missing, wrong index): not re-parsed on every request.
    private let failed: LRUCache<FontKey, Bool>
    private let attempts = AttemptCounter()

    public init(fontCacheLimit: Int = 400) {
        fonts = LRUCache(limit: fontCacheLimit)
        failed = LRUCache(limit: 4096)
    }

    /// How many times a font file was actually loaded (cache misses). For tests.
    var fontLoadAttempts: Int { attempts.value }

    /// Lets previously failed faces be loaded again, e.g. after a rescan replaced their files.
    public func forgetFailures() {
        failed.removeAll()
    }

    /// Drops the cached fonts (and load failures) of files at or below `root`, so the renderer holds nothing open
    /// on a volume that is being unmounted, and moved or replaced files are loaded afresh.
    public func forgetFonts(under root: URL) {
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let matches: (FontKey) -> Bool = { key in
            let path = key.url.standardizedFileURL.path
            return path == base || path.hasPrefix(prefix)
        }
        fonts.removeAll(where: matches)
        failed.removeAll(where: matches)
    }

    /// Drops every cached font and load failure.
    public func forgetAllFonts() {
        fonts.removeAll()
        failed.removeAll()
    }

    /// Base font (size 1) for a face, created from the file's descriptors without registering it.
    private func baseFont(_ url: URL, _ faceIndex: Int) -> CTFont? {
        let key = FontKey(url: url, faceIndex: faceIndex)
        if let cached = fonts[key] { return cached }
        if failed[key] != nil { return nil }
        attempts.increment()
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              descs.indices.contains(faceIndex) else {
            failed[key] = true
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(descs[faceIndex], 1, nil)
        fonts[key] = font
        return font
    }

    private func line(font: CTFont, text: String, pointSize: CGFloat, tracking: CGFloat, color: CGColor?) -> CTLine {
        let sized = CTFontCreateCopyWithAttributes(font, pointSize, nil, nil)
        var attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): sized]
        if tracking != 0 { attrs[.init(kCTKernAttributeName as String)] = tracking }
        if let color { attrs[.init(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    public func render(fileURL: URL, faceIndex: Int, request: PreviewRequest) -> CGImage? {
        let w = Int((request.size.width * request.scale).rounded())
        let h = Int((request.size.height * request.scale).rounded())
        guard w > 0, h > 0, request.pointSize > 0, let font = baseFont(fileURL, faceIndex),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: PreviewRequest.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(request.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: request.scale, y: request.scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(request.smoothing)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let ctLine = line(font: font, text: request.text, pointSize: request.pointSize,
                          tracking: request.tracking, color: request.foreground)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let x: CGFloat
        switch request.alignment {
        case .center: x = (request.size.width - width) / 2
        case .right: x = request.size.width - width
        default: x = 0
        }
        // Center the typographic box (descent below baseline, ascent above) vertically.
        let baseline = request.size.height / 2 - (ascent - descent) / 2
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(ctLine, ctx)   // overflow is clipped by the bitmap bounds
        return ctx.makeImage()
    }

    public func inkHeight(fileURL: URL, faceIndex: Int, text: String, pointSize: CGFloat) -> CGFloat {
        guard let font = baseFont(fileURL, faceIndex) else { return 0 }
        let l = line(font: font, text: text, pointSize: pointSize, tracking: 0, color: nil)
        return CTLineGetBoundsWithOptions(l, .useGlyphPathBounds).height
    }

    // MARK: Sample text

    /// Highest priority first; names refer to `ScriptCoverage.scripts` so bit order stays defined in one place.
    private static let samplePhrases: [(script: String, text: String)] = [
        ("Cyrillic", "Съешь же ещё этих мягких булок"),
        ("Greek", "Ξεσκεπάζω τὴν ψυχοφθόρα"),
        ("Arabic", "نص تجريبي للخط العربي"),
        ("Hebrew", "שלום עולם, זו דוגמה"),
        ("Thai", "ภาษาไทย ตัวอย่างข้อความ"),
        ("Devanagari", "हिन्दी नमस्ते दुनिया"),
        ("Han", "字体预览 永字八法"),
        ("Hiragana/Katakana", "あいうえお カタカナ"),
        ("Hangul", "한글 글꼴 미리보기"),
        ("Symbols", "© ® ™ ° ± × ÷ € £ ¥ § ¶"),
    ]

    private static let sampleBits: [(bit: Int64, text: String)] = samplePhrases.compactMap { p in
        guard let i = ScriptCoverage.scripts.firstIndex(where: { $0.name == p.script }) else { return nil }
        return (Int64(1) << Int64(i), p.text)
    }

    public static func sampleText(for scriptsBitmask: Int64, fallback: String) -> String {
        if scriptsBitmask & 1 != 0 { return fallback }   // Latin bit is index 0
        for entry in sampleBits where scriptsBitmask & entry.bit != 0 { return entry.text }
        return fallback
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
