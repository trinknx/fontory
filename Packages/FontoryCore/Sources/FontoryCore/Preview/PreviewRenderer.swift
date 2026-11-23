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
        sized = LRUCache(limit: max(64, fontCacheLimit * 2))
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
        sized.removeAll(where: { matches($0.face) })
    }

    /// Drops every cached font and load failure.
    public func forgetAllFonts() {
        fonts.removeAll()
        sized.removeAll()
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

    // MARK: Fonts at size

    /// A face at one point size with one set of feature settings.
    private struct SizedKey: Hashable, Sendable {
        let face: FontKey
        let pointSize: CGFloat
        /// `PreviewFeatures.rawValue`, plus `allCapsBit` when small caps apply to capitals too.
        let features: Int
    }

    private static let allCapsBit = 1 << 30

    /// Sized (and featured) copies of the base fonts, so scrolling does not rebuild them for every cell.
    private let sized: LRUCache<SizedKey, CTFont>
    private let sizedCreations = AttemptCounter()

    /// How many sized font copies were created (cache misses). For tests.
    var sizedFontCreations: Int { sizedCreations.value }

    private func sizedFont(_ url: URL, _ faceIndex: Int, pointSize: CGFloat, features: PreviewFeatures, allCaps: Bool) -> CTFont? {
        let capsBit = features.contains(.smallCaps) && allCaps ? Self.allCapsBit : 0
        let key = SizedKey(face: FontKey(url: url, faceIndex: faceIndex), pointSize: pointSize,
                           features: features.rawValue | capsBit)
        if let cached = sized[key] { return cached }
        guard let base = baseFont(url, faceIndex) else { return nil }
        sizedCreations.increment()
        let settings = Self.featureSettings(features, allCaps: capsBit != 0)
        let attributes = settings.isEmpty ? nil
            : CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, pointSize, nil, attributes)
        sized[key] = font
        return font
    }

    /// `kCTFontFeatureSettingsAttribute` entries for the non-default features (empty for `.standard`).
    static func featureSettings(_ features: PreviewFeatures, allCaps: Bool) -> [[String: Any]] {
        func tag(_ name: String, _ on: Bool) -> [String: Any] {
            [kCTFontOpenTypeFeatureTag as String: name, kCTFontOpenTypeFeatureValue as String: on ? 1 : 0]
        }
        var out: [[String: Any]] = []
        if !features.contains(.ligatures) { out += [tag("liga", false), tag("clig", false)] }
        if features.contains(.discretionaryLigatures) { out.append(tag("dlig", true)) }
        if features.contains(.alternates) { out += [tag("salt", true), tag("swsh", true)] }
        if features.contains(.smallCaps) {
            out.append(tag("smcp", true))
            if allCaps { out.append(tag("c2sc", true)) }
        }
        return out
    }

    /// Text with letters and no lowercase letters: small caps then also apply `c2sc`.
    static func isAllCaps(_ text: String) -> Bool {
        text.contains(where: \.isLetter) && !text.contains(where: \.isLowercase)
    }

    // MARK: Lines

    private static let placeholder = "\u{25CC}"   // ◌ DOTTED CIRCLE

    /// Characters that never need a glyph of their own (joiners, variation selectors, controls).
    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || (0x200B...0x200F).contains(v) || (0xFE00...0xFE0F).contains(v)
            || (0xE0100...0xE01EF).contains(v) || v == 0x2060 || v == 0xFEFF
    }

    private static func covers(_ font: CTFont, _ character: Character) -> Bool {
        for scalar in character.unicodeScalars where !isIgnorable(scalar) {
            let units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if !CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) { return false }
        }
        return true
    }

    private func attributes(font: CTFont, request: PreviewRequest, color: CGColor?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
        if request.tracking != 0 { attrs[.init(kCTKernAttributeName as String)] = request.tracking }
        if let color { attrs[.init(kCTForegroundColorAttributeName as String)] = color }
        if request.outline {
            // Positive width strokes without filling; percent of the point size, thicker at small sizes.
            attrs[.init(kCTStrokeWidthAttributeName as String)] = max(2.5, 50 / request.pointSize)
            if let color { attrs[.init(kCTStrokeColorAttributeName as String)] = color }
        }
        if request.underline {
            attrs[.init(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
        }
        return attrs
    }

    /// The styled text for a request. With `showMissingGlyphs`, characters the face lacks are replaced by ◌ in the
    /// system font at reduced opacity, so CoreText has nothing left to substitute from a fallback font.
    private func attributedText(font: CTFont, request: PreviewRequest, color: CGColor?) -> NSAttributedString {
        let attrs = attributes(font: font, request: request, color: color)
        guard request.showMissingGlyphs else { return NSAttributedString(string: request.text, attributes: attrs) }
        var placeholderAttrs = attrs
        placeholderAttrs[.init(kCTFontAttributeName as String)] =
            CTFontCreateUIFontForLanguage(.system, request.pointSize, nil) ?? font
        if let color {
            placeholderAttrs[.init(kCTForegroundColorAttributeName as String)] = color.copy(alpha: color.alpha * 0.4) ?? color
            if request.outline { placeholderAttrs[.init(kCTStrokeColorAttributeName as String)] = color.copy(alpha: color.alpha * 0.4) ?? color }
        }
        let out = NSMutableAttributedString()
        var covered = ""
        for character in request.text {
            if character.isWhitespace || Self.covers(font, character) {
                covered.append(character)
            } else {
                if !covered.isEmpty { out.append(NSAttributedString(string: covered, attributes: attrs)); covered = "" }
                out.append(NSAttributedString(string: Self.placeholder, attributes: placeholderAttrs))
            }
        }
        if !covered.isEmpty { out.append(NSAttributedString(string: covered, attributes: attrs)) }
        return out
    }

    private func sizedFont(for request: PreviewRequest, _ url: URL, _ faceIndex: Int) -> CTFont? {
        sizedFont(url, faceIndex, pointSize: request.pointSize, features: request.features,
                  allCaps: request.features.contains(.smallCaps) && Self.isAllCaps(request.text))
    }

    /// The styled text of a request, as drawn. For tests.
    func attributedText(fileURL: URL, faceIndex: Int, request: PreviewRequest) -> NSAttributedString? {
        guard let font = sizedFont(for: request, fileURL, faceIndex) else { return nil }
        return attributedText(font: font, request: request, color: request.foreground)
    }

    /// The laid-out line of a request, as drawn. For tests.
    func line(fileURL: URL, faceIndex: Int, request: PreviewRequest) -> CTLine? {
        attributedText(fileURL: fileURL, faceIndex: faceIndex, request: request).map(CTLineCreateWithAttributedString)
    }

    // MARK: Rendering

    public func render(fileURL: URL, faceIndex: Int, request: PreviewRequest) -> CGImage? {
        let w = Int((request.size.width * request.scale).rounded())
        let h = Int((request.size.height * request.scale).rounded())
        guard w > 0, h > 0, request.pointSize > 0, let font = sizedFont(for: request, fileURL, faceIndex),
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

        let ctLine = CTLineCreateWithAttributedString(attributedText(font: font, request: request, color: request.foreground))
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
        if request.showGuides { drawGuides(ctx, font: font, baseline: baseline, request: request) }
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(ctLine, ctx)   // overflow is clipped by the bitmap bounds
        return ctx.makeImage()
    }

    /// Guide color for the baseline (a warm accent); the other guides use the text color, faint.
    private static let baselineGuide = CGColor(srgbRed: 0.93, green: 0.42, blue: 0.16, alpha: 0.85)

    /// Dashed full-width lines at the face's baseline, x-height, cap-height, ascender and descender.
    private func drawGuides(_ ctx: CGContext, font: CTFont, baseline: CGFloat, request: PreviewRequest) {
        let neutral = request.foreground.copy(alpha: 0.28) ?? request.foreground
        let lineWidth = 1 / request.scale
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        func stroke(_ y: CGFloat, _ color: CGColor) {
            // Snap to the pixel grid so the hairline stays crisp.
            let snapped = ((y * request.scale).rounded() + 0.5) / request.scale
            ctx.setStrokeColor(color)
            ctx.strokeLineSegments(between: [CGPoint(x: 0, y: snapped), CGPoint(x: request.size.width, y: snapped)])
        }
        for offset in [CTFontGetAscent(font), CTFontGetCapHeight(font), CTFontGetXHeight(font), -CTFontGetDescent(font)]
            where offset != 0 {
            stroke(baseline + offset, neutral)
        }
        stroke(baseline, Self.baselineGuide)
        ctx.restoreGState()
    }

    public func inkHeight(fileURL: URL, faceIndex: Int, text: String, pointSize: CGFloat) -> CGFloat {
        guard let font = baseFont(fileURL, faceIndex) else { return 0 }
        let sized = CTFontCreateCopyWithAttributes(font, pointSize, nil, nil)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): sized]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
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
