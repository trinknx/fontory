import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

/// Render options of the preview popover: OpenType features, guides, missing-glyph placeholders, outline, underline.
@Suite struct PreviewOptionsTests {
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let baskerville = "/System/Library/Fonts/Supplemental/Baskerville.ttc"
    static let arial = "/System/Library/Fonts/Supplemental/Arial.ttf"

    func request(_ text: String, pointSize: CGFloat = 48) -> PreviewRequest {
        PreviewRequest(text: text, pointSize: pointSize, foreground: Self.black, background: Self.white,
                       size: CGSize(width: 600, height: 120), scale: 2)
    }

    /// RGBA pixels of an image.
    func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// Non-white pixels inside `rect` (pixel coordinates, origin top-left as stored in memory).
    func ink(_ image: CGImage, in rect: CGRect? = nil) -> Int {
        let px = pixels(image)
        let r = rect ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var n = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let i = (y * image.width + x) * 4
                if px[i] < 250 || px[i + 1] < 250 || px[i + 2] < 250 { n += 1 }
            }
        }
        return n
    }

    func render(_ path: String, _ r: PreviewRequest, renderer: PreviewRenderer = PreviewRenderer()) throws -> CGImage {
        try #require(renderer.render(fileURL: URL(fileURLWithPath: path), faceIndex: 0, request: r))
    }

    @Test func defaultsKeepStandardRendering() {
        let r = request("Abc")
        #expect(r.features == .standard)
        #expect(!r.showGuides && !r.showMissingGlyphs && !r.outline && !r.underline)
    }

    @Test func optionsTakePartInEqualityAndHash() {
        let a = request("x")
        var b = a; b.showGuides = true; #expect(a != b)
        b = a; b.showMissingGlyphs = true; #expect(a != b)
        b = a; b.outline = true; #expect(a != b)
        b = a; b.underline = true; #expect(a != b)
        b = a; b.features.remove(.ligatures); #expect(a != b)
        b = a; b.features.insert(.smallCaps); #expect(a != b)
        var c = a; c.features.insert(.alternates); c.features.remove(.alternates)
        #expect(a == c && a.hashValue == c.hashValue)
    }

    @Test func ligaturesOffSplitsFi() throws {
        let renderer = PreviewRenderer()
        let url = URL(fileURLWithPath: Self.baskerville)
        var r = request("fi ffl")
        let on = try #require(renderer.line(fileURL: url, faceIndex: 0, request: r))
        r.features.remove(.ligatures)
        let off = try #require(renderer.line(fileURL: url, faceIndex: 0, request: r))
        #expect(CTLineGetGlyphCount(on) < CTLineGetGlyphCount(off))
        #expect(CTLineGetGlyphCount(off) == 6)
    }

    func glyphs(_ line: CTLine) -> [CGGlyph] {
        (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [CGGlyph] in
            var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(), &g)
            return g
        }
    }

    @Test func smallCapsChangeGlyphsAndCoverCapitals() throws {
        let renderer = PreviewRenderer()
        let url = URL(fileURLWithPath: Self.baskerville)   // face 0 has smcp and c2sc
        var r = request("Small caps")
        let plain = glyphs(try #require(renderer.line(fileURL: url, faceIndex: 0, request: r)))
        r.features.insert(.smallCaps)
        let caps = glyphs(try #require(renderer.line(fileURL: url, faceIndex: 0, request: r)))
        #expect(plain.first == caps.first)   // the capital S stays
        #expect(plain != caps)
        #expect(pixels(try render(Self.baskerville, r, renderer: renderer))
                != pixels(try render(Self.baskerville, { var p = r; p.features = .standard; return p }(), renderer: renderer)))
    }

    @Test func featureSettingsList() {
        func tags(_ f: PreviewFeatures, caps: Bool = false) -> [String] {
            PreviewRenderer.featureSettings(f, allCaps: caps).map { "\($0[kCTFontOpenTypeFeatureTag as String]!)=\($0[kCTFontOpenTypeFeatureValue as String]!)" }
        }
        #expect(tags(.standard).isEmpty)
        #expect(tags([]) == ["liga=0", "clig=0"])
        #expect(tags([.ligatures, .discretionaryLigatures]) == ["dlig=1"])
        #expect(tags([.ligatures, .alternates]) == ["salt=1", "swsh=1"])
        #expect(tags([.ligatures, .smallCaps]) == ["smcp=1"])
        // No system font here has c2sc, so the all-capitals case is checked on the settings themselves.
        #expect(tags([.ligatures, .smallCaps], caps: true) == ["smcp=1", "c2sc=1"])
    }

    @Test func featureFontsAreCached() throws {
        let renderer = PreviewRenderer()
        var r = request("fi"); r.features = [.ligatures, .discretionaryLigatures]
        _ = try render(Self.baskerville, r, renderer: renderer)
        let before = renderer.sizedFontCreations
        _ = try render(Self.baskerville, r, renderer: renderer)
        #expect(renderer.sizedFontCreations == before)
        r.features = .standard
        _ = try render(Self.baskerville, r, renderer: renderer)
        #expect(renderer.sizedFontCreations == before + 1)
    }

    @Test func missingGlyphsBecomePlaceholdersWithoutFallback() throws {
        let renderer = PreviewRenderer()
        let url = URL(fileURLWithPath: Self.arial)
        var r = request("A中B")
        r.showMissingGlyphs = true
        let text = try #require(renderer.attributedText(fileURL: url, faceIndex: 0, request: r))
        #expect(!text.string.contains("中"))
        #expect(text.string == "A\u{25CC}B")
        // The covered characters keep the face's font; nothing is left for CoreText fallback to pick.
        let line = try #require(renderer.line(fileURL: url, faceIndex: 0, request: r))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let names = runs.map { run -> String in
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName as String] as! CTFont
            return CTFontCopyPostScriptName(font) as String
        }
        #expect(names.first == "ArialMT" && names.last == "ArialMT")
        #expect(!names.contains { $0.contains("PingFang") || $0.contains("Hiragino") || $0.contains("STHeiti") })

        // Off: CoreText falls back as before, and the image differs.
        r.showMissingGlyphs = false
        let plain = try #require(renderer.attributedText(fileURL: url, faceIndex: 0, request: r))
        #expect(plain.string == "A中B")
        var on = r; on.showMissingGlyphs = true
        #expect(pixels(try render(Self.arial, r, renderer: renderer)) != pixels(try render(Self.arial, on, renderer: renderer)))
    }

    @Test func coveredTextIsUnchangedByMissingGlyphMode() throws {
        let renderer = PreviewRenderer()
        var r = request("Chữ Việt có dấu")
        r.showMissingGlyphs = true
        let text = try #require(renderer.attributedText(fileURL: URL(fileURLWithPath: Self.arial), faceIndex: 0, request: r))
        #expect(text.string == "Chữ Việt có dấu")
    }

    func missingText(_ text: String, renderer: PreviewRenderer = PreviewRenderer()) throws -> String {
        var r = request(text)
        r.showMissingGlyphs = true
        return try #require(renderer.attributedText(fileURL: URL(fileURLWithPath: Self.arial), faceIndex: 0, request: r)).string
    }

    @Test func missingGlyphCoverageEdgeCases() throws {
        #expect(try missingText("A\u{3000}B") == "A\u{25CC}B")          // ideographic space: Arial lacks it
        #expect(try missingText("A\u{00A0}B") == "A\u{00A0}B")          // NBSP: Arial has it
        #expect(try missingText("A B\tC") == "A B\tC")                  // ASCII space and tab always pass
        #expect(try missingText("A\u{0085}B") == "A\u{0085}B")          // C1 control: ignored
        #expect(try missingText("A\u{1F600}B") == "A\u{25CC}B")         // astral (surrogate pair): one placeholder
        #expect(try missingText("e\u{0301}x") == "e\u{0301}x")          // combining mark Arial has
        #expect(try missingText("中文") == "\u{25CC}\u{25CC}")
    }

    @Test func placeholderFontIsCreatedOnlyWhenNeededAndCached() throws {
        let renderer = PreviewRenderer()
        var r = request("Covered text")
        r.showMissingGlyphs = true
        _ = try render(Self.arial, r, renderer: renderer)
        #expect(renderer.placeholderFontCreations == 0)
        r.text = "A中"
        _ = try render(Self.arial, r, renderer: renderer)
        _ = try render(Self.arial, r, renderer: renderer)
        #expect(renderer.placeholderFontCreations == 1)
    }

    @Test func inkHeightHonoursFeaturesAndPlaceholders() throws {
        let renderer = PreviewRenderer()
        let baskerville = URL(fileURLWithPath: Self.baskerville)
        var r = request("ace", pointSize: 100)
        let plain = renderer.inkHeight(fileURL: baskerville, faceIndex: 0, request: r)
        r.features.insert(.smallCaps)
        let caps = renderer.inkHeight(fileURL: baskerville, faceIndex: 0, request: r)
        #expect(plain > 0 && caps > plain + 1, "plain \(plain) caps \(caps)")   // small caps rise above the x-height

        let arial = URL(fileURLWithPath: Self.arial)
        var cjk = request("中", pointSize: 100)
        let fallback = renderer.inkHeight(fileURL: arial, faceIndex: 0, request: cjk)
        cjk.showMissingGlyphs = true
        let placeholder = renderer.inkHeight(fileURL: arial, faceIndex: 0, request: cjk)
        #expect(fallback > 0 && placeholder > 0 && abs(fallback - placeholder) > 1)
        // The text-only overload is the standard case.
        #expect(renderer.inkHeight(fileURL: arial, faceIndex: 0, text: "Hxg", pointSize: 100)
                == renderer.inkHeight(fileURL: arial, faceIndex: 0, request: request("Hxg", pointSize: 100)))
    }

    @Test func guidesDrawInEmptyRegions() throws {
        var r = request("x")
        let plain = try render(Self.arial, r)
        r.showGuides = true
        let guided = try render(Self.arial, r)
        // The right half holds no text: only the guides can put ink there.
        let right = CGRect(x: 800, y: 0, width: 400, height: 240)
        #expect(ink(plain, in: right) == 0)
        #expect(ink(guided, in: right) > 0)
    }

    @Test func outlineStrokesInsteadOfFilling() throws {
        var r = request("HHHH", pointSize: 80)
        let filled = try render(Self.arial, r)
        r.outline = true
        let outlined = try render(Self.arial, r)
        #expect(ink(outlined) > 0)
        #expect(ink(outlined) < ink(filled))
    }

    @Test func underlineAddsInk() throws {
        var r = request("HHHH")
        let plain = try render(Self.arial, r)
        r.underline = true
        let underlined = try render(Self.arial, r)
        #expect(ink(underlined) > ink(plain))
    }

    @Test func allCapsDetection() {
        #expect(PreviewRenderer.isAllCaps("HELLO WORLD"))
        #expect(!PreviewRenderer.isAllCaps("Hello"))
        #expect(!PreviewRenderer.isAllCaps("123"))
    }
}

