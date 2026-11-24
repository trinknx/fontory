import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct LayoutRendererTests {
    private static let hoefler = URL(fileURLWithPath: TempFonts.hoeflerText)
    private static let arial = URL(fileURLWithPath: TempFonts.arialBold)

    private func reference(_ ps: String, _ family: String) -> FontReference {
        FontReference(postScriptName: ps, family: family)
    }

    private func resolved(_ ref: FontReference, _ url: URL, faceIndex: Int = 0) -> ResolvedFont {
        ResolvedFont(reference: ref, faceID: 1, url: url, faceIndex: faceIndex, isMissing: false)
    }

    private func block(_ kind: LayoutBlock.Kind = .text, text: String, font: FontReference, size: Double = 48,
                       frame: LayoutFrame = LayoutFrame(x: 20, y: 20, w: 560, h: 300), lineHeight: Double = 1.2,
                       tracking: Double = 0, sizes: [Double] = []) -> LayoutBlock {
        LayoutBlock(kind: kind, frame: frame, text: text, font: font, size: size, lineHeight: lineHeight,
                    tracking: tracking, sizes: sizes)
    }

    private func doc(_ blocks: [LayoutBlock], showMissing: Bool = true, size: LayoutSize = LayoutSize(w: 600, h: 400)) -> LayoutDocument {
        LayoutDocument(name: "Test", pageSize: size, showMissing: showMissing, blocks: blocks)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    /// Rows (top to bottom) that have any dark pixel, grouped into contiguous bands.
    private func inkBands(_ image: CGImage) -> Int {
        let data = bytes(image), w = image.width
        var bands = 0, inBand = false
        for row in 0..<image.height {
            var ink = false
            for x in 0..<w where data[(row * w + x) * 4] < 128 { ink = true; break }
            if ink && !inBand { bands += 1 }
            inBand = ink
        }
        return bands
    }

    private func covers(_ url: URL, _ text: String) -> Bool {
        guard let font = FontFile.font(at: url, faceIndex: 0, size: 12) else { return false }
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
    }

    @Test func missingCharactersBecomePlaceholders() throws {
        // Hoefler Text has no Vietnamese stacked marks: verify, so the test stays honest.
        #expect(!covers(Self.hoefler, "ế"))
        #expect(!covers(Self.hoefler, "ệ"))
        #expect(covers(Self.hoefler, "Ting Vit"))
        let ref = reference("HoeflerText-Regular", "Hoefler Text")
        let fonts = [ref: resolved(ref, Self.hoefler)]
        let b = block(text: "Tiếng Việt", font: ref)
        let on = doc([b], showMissing: true), off = doc([b], showMissing: false)
        let report = LayoutRenderer.renderImage(on, fonts: fonts, scale: 1).report
        #expect(report.missingCharacters[b.id.uuidString] == 2)
        #expect(report.missingFontBlockIDs.isEmpty)
        let a = try #require(LayoutRenderer.image(on, fonts: fonts, scale: 1))
        let c = try #require(LayoutRenderer.image(off, fonts: fonts, scale: 1))
        #expect(bytes(a) != bytes(c))
        // The placeholder string itself is what is set: ◌ replaces each missing letter.
        let text = LayoutRenderer.attributedText(b.text, font: try #require(FontFile.font(at: Self.hoefler, faceIndex: 0, size: 48)),
                                                 size: 48, color: CGColor(gray: 0, alpha: 1), showMissing: true,
                                                 paragraph: nil, kern: 0).text
        #expect(text.string == "Ti\u{25CC}ng Vi\u{25CC}t")
    }

    @Test func missingFontReported() throws {
        let gone = reference("Nope-Regular", "Nope")
        let offline = reference("Arial-BoldMT", "Arial")
        let ok = reference("HoeflerText-Regular", "Hoefler Text")
        let a = block(text: "Gone", font: gone)
        let b = block(text: "Offline", font: offline, frame: LayoutFrame(x: 20, y: 100, w: 560, h: 80))
        let c = block(text: "Here", font: ok, frame: LayoutFrame(x: 20, y: 200, w: 560, h: 80))
        let fonts = [offline: ResolvedFont(reference: offline, faceID: 3, url: nil, faceIndex: 0, isMissing: true),
                     ok: resolved(ok, Self.hoefler)]
        let (image, report) = LayoutRenderer.renderImage(doc([a, b, c]), fonts: fonts, scale: 1)
        #expect(image != nil)
        #expect(report.missingFontBlockIDs == [a.id.uuidString, b.id.uuidString])
        // Drawn in the system font, not skipped.
        let only = try #require(LayoutRenderer.image(doc([a]), fonts: [:], scale: 1))
        let empty = try #require(LayoutRenderer.image(doc([]), fonts: [:], scale: 1))
        #expect(bytes(only) != bytes(empty))
    }

    @Test func trackingAndLineHeightChangeLayout() throws {
        let ref = reference("Arial-BoldMT", "Arial")
        let fonts = [ref: resolved(ref, Self.arial)]
        let text = "Pack my box with five dozen liquor jugs and a few more words to wrap"
        let base = block(text: text, font: ref, size: 32, frame: LayoutFrame(x: 20, y: 20, w: 400, h: 360))
        var tracked = base; tracked.tracking = 200
        var spaced = base; spaced.lineHeight = 2
        let r0 = LayoutRenderer.renderImage(doc([base]), fonts: fonts, scale: 1)
        let r1 = LayoutRenderer.renderImage(doc([tracked]), fonts: fonts, scale: 1)
        let r2 = LayoutRenderer.renderImage(doc([spaced]), fonts: fonts, scale: 1)
        let id = base.id.uuidString
        // Wider tracking wraps into more lines; taller line height moves the same lines apart.
        #expect((r1.report.lineCounts[id] ?? 0) > (r0.report.lineCounts[id] ?? 0))
        #expect(r2.report.lineCounts[id] == r0.report.lineCounts[id])
        let b0 = bytes(try #require(r0.image)), b2 = bytes(try #require(r2.image))
        #expect(b0 != b2)
        #expect(b0 != bytes(try #require(r1.image)))
    }

    @Test func waterfallDrawsOneLinePerSize() throws {
        let ref = reference("Arial-BoldMT", "Arial")
        let fonts = [ref: resolved(ref, Self.arial)]
        let sizes: [Double] = [12, 24, 36, 48]
        let b = block(.waterfall, text: "Hamburgefonstiv", font: ref, size: 24,
                      frame: LayoutFrame(x: 20, y: 20, w: 560, h: 360), lineHeight: 1.6, sizes: sizes)
        let (image, report) = LayoutRenderer.renderImage(doc([b]), fonts: fonts, scale: 1)
        #expect(report.lineCounts[b.id.uuidString] == sizes.count)
        #expect(inkBands(try #require(image)) == sizes.count)
    }

    @Test func charsetDrawsAGrid() throws {
        let ref = reference("Arial-BoldMT", "Arial")
        let fonts = [ref: resolved(ref, Self.arial)]
        // 380 / (20 × 1.6) = 11.9 → 12 columns; 26 letters → 3 rows.
        let b = block(.charset, text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", font: ref, size: 20,
                      frame: LayoutFrame(x: 20, y: 20, w: 380, h: 300))
        #expect(LayoutRenderer.charsetColumns(width: 380, size: 20) == 12)
        #expect(LayoutRenderer.charsetColumns(width: 50, size: 20) == 4)
        let (image, report) = LayoutRenderer.renderImage(doc([b]), fonts: fonts, scale: 1)
        #expect(report.lineCounts[b.id.uuidString] == 3)
        #expect(inkBands(try #require(image)) == 3)
    }

    @Test func pdfHasOnePagePerDocument() throws {
        let tmp = try TempFonts()
        defer { tmp.cleanup() }
        let ref = reference("HoeflerText-Regular", "Hoefler Text")
        let fonts = [ref: resolved(ref, Self.hoefler)]
        let docs = (0..<30).map { i in doc([block(text: "Page \(i) Tiếng Việt", font: ref)]) }
        let url = tmp.root.appendingPathComponent("out.pdf")
        try LayoutRenderer.pdf(docs, fonts: fonts, to: url)
        let pdf = try #require(CGPDFDocument(url as CFURL))
        #expect(pdf.numberOfPages == 30)
        let box = try #require(pdf.page(at: 1)).getBoxRect(.mediaBox)
        #expect(box.size == CGSize(width: 600, height: 400))
    }

    @Test func documentsForEachCandidateUseClosestStyle() {
        let blockFont = reference("Old-Bold", "Old")
        let a = reference("A-Regular", "A"), b = reference("B-Regular", "B")
        func style(_ r: FontReference, _ w: Double, italic: Bool = false) -> PairingStyle {
            PairingStyle(reference: r, name: r.postScriptName, weight: w, width: 5, isItalic: italic)
        }
        let aBold = reference("A-Bold", "A"), bBlack = reference("B-Black", "B")
        let table: [String: [PairingStyle]] = [
            "Old": [style(reference("Old-Regular", "Old"), 400), style(blockFont, 700)],
            "A": [style(a, 400), style(aBold, 700), style(reference("A-BoldItalic", "A"), 700, italic: true)],
            "B": [style(b, 400), style(bBlack, 900)],
        ]
        var d = doc([block(text: "x", font: blockFont)])
        d.candidates = [a, b, reference("A-Light", "a")]
        let out = LayoutRenderer.documentsForEachCandidate(d) { table[$0.family] ?? [] }
        #expect(out.count == 2)
        #expect(out.map { $0.blocks[0].font } == [aBold, bBlack])
    }

    @Test func cyclingRenderIsFast() throws {
        let ref = reference("Arial-BoldMT", "Arial")
        let fonts = [ref: resolved(ref, Self.arial)]
        let poster = LayoutDocument(name: "Poster", pageSize: LayoutSize(w: 1080, h: 1350), blocks: [
            block(text: "Bold ideas, set in type", font: ref, size: 120, frame: LayoutFrame(x: 80, y: 80, w: 920, h: 460)),
            block(text: "A subhead that sits under the headline", font: ref, size: 48,
                  frame: LayoutFrame(x: 80, y: 560, w: 920, h: 140)),
            block(text: String(repeating: "A short paragraph of body copy for the poster. ", count: 6), font: ref,
                  size: 28, frame: LayoutFrame(x: 80, y: 720, w: 920, h: 420), lineHeight: 1.4),
            block(text: "Caption · Tiếng Việt", font: ref, size: 18, frame: LayoutFrame(x: 80, y: 1220, w: 920, h: 40)),
        ])
        _ = LayoutRenderer.image(poster, fonts: fonts, scale: 1)   // warm the font cache
        let start = Date()
        for _ in 0..<10 { _ = LayoutRenderer.image(poster, fonts: fonts, scale: 1) }
        let average = Date().timeIntervalSince(start) / 10
        #expect(average < 0.1, "average \(average)s")
    }

    @Test func rendersOffTheMainThread() async throws {
        let ref = reference("Arial-BoldMT", "Arial")
        let fonts = [ref: resolved(ref, Self.arial)]
        let d = doc([block(text: "Hi", font: ref)])
        let images = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { LayoutRenderer.image(d, fonts: fonts, scale: 1) != nil } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(images == Array(repeating: true, count: 8))
    }
}
