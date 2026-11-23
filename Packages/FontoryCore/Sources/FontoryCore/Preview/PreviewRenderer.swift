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
        guard let font = FontFile.font(at: url, faceIndex: faceIndex) else {
            failed[key] = true
            return nil
        }
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
        /// `PreviewRequest.featureSettings`.
        let settings: [FontFeatureSetting]
        /// `PreviewRequest.variations`.
        let variations: [UInt32: Double]
    }

    private static let allCapsBit = 1 << 30

    /// Sized (and featured) copies of the base fonts, so scrolling does not rebuild them for every cell.
    private let sized: LRUCache<SizedKey, CTFont>
    private let sizedCreations = AttemptCounter()

    /// How many sized font copies were created (cache misses). For tests.
    var sizedFontCreations: Int { sizedCreations.value }

    private func sizedFont(_ url: URL, _ faceIndex: Int, pointSize: CGFloat, features: PreviewFeatures, allCaps: Bool,
                           extra: [FontFeatureSetting] = [], variations: [UInt32: Double] = [:]) -> CTFont? {
        let capsBit = features.contains(.smallCaps) && allCaps ? Self.allCapsBit : 0
        let key = SizedKey(face: FontKey(url: url, faceIndex: faceIndex), pointSize: pointSize,
                           features: features.rawValue | capsBit, settings: extra, variations: variations)
        if let cached = sized[key] { return cached }
        guard let base = baseFont(url, faceIndex) else { return nil }
        sizedCreations.increment()
        let settings = Self.featureSettings(features, allCaps: capsBit != 0, extra: extra)
        var attributeValues: [CFString: Any] = [:]
        if !settings.isEmpty { attributeValues[kCTFontFeatureSettingsAttribute] = settings }
        if !variations.isEmpty {
            attributeValues[kCTFontVariationAttribute] = Dictionary(uniqueKeysWithValues: variations.map {
                (NSNumber(value: $0.key), NSNumber(value: $0.value))
            })
        }
        let attributes = attributeValues.isEmpty ? nil
            : CTFontDescriptorCreateWithAttributes(attributeValues as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, pointSize, nil, attributes)
        sized[key] = font
        return font
    }

    /// `kCTFontFeatureSettingsAttribute` entries for the non-default features (empty for `.standard` without
    /// `extra`); a tag in `extra` replaces the same tag from `features`.
    static func featureSettings(_ features: PreviewFeatures, allCaps: Bool, extra: [FontFeatureSetting]) -> [[String: Any]] {
        let base = featureSettings(features, allCaps: allCaps)
        guard !extra.isEmpty else { return base }
        let overridden = Set(extra.compactMap(\.openTypeTag))
        return base.filter { !overridden.contains($0[kCTFontOpenTypeFeatureTag as String] as? String ?? "") }
            + extra.map(\.attribute)
    }

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

    /// Characters that never need a glyph of their own: C0/C1 controls and DEL, zero-width and directional
    /// formatting characters (embeddings, overrides, isolates U+2066–2069, the Arabic letter mark U+061C), joiners,
    /// variation selectors.
    static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || (0x7F...0x9F).contains(v) || (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
            || (0x2060...0x2069).contains(v) || v == 0x061C || (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v)
            || v == 0xFEFF
    }

    /// For each Character of `text`, whether the face covers it. One glyph lookup over the whole UTF-16 buffer;
    /// a surrogate pair's glyph lands in its first slot. ASCII space and tab always count as covered; other spaces
    /// (NBSP, U+3000) are checked like any character.
    static func coverage(of text: String, in font: CTFont) -> [Bool] {
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if !units.isEmpty { _ = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) }
        var out: [Bool] = []
        out.reserveCapacity(text.count)
        var offset = 0
        for character in text {
            var covered = true
            for scalar in character.unicodeScalars {
                defer { offset += scalar.utf16.count }
                if scalar == " " || scalar == "\t" || isIgnorable(scalar) { continue }
                if glyphs[offset] == 0 { covered = false }
            }
            out.append(covered)
        }
        return out
    }

    /// The system font that draws ◌, per point size; created only when a character is missing.
    private let placeholderFonts = LRUCache<CGFloat, CTFont>(limit: 32)
    private let placeholderCreations = AttemptCounter()

    /// How many placeholder fonts were created. For tests.
    var placeholderFontCreations: Int { placeholderCreations.value }

    private func placeholderFont(size: CGFloat) -> CTFont? {
        if let cached = placeholderFonts[size] { return cached }
        guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return nil }
        placeholderCreations.increment()
        placeholderFonts[size] = font
        return font
    }

    private func attributes(font: CTFont, request: PreviewRequest, color: CGColor?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
        if request.tracking != 0 {
            attrs[.init(kCTKernAttributeName as String)] = request.tracking
        } else if request.disablesKerning {
            attrs[.init(kCTKernAttributeName as String)] = 0
        }
        if let language = request.language { attrs[.init(kCTLanguageAttributeName as String)] = language }
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
        let coverage = Self.coverage(of: request.text, in: font)
        guard coverage.contains(false) else { return NSAttributedString(string: request.text, attributes: attrs) }
        var placeholderAttrs = attrs
        placeholderAttrs[.init(kCTFontAttributeName as String)] = placeholderFont(size: request.pointSize) ?? font
        if let color {
            let faint = color.copy(alpha: color.alpha * 0.4) ?? color
            placeholderAttrs[.init(kCTForegroundColorAttributeName as String)] = faint
            if request.outline { placeholderAttrs[.init(kCTStrokeColorAttributeName as String)] = faint }
        }
        let out = NSMutableAttributedString()
        var covered = ""
        for (character, isCovered) in zip(request.text, coverage) {
            if isCovered {
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
                  allCaps: request.features.contains(.smallCaps) && Self.isAllCaps(request.text),
                  extra: request.featureSettings, variations: request.variations)
    }

    /// The face at `pointSize` with the default features, from the shared font cache (nil when it cannot be loaded).
    /// The glyph cells of the Characters tab draw with it.
    public func font(fileURL: URL, faceIndex: Int, pointSize: CGFloat) -> CTFont? {
        sizedFont(fileURL, faceIndex, pointSize: pointSize, features: .standard, allCaps: false)
    }

    /// The face at `pointSize` with `features` applied (small caps without `c2sc`), from the shared font cache. The
    /// Text tab's body text sets with it.
    public func font(fileURL: URL, faceIndex: Int, pointSize: CGFloat, features: PreviewFeatures) -> CTFont? {
        sizedFont(fileURL, faceIndex, pointSize: pointSize, features: features, allCaps: false)
    }

    /// The face at `pointSize` with exactly `settings` applied (the Features tab), from the shared font cache.
    public func font(fileURL: URL, faceIndex: Int, pointSize: CGFloat, settings: [FontFeatureSetting]) -> CTFont? {
        sizedFont(fileURL, faceIndex, pointSize: pointSize, features: .standard, allCaps: false, extra: settings)
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

    /// Dashed full-width lines at the face's baseline, x-height, cap-height, ascender and descender.
    private func drawGuides(_ ctx: CGContext, font: CTFont, baseline: CGFloat, request: PreviewRequest) {
        MetricGuides.draw(ctx, font: font, baseline: baseline, width: request.size.width, foreground: request.foreground,
                          scale: request.scale)
    }

    /// Ink height of `text` at `pointSize` with the standard features and CoreText fallback.
    public func inkHeight(fileURL: URL, faceIndex: Int, text: String, pointSize: CGFloat) -> CGFloat {
        let request = PreviewRequest(text: text, pointSize: pointSize, foreground: Self.measureColor,
                                     background: Self.measureColor, size: CGSize(width: 1, height: 1), scale: 1)
        return inkHeight(fileURL: fileURL, faceIndex: faceIndex, request: request)
    }

    /// Ink height of a request's text at its point size, shaped as it is drawn: same OpenType features and the
    /// same ◌ substitution. Outline, underline, colors and size do not take part.
    public func inkHeight(fileURL: URL, faceIndex: Int, request: PreviewRequest) -> CGFloat {
        guard request.pointSize > 0, let font = sizedFont(for: request, fileURL, faceIndex) else { return 0 }
        var shape = request
        shape.outline = false
        shape.underline = false
        shape.tracking = 0
        let l = CTLineCreateWithAttributedString(attributedText(font: font, request: shape, color: nil))
        return CTLineGetBoundsWithOptions(l, .useGlyphPathBounds).height
    }

    private static let measureColor = CGColor(gray: 0, alpha: 1)

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
