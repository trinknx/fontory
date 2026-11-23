import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct BodyTextRendererTests {
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    func style(_ text: String = BodyTextSamples.english.text, width: CGFloat = 640, columns: Int = 1,
               alignment: CTTextAlignment = .left, lineHeight: CGFloat = 1.4) -> BodyTextStyle {
        var s = BodyTextStyle(text: text, pointSize: 18, foreground: Self.black, background: Self.white, width: width)
        s.columns = columns
        s.alignment = alignment
        s.lineHeight = lineHeight
        return s
    }

    func font(_ path: String = TempFonts.arialBold, index: Int = 0, features: PreviewFeatures = .standard) throws -> CTFont {
        try #require(PreviewRenderer().font(fileURL: URL(fileURLWithPath: path), faceIndex: index, pointSize: 18,
                                            features: features))
    }

    func hasInk(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: px.count, by: 4) where px[i] != 255 || px[i + 1] != 255 || px[i + 2] != 255 { return true }
        return false
    }

    @Test func samplesAreMultiParagraph() {
        for sample in BodyTextSamples.all {
            let paragraphs = sample.text.components(separatedBy: "\n").filter { !$0.isEmpty }
            #expect(paragraphs.count >= 5, "\(sample.name): a title line and at least four paragraphs")
            #expect(sample.text.contains("—"), "\(sample.name) has an em dash")
            let hasDigit = sample.text.contains { $0.isNumber }
            #expect(hasDigit, "\(sample.name) has numbers")
        }
        #expect(BodyTextSamples.vietnamese.text.contains("ữ") && BodyTextSamples.vietnamese.text.contains("ệ"))
    }

    @Test func columnSplitProducesNFrames() throws {
        let f = try font()
        for n in 1...3 {
            let layout = BodyTextRenderer.layout(font: f, style: style(columns: n))
            #expect(layout.columnCount == n, "\(n) columns")
            #expect(layout.isComplete)
        }
    }

    @Test func moreColumnsAreShorter() throws {
        let f = try font()
        // Wide enough that three columns are not dominated by wrapping waste.
        let one = BodyTextRenderer.layout(font: f, style: style(width: 1400, columns: 1)).size.height
        let three = BodyTextRenderer.layout(font: f, style: style(width: 1400, columns: 3)).size.height
        #expect(three < one)
    }

    @Test func columnsAreBalanced() throws {
        let f = try font()
        let layout = BodyTextRenderer.layout(font: f, style: style(columns: 2))
        let counts = layout.lineCountsPerColumn
        #expect(counts.count == 2)
        #expect(abs(counts[0] - counts[1]) <= 3, "\(counts)")
    }

    @Test func heightGrowsWithTextLength() throws {
        let f = try font()
        let short = BodyTextRenderer.layout(font: f, style: style("A short line.")).size.height
        let long = BodyTextRenderer.layout(font: f, style: style()).size.height
        let longer = BodyTextRenderer.layout(font: f, style: style(BodyTextSamples.english.text + "\n" + BodyTextSamples.english.text)).size.height
        #expect(short < long && long < longer)
    }

    @Test func lineHeightChangesHeight() throws {
        let f = try font()
        let tight = BodyTextRenderer.layout(font: f, style: style(lineHeight: 1.0)).size.height
        let loose = BodyTextRenderer.layout(font: f, style: style(lineHeight: 2.0)).size.height
        #expect(loose > tight * 1.5)
    }

    @Test func baselinesAreLineHeightApart() throws {
        let f = try font()
        let layout = BodyTextRenderer.layout(font: f, style: style(BodyTextSamples.english.text.components(separatedBy: "\n")[1]))
        let ys = layout.lines.map(\.origin.y)
        #expect(ys.count > 2)
        for (a, b) in zip(ys, ys.dropFirst()) { #expect(abs((a - b) - 18 * 1.4) < 0.01, "\(a - b)") }
    }

    @Test func justifiedDiffersFromLeft() throws {
        let f = try font()
        let left = BodyTextRenderer.layout(font: f, style: style(alignment: .left))
        let justified = BodyTextRenderer.layout(font: f, style: style(alignment: .justified))
        let column = left.columnWidth
        // Justified body lines (not the last of a paragraph) fill the column; ragged-right lines mostly do not.
        let fullLeft = left.lineWidths.filter { $0 > column - 0.5 }.count
        let fullJustified = justified.lineWidths.filter { $0 > column - 0.5 }.count
        #expect(fullJustified > fullLeft)
    }

    @Test func vietnameseRendersWithTheFont() throws {
        let f = try font()
        let layout = BodyTextRenderer.layout(font: f, style: style(BodyTextSamples.vietnamese.text))
        #expect(layout.isComplete)
        #expect(layout.size.height > 100)
        let strips = BodyTextRenderer.renderAll(layout, scale: 2)
        #expect(!strips.isEmpty)
        #expect(strips.contains { hasInk($0.image) })
    }

    @Test func featuresChangeGlyphRuns() throws {
        let text = "office fit — Small caps"
        let plain = BodyTextRenderer.layout(font: try font(TempFonts.avenirNext), style: style(text)).glyphs
        let noLiga = BodyTextRenderer.layout(font: try font(TempFonts.avenirNext, features: []), style: style(text)).glyphs
        let smcp = BodyTextRenderer.layout(font: try font(TempFonts.avenirNext, features: [.ligatures, .smallCaps]),
                                           style: style(text)).glyphs
        #expect(plain != noLiga)
        #expect(plain != smcp)
    }

    @Test func stripsCoverTheWholeHeight() throws {
        let f = try font()
        var s = style(BodyTextSamples.english.text + "\n" + BodyTextSamples.english.text)
        s.showGuides = true
        let layout = BodyTextRenderer.layout(font: f, style: s)
        let strips = BodyTextRenderer.renderAll(layout, scale: 2, stripHeight: 256)
        #expect(strips.count > 1)
        #expect(strips.first?.rect.minY == 0)
        #expect(abs((strips.last?.rect.maxY ?? 0) - layout.size.height) < 0.001)
        for (a, b) in zip(strips, strips.dropFirst()) { #expect(a.rect.maxY == b.rect.minY) }
        for strip in strips {
            #expect(strip.image.width == Int((strip.rect.width * 2).rounded()))
        }
    }

    @Test func emptyTextAndTinyWidthDoNotCrash() throws {
        let f = try font()
        let empty = BodyTextRenderer.layout(font: f, style: style(""))
        #expect(empty.size.height > 0)
        _ = BodyTextRenderer.renderAll(empty, scale: 2)
        let tiny = BodyTextRenderer.layout(font: f, style: style(width: 4, columns: 3))
        _ = BodyTextRenderer.renderAll(tiny, scale: 1)
    }

    @Test func styleEqualityComparesColorsByValue() {
        let a = style()
        var b = style()
        b.foreground = CGColor(gray: 0, alpha: 1)
        #expect(a == b)
        b.columns = 2
        #expect(a != b)
    }

    @Test func rendersOneStripForAYRange() throws {
        let f = try font()
        let layout = BodyTextRenderer.layout(font: f, style: style())
        let rect = CGRect(x: 0, y: 200, width: layout.size.width, height: 100)
        let image = try #require(BodyTextRenderer.render(layout, scale: 2, rect: rect))
        #expect(image.width == Int(layout.size.width * 2) && image.height == 200)
        #expect(hasInk(image))
        // Opaque background: no alpha channel kept.
        #expect(image.alphaInfo == .noneSkipLast)
    }

    @Test func stripCacheRetainsABoundedNumberOfStrips() throws {
        let f = try font()
        func maxRetained(copies: Int) -> (count: Int, bytes: Int, strips: Int) {
            let text = Array(repeating: BodyTextSamples.english.text, count: copies).joined(separator: "\n")
            let layout = BodyTextRenderer.layout(font: f, style: style(text))
            let cache = BodyTextStripCache(layoutSize: layout.size, stripHeight: 256, limit: 6)
            var maxCount = 0, maxBytes = 0
            // Scroll top to bottom through a 600 pt viewport, rendering what is wanted, as the view does.
            var y: CGFloat = 0
            while y < layout.size.height {
                let wanted = cache.indices(near: CGRect(x: 0, y: y, width: layout.size.width, height: 600))
                #expect(wanted.count <= cache.limit)
                for i in wanted where cache.image(at: i) == nil {
                    let image = try! #require(BodyTextRenderer.render(layout, scale: 2, rect: cache.rect(at: i)))
                    cache.insert(image, at: i, keeping: Set(wanted))
                }
                maxCount = max(maxCount, cache.count)
                maxBytes = max(maxBytes, cache.retainedBytes)
                y += 150
            }
            return (maxCount, maxBytes, cache.stripCount)
        }
        let short = maxRetained(copies: 4)
        let long = maxRetained(copies: 16)
        #expect(long.strips > short.strips * 3)
        #expect(short.count <= 6 && long.count <= 6)
        #expect(long.bytes == short.bytes, "retained memory does not grow with the document")
    }

    @Test func stripCacheRectsTileTheLayout() {
        let cache = BodyTextStripCache(layoutSize: CGSize(width: 300, height: 1000), stripHeight: 256, limit: 6)
        #expect(cache.stripCount == 4)
        #expect(cache.rect(at: 0) == CGRect(x: 0, y: 0, width: 300, height: 256))
        #expect(cache.rect(at: 3) == CGRect(x: 0, y: 768, width: 300, height: 232))
        #expect(cache.indices(near: CGRect(x: 0, y: 300, width: 300, height: 100)) == [0, 1, 2])
    }

    @Test func tallScriptInkIsNotClipped() throws {
        let f = try #require(PreviewRenderer().font(fileURL: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Zapfino.ttf"),
                                                    faceIndex: 0, pointSize: 72, features: .standard))
        var s = style("Zapfino flourishes\nfly high and low", width: 1600)
        s.pointSize = 72
        s.lineHeight = 1.0
        let layout = BodyTextRenderer.layout(font: f, style: s)
        for placed in layout.lines {
            let ink = CTLineGetBoundsWithOptions(placed.line, .useGlyphPathBounds)
            #expect(placed.origin.y + ink.maxY <= layout.size.height, "ink above the top")
            #expect(placed.origin.y + ink.minY >= 0, "ink below the bottom")
        }
    }
}
