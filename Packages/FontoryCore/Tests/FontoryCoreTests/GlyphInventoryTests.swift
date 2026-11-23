import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct GlyphInventoryTests {
    static let hoefler = "/System/Library/Fonts/Supplemental/Hoefler Text.ttc"
    static let zapfino = "/System/Library/Fonts/Supplemental/Zapfino.ttf"

    static func font(_ path: String, face: Int = 0, size: CGFloat = 1) throws -> CTFont {
        try #require(FontFile.font(at: URL(fileURLWithPath: path), faceIndex: face, size: size))
    }

    // MARK: Inventory

    @Test func arialBoldInventory() throws {
        let inv = try #require(GlyphInventory.load(fileURL: URL(fileURLWithPath: TempFonts.arialBold), faceIndex: 0))
        #expect(inv.entries.count > 200)
        #expect(inv.glyphCount > 200)
        let font = try Self.font(TempFonts.arialBold)
        var unit: UniChar = 0x41
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1))
        let a = try #require(inv.entries.first { $0.scalarValue == 0x41 })
        #expect(a.glyphID == glyph)
        #expect(a.glyphName == "A")
        #expect(a.category == .letters)
        #expect(a.script == .latin)
        #expect(a.advance > 0)
        // Mapped first, in Unicode order; no .notdef among the unmapped.
        let mapped = inv.entries.filter(\.isMapped)
        #expect(mapped.map { $0.scalarValue! } == mapped.map { $0.scalarValue! }.sorted())
        #expect(inv.entries.prefix(mapped.count).allSatisfy { $0.isMapped })
        #expect(!inv.entries.contains { !$0.isMapped && $0.glyphID == 0 })
        #expect(inv.unitsPerEm == 2048)
        #expect(inv.ascent > 0 && inv.descent > 0 && inv.capHeight > inv.xHeight)
    }

    @Test func astralScalarsAreMapped() throws {
        let inv = try #require(GlyphInventory.load(fileURL: URL(fileURLWithPath: TempFonts.emoji), faceIndex: 0))
        let grinning = try #require(inv.entries.first { $0.scalarValue == 0x1F600 })
        #expect(grinning.glyphID != 0)
        #expect(grinning.category == .symbols)
    }

    @Test func ttcFacesDiffer() throws {
        let url = URL(fileURLWithPath: TempFonts.avenirNext)
        let first = try #require(GlyphInventory.load(fileURL: url, faceIndex: 0))
        let other = try #require(GlyphInventory.load(fileURL: url, faceIndex: 3))
        #expect(first.entries.count > 200 && other.entries.count > 200)
        #expect(first.entries.contains { $0.scalarValue == 0x41 })
        #expect(other.entries.contains { $0.scalarValue == 0x41 })
        #expect(GlyphInventory.load(fileURL: url, faceIndex: 999) == nil)
    }

    @Test func unmappedGlyphsOfAFontWithAlternates() throws {
        for path in [Self.hoefler, Self.zapfino] where FileManager.default.fileExists(atPath: path) {
            let inv = try #require(GlyphInventory.load(fileURL: URL(fileURLWithPath: path), faceIndex: 0))
            let unmapped = inv.entries.filter { !$0.isMapped }
            #expect(!unmapped.isEmpty, "\(path)")
            #expect(unmapped.map(\.glyphID) == unmapped.map(\.glyphID).sorted())
            let mappedIDs = Set(inv.entries.filter(\.isMapped).map(\.glyphID))
            #expect(unmapped.allSatisfy { !mappedIDs.contains($0.glyphID) })
            #expect(inv.entries.filter(\.isMapped).count + unmapped.count >= inv.glyphCount - 1)
        }
    }

    @Test func junkFileHasNoInventory() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let junk = try t.junk()
        #expect(GlyphInventory.load(fileURL: junk, faceIndex: 0) == nil)
    }

    @Test func cacheReturnsTheSameInventory() throws {
        let cache = GlyphInventoryCache(limit: 2)
        let url = URL(fileURLWithPath: TempFonts.arialBold)
        let a = try #require(cache.inventory(fileURL: url, faceIndex: 0))
        #expect(cache.cached(fileURL: url, faceIndex: 0) != nil)
        let b = try #require(cache.inventory(fileURL: url, faceIndex: 0))
        #expect(a.entries.count == b.entries.count)
        #expect(cache.cached(fileURL: URL(fileURLWithPath: TempFonts.sfns), faceIndex: 0) == nil)
    }

    // MARK: Classification

    @Test func categories() {
        func cat(_ v: UInt32) -> GlyphCategory { GlyphCategory(Unicode.Scalar(v)!) }
        #expect(cat(0x41) == .letters)
        #expect(cat(0x4E00) == .letters)
        #expect(cat(0x37) == .numbers)
        #expect(cat(0xBD) == .numbers)        // ½
        #expect(cat(0x2C) == .punctuation)
        #expect(cat(0x2014) == .punctuation)  // em dash
        #expect(cat(0x20AC) == .symbols)      // €
        #expect(cat(0x2B) == .symbols)
        #expect(cat(0x301) == .marks)
        #expect(cat(0x20) == .separatorsOther)
        #expect(cat(0xE000) == .separatorsOther)
    }

    @Test func scripts() {
        func script(_ v: UInt32) -> GlyphScript? { GlyphScript.of(Unicode.Scalar(v)!) }
        #expect(script(0x41) == .latin)
        #expect(script(0x1EA1) == .latin)     // ạ
        #expect(script(0x37) == nil)          // digits are common
        #expect(script(0xD7) == nil)          // ×
        #expect(script(0x3B1) == .greek)
        #expect(script(0x416) == .cyrillic)
        #expect(script(0x627) == .arabic)
        #expect(script(0x5D0) == .hebrew)
        #expect(script(0xE01) == .thai)
        #expect(script(0x915) == .devanagari)
        #expect(script(0x4E00) == .han)
        #expect(script(0x20000) == .han)
        #expect(script(0x3042) == .kana)
        #expect(script(0x30A2) == .kana)
        #expect(script(0xAC00) == .hangul)
        // Every script title names an entry of the coverage table (Kana covers Hiragana/Katakana).
        let coverage = Set(ScriptCoverage.scripts.map(\.name))
        for s in GlyphScript.allCases { #expect(coverage.contains(s.coverageName), "\(s)") }
    }

    @Test func filtersAndOrder() throws {
        let inv = try #require(GlyphInventory.load(fileURL: URL(fileURLWithPath: Self.hoefler), faceIndex: 0))
        let letters = inv.entries(filter: .category(.letters), search: nil, order: .unicode)
        #expect(!letters.isEmpty && letters.allSatisfy { $0.category == .letters })
        let latin = inv.entries(filter: .script(.latin), search: nil, order: .unicode)
        #expect(latin.contains { $0.scalarValue == 0x41 } && latin.allSatisfy { $0.script == .latin })
        let extra = inv.entries(filter: .unmapped, search: nil, order: .unicode)
        #expect(!extra.isEmpty && extra.allSatisfy { !$0.isMapped })
        let byGlyph = inv.entries(filter: .all, search: nil, order: .glyph)
        #expect(byGlyph.count == inv.entries.count)
        #expect(byGlyph.map(\.glyphID) == byGlyph.map(\.glyphID).sorted())
        #expect(inv.count(for: .all) == inv.entries.count)
        #expect(inv.count(for: .unmapped) == extra.count)
        #expect(inv.count(for: .script(.han)) == 0)
    }

    // MARK: Search

    @Test func searchForms() throws {
        #expect(GlyphSearch("") == nil)
        #expect(GlyphSearch("   ") == nil)
        #expect(GlyphSearch(" ")?.codePoints == [0x20])          // a lone space searches for the space
        #expect(GlyphSearch("ä")?.codePoints == [0xE4])
        #expect(GlyphSearch("ä")?.text == nil)
        #expect(GlyphSearch("7")?.codePoints == [0x37])          // one character is that character
        #expect(GlyphSearch("U+00E4")?.codePoints == [0xE4])
        #expect(GlyphSearch("u+1f600")?.codePoints == [0x1F600])
        #expect(GlyphSearch("U+00E4")?.text == nil)
        #expect(GlyphSearch("0xE4")?.codePoints == [0xE4])
        #expect(GlyphSearch("00e4")?.codePoints == [0xE4])        // hex letters: hex only
        #expect(GlyphSearch("228")?.codePoints == [228, 0x228])   // all digits: decimal and hex
        #expect(GlyphSearch("U+110000") == nil || GlyphSearch("U+110000")?.codePoints.isEmpty == true)
        #expect(GlyphSearch("diaeresis")?.text == "diaeresis")
        #expect(GlyphSearch("face")?.codePoints == [0xFACE])      // hex-looking words also search names
        #expect(GlyphSearch("face")?.text == "face")
    }

    @Test func searchMatches() throws {
        let inv = try #require(GlyphInventory.load(fileURL: URL(fileURLWithPath: TempFonts.arialBold), faceIndex: 0))
        func scalars(_ q: String) -> Set<UInt32> {
            Set(inv.entries(filter: .all, search: GlyphSearch(q), order: .unicode).compactMap(\.scalarValue))
        }
        #expect(scalars("ä") == [0xE4])
        #expect(scalars("U+00E4") == [0xE4])
        #expect(scalars("00e4") == [0xE4])
        #expect(scalars("228").contains(0xE4))
        let diaeresis = scalars("with diaeresis")
        #expect(diaeresis.contains(0xE4) && diaeresis.contains(0xC4) && !diaeresis.contains(0x41))
        #expect(scalars("LATIN CAPITAL LETTER A").contains(0x41))
        // Glyph names: "adieresis" is the post-table name of ä.
        let byGlyphName = inv.entries(filter: .all, search: GlyphSearch("Adieresis"), order: .unicode)
        #expect(byGlyphName.contains { $0.scalarValue == 0xE4 })
        #expect(inv.entries(filter: .category(.numbers), search: GlyphSearch("ä"), order: .unicode).isEmpty)
    }

    // MARK: SVG

    @Test func svgOfM() throws {
        let url = URL(fileURLWithPath: TempFonts.arialBold)
        let inv = try #require(GlyphInventory.load(fileURL: url, faceIndex: 0))
        let m = try #require(inv.entries.first { $0.scalarValue == 0x4D })
        let svg = try #require(GlyphSVG.document(fileURL: url, faceIndex: 0, glyph: m.glyphID))
        #expect(svg.hasPrefix("<svg"))
        #expect(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        let d = try #require(svg.firstMatch(of: /d="([^"]+)"/)?.1)
        #expect(d.hasPrefix("M"))
        #expect(d.contains("L"))
        #expect(d.contains("Z"))
        #expect(!d.contains("nan") && !d.contains("inf"))
        // viewBox: advance wide, ascent + descent high (font units).
        let box = try #require(svg.firstMatch(of: /viewBox="([^"]+)"/)?.1).split(separator: " ").compactMap { Double($0) }
        #expect(box.count == 4)
        #expect(box[2] == Double(m.advance).rounded())
        #expect(box[3] > 2048 * 0.9)
        // Flipped: every y lies inside the viewBox (M of Arial sits between baseline and cap height).
        let numbers = d.split(whereSeparator: { $0.isLetter || $0 == " " }).compactMap { Double($0) }
        let ys = stride(from: 1, to: numbers.count, by: 2).map { numbers[$0] }
        #expect(!ys.isEmpty && ys.allSatisfy { $0 >= 0 && $0 <= box[3] })
    }

    @Test func svgNumberFormat() {
        #expect(GlyphSVG.number(1.0) == "1")
        #expect(GlyphSVG.number(1.25) == "1.25")
        #expect(GlyphSVG.number(-0.001) == "0")
        #expect(GlyphSVG.number(12.3456) == "12.35")
    }

    @Test func emptyGlyphHasEmptyPath() throws {
        let url = URL(fileURLWithPath: TempFonts.arialBold)
        let inv = try #require(GlyphInventory.load(fileURL: url, faceIndex: 0))
        let space = try #require(inv.entries.first { $0.scalarValue == 0x20 })
        let svg = try #require(GlyphSVG.document(fileURL: url, faceIndex: 0, glyph: space.glyphID))
        #expect(svg.contains("d=\"\""))
    }

    // MARK: Cell rendering

    @Test func rendersGlyphCell() throws {
        let font = try Self.font(TempFonts.arialBold, size: 40)
        var unit: UniChar = 0x41
        var glyph: CGGlyph = 0
        _ = CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1)
        let style = GlyphCellStyle(size: CGSize(width: 64, height: 64), scale: 2,
                                   foreground: CGColor(gray: 0, alpha: 1), background: CGColor(gray: 1, alpha: 1))
        let image = try #require(GlyphCellRenderer.render(font: font, glyph: glyph, style: style))
        #expect(image.width == 128 && image.height == 128)
        #expect(PreviewRendererTests().hasInk(image))
        #expect(GlyphCellRenderer.pointSize(cellHeight: 64, ascent: 0.9, descent: 0.2) > 20)
    }
}