@Suite struct PreviewSamplesTests {
    @Test func languagesAreCompleteAndDistinct() {
        let names = PreviewSamples.languages.map(\.name)
        #expect(names.count == 24)
        #expect(Set(names).count == names.count)
        #expect(Set(PreviewSamples.languages.map(\.text)).count == names.count)
        #expect(names == names.sorted())
        for name in ["Vietnamese", "Korean", "Arabic", "Hebrew", "Thai", "Japanese",
                     "Chinese (Simplified)", "Chinese (Traditional)"] {
            #expect(names.contains(name))
        }
        #expect(PreviewSamples.language("Vietnamese")?.text == "Thủy thủ ngồi xếp bằng, khẽ vuốt râu và cười.")
    }

    @Test func languageSamplesUseTheirScript() {
        func has(_ lang: String, _ range: ClosedRange<UInt32>) -> Bool {
            PreviewSamples.language(lang)?.text.unicodeScalars.contains { range.contains($0.value) } ?? false
        }
        #expect(has("Arabic", 0x0600...0x06FF))
        #expect(has("Hebrew", 0x05D0...0x05EA))
        #expect(has("Thai", 0x0E00...0x0E7F))
        #expect(has("Korean", 0xAC00...0xD7A3))
        #expect(has("Japanese", 0x3040...0x30FF))
        #expect(has("Greek", 0x0370...0x03FF))
        #expect(has("Russian", 0x0400...0x04FF))
        #expect(has("Chinese (Simplified)", 0x4E00...0x9FFF))
    }

