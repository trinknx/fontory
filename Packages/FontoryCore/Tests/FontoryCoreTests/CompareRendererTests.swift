import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct CompareRendererTests {
    private static let canvas = CGSize(width: 1000, height: 400)
    private static let applePath = "/System/Library/Fonts/Apple Symbols.ttf"

    private func resolved(_ ps: String, _ family: String, _ path: String) -> ResolvedFont {
        ResolvedFont(reference: FontReference(postScriptName: ps, family: family), faceID: 1,
                     url: URL(fileURLWithPath: path), faceIndex: 0, isMissing: false)
    }

    private var hoefler: ResolvedFont { resolved("HoeflerText-Regular", "Hoefler Text", TempFonts.hoeflerText) }
    private var arial: ResolvedFont { resolved("Arial-BoldMT", "Arial", TempFonts.arialBold) }

    private func scene(_ text: String, rule: CompareSizeRule = .sameSize, mode: CompareMode = .overlay,
                       b: ResolvedFont? = nil, useB: Bool = true) -> CompareScene {
        let options = CompareOptions(mode: mode, sizeRule: rule, outlines: false, guides: true)
        return CompareRenderer.scene(a: hoefler, aLabel: "Hoefler", b: useB ? (b ?? arial) : nil, bLabel: "Arial",
                                     text: text, options: options, canvas: Self.canvas)
    }

    private func draw(_ s: CompareScene, outlines: Bool = false) -> CGImage? {
        let options = CompareOptions(mode: .overlay, sizeRule: .sameSize, outlines: outlines, guides: true)
        return CompareRenderer.image(s, options: options,
                                     colorA: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                     colorB: CGColor(red: 0, green: 0, blue: 1, alpha: 1),
                                     guideColor: CGColor(gray: 0.5, alpha: 1), background: CGColor(gray: 1, alpha: 1), scale: 1)
    }

    @Test func sameSizeKeepsScaleOne() {
        #expect(scene("Hamburgefonstiv").scaleB == 1)
    }

    @Test func matchXHeightEqualisesXHeights() {
        let s = scene("Hamburgefonstiv", rule: .matchXHeight)
        let a = s.a.metrics!.xHeight * Double(s.pointSize)
        let b = s.b.metrics!.xHeight * Double(s.pointSize) * s.scaleB
        #expect(abs(a - b) < 0.5)
        #expect(s.scaleB != 1)
    }

    @Test func matchCapHeightEqualisesCapHeights() {
        let s = scene("Hamburgefonstiv", rule: .matchCapHeight)
        let a = s.a.metrics!.capHeight * Double(s.pointSize)
        let b = s.b.metrics!.capHeight * Double(s.pointSize) * s.scaleB
        #expect(abs(a - b) < 0.5)
    }

    @Test func fitsWidestLine() {
        let s = scene("Hamburgefonstiv")
        #expect(s.pointSize > 0)
        #expect(max(s.a.metrics!.lineWidth, s.b.metrics!.lineWidth) <= 1000 * 0.9 + 0.5)
    }

    @Test func capHeightCappedAt60Percent() {
        let s = scene("ii")
        #expect(!s.isGlyphMode)
        #expect(s.a.metrics!.capHeight * Double(s.pointSize) <= 400 * 0.6 + 0.5)
    }

    @Test func sideBySideHasTwoBaselines() {
        let s = scene("Hamburgefonstiv", mode: .sideBySide)
        #expect(s.baselines.count == 2)
        #expect(s.baselines[0] > s.baselines[1])
        #expect(scene("Hamburgefonstiv").baselines.count == 1)
    }

    @Test func glyphModeCentresBothGlyphs() {
        let s = scene("o")
        #expect(s.isGlyphMode)
        for side in [s.a, s.b] {
            #expect(side.metrics!.advance != nil && side.metrics!.leftBearing != nil && side.metrics!.rightBearing != nil)
            #expect(abs(side.path!.boundingBox.midX - 500) < 1000 * 0.03)
        }
    }

    @Test func missingCharactersCountedAndSubstituted() {
        let text = "Ẩm ướt 漢"
        let s = scene(text)
        let font = LayoutRenderer.font(URL(fileURLWithPath: TempFonts.hoeflerText), 0, variations: [:], size: 20)!
        let expected = PreviewRenderer.coverage(of: text, in: font).filter { !$0 }.count
        #expect(expected >= 1)   // at least 漢 is not in Hoefler Text
        #expect(s.a.missingCharacters == expected)
        #expect(s.a.path != nil)
    }

    /// No installed system font reports an x-height of 0 (checked: all of /System/Library/Fonts[/Supplemental]), so the
    /// fallback is proven directly: a reported 0 must become the measured ink height of "x" / "H".
    @Test func zeroReportedHeightFallsBackToInk() throws {
        let font = try #require(LayoutRenderer.font(URL(fileURLWithPath: TempFonts.hoeflerText), 0, variations: [:], size: 100))
        let x = CompareRenderer.verticalMetric(0, fallback: "x", font: font)
        let h = CompareRenderer.verticalMetric(0, fallback: "H", font: font)
        #expect(x > 0 && abs(x - Double(CTFontGetXHeight(font))) < 3)
        #expect(h > 0 && abs(h - Double(CTFontGetCapHeight(font))) < 3)
        #expect(CompareRenderer.verticalMetric(42, fallback: "x", font: font) == 42)
    }

    @Test func overlayLinesShareLeftOrigin() {
        for mode in [CompareMode.overlay, .sideBySide] {
            let s = scene("Hamburgefonstiv", mode: mode)
            let gap = abs(s.a.path!.boundingBox.minX - s.b.path!.boundingBox.minX)
            #expect(gap <= 0.05 * s.pointSize)
        }
    }

    @Test func emptyTextRendersGuidesOnly() {
        let s = scene("")
        #expect(s.a.metrics!.lineWidth == 0)
        #expect(s.a.path == nil || s.a.path!.isEmpty)
        #expect(s.pointSize.isFinite)
        #expect(draw(s) != nil)
    }

    @Test func missingFontSide() {
        let gone = ResolvedFont(reference: FontReference(postScriptName: "Gone", family: "Gone"), faceID: nil,
                                url: nil, faceIndex: 0, isMissing: true)
        let s = scene("Hamburgefonstiv", rule: .matchXHeight, b: gone)
        #expect(s.b.isMissing && s.b.path == nil && s.b.metrics == nil)
        #expect(s.scaleB == 1)
        #expect(draw(s) != nil)
    }

    @Test func noB() {
        let s = scene("Hamburgefonstiv", rule: .matchXHeight, useB: false)
        #expect(s.b.font == nil)
        #expect(s.scaleB == 1)
    }

    @Test func imageDrawsBothColours() throws {
        let image = try #require(draw(scene("Hamburgefonstiv")))
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var red = 0, blue = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if r > 200 && r > g + 40 && r > b + 40 { red += 1 }
            if b > 200 && b > r + 40 && b > g + 40 { blue += 1 }
        }
        #expect(red > 0 && blue > 0)
    }

    @Test func percentDifference() {
        #expect(CompareRenderer.percentDifference(100, 94) == -6)
        #expect(CompareRenderer.percentDifference(0, 5) == nil)
    }

    /// A variable instance's PostScript name may differ from the base font's; the line must still draw.
    @Test func variableInstanceStillDraws() throws {
        let path = "/System/Library/Fonts/SFNS.ttf"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let ref = FontReference(postScriptName: "SFNS", family: "System Font", variations: ["wght": 700])
        let font = ResolvedFont(reference: ref, faceID: 1, url: URL(fileURLWithPath: path), faceIndex: 0, isMissing: false)
        let options = CompareOptions(mode: .overlay, sizeRule: .sameSize, outlines: false, guides: false)
        let s = CompareRenderer.scene(a: font, aLabel: "SF", b: nil, bLabel: "", text: "Hamburgefonstiv",
                                      options: options, canvas: Self.canvas)
        let path2 = try #require(s.a.path)
        #expect(!path2.isEmpty)
    }

    /// A run CoreText fell back to another font for is not drawn (the side's font lacks the character).
    @Test func fallbackRunIsNotDrawn() throws {
        let symbols = try #require(FontFile.font(at: URL(fileURLWithPath: Self.applePath), faceIndex: 0, size: 100))
        var scalar: [UniChar] = [0x65E5]
        var glyph: [CGGlyph] = [0]
        guard !CTFontGetGlyphsForCharacters(symbols, &scalar, &glyph, 1) else { return }   // font has it: no fallback to test
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "日", attributes: [.init(kCTFontAttributeName as String): symbols]))
        let usedFallback = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).contains { run in
            let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
            return !CompareRenderer.isSameFace(f, symbols)
        }
        guard usedFallback else { return }
        let path = CGMutablePath()
        CompareRenderer.appendGlyphs(of: line, font: symbols, to: path, offsetX: 0)
        #expect(path.isEmpty)
    }
}