    @Test func fixedSamples() {
        #expect(PreviewSamples.lowercase.text.filter(\.isLetter).count == 26)
        #expect(PreviewSamples.uppercase.text == PreviewSamples.lowercase.text.uppercased())
        #expect(PreviewSamples.hamburgefonstiv.text == "Hamburgefonstiv")
        #expect(PreviewSamples.accented.text.contains("ư"))
        for c in ["Ă", "Â", "Đ", "Ê", "Ô", "Ơ", "Ư", "Ấ", "Ầ", "Ẩ", "Ẫ", "Ậ", "Ế", "Ổ", "Ữ", "Ự", "ý", "Ÿ"] {
            #expect(PreviewSamples.accented.text.contains(c), "missing \(c)")
        }
        // Vietnamese: every accented lowercase letter has its capital, and the reverse.
        for c in ["ĩ", "ũ", "Ẳ", "Ẵ", "Ặ", "Ờ", "Ở", "Ỡ", "Ĩ", "Ũ", "Ạ", "Ả", "Ẹ", "Ẻ", "Ẽ", "Ỉ", "Ọ", "Ỏ", "Ụ", "Ủ", "Ỳ", "Ỵ", "Ỷ", "Ỹ"] {
            #expect(PreviewSamples.accented.text.contains(c), "missing \(c)")
        }
        let vietnamese = PreviewSamples.accented.text.split(separator: " ").filter { $0.count == 1 }.map(String.init)
            .filter { $0.unicodeScalars.contains { (0x1EA0...0x1EF9).contains($0.value) || [0x128, 0x129, 0x168, 0x169].contains($0.value) } }
        for c in vietnamese {
            #expect(PreviewSamples.accented.text.contains(c.uppercased()), "no capital for \(c)")
            #expect(PreviewSamples.accented.text.contains(c.lowercased()), "no lowercase for \(c)")
        }
        #expect(PreviewSamples.numbers.text.contains("0123456789"))
        #expect(PreviewSamples.currencies.text.contains("₫"))
    }

    @Test func dynamicTextFollowsScriptsAndStyle() {
        let latin: Int64 = 1
        let cyrillic = Int64(1) << 3
        #expect(PreviewSamples.dynamicText(scriptsBitmask: latin, style: .automatic) == PreviewSamples.DynamicStyle.automatic.latinText)
        #expect(PreviewSamples.dynamicText(scriptsBitmask: latin, style: .automatic) == "The quick brown fox jumps over the lazy dog")
        #expect(PreviewSamples.dynamicText(scriptsBitmask: latin, style: .short) == "AaBbGg")
        // Settings saved before the default changed ("pangram") still decode.
        #expect(PreviewSamples.DynamicStyle(rawValue: "pangram") == .short)
        let cyr = PreviewSamples.dynamicText(scriptsBitmask: cyrillic, style: .short)
        #expect(cyr.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
        #expect(PreviewSamples.dynamicText(scriptsBitmask: 0, style: .automatic) == PreviewSamples.DynamicStyle.automatic.latinText)
    }
}
