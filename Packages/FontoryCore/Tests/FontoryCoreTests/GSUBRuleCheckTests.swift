import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct GSUBRuleCheckTests {
    private func load(_ path: String) throws -> CTFont {
        try #require(FontFile.font(at: URL(fileURLWithPath: path), faceIndex: 0, size: 12))
    }

    private func glyph(_ c: Character, _ font: CTFont) -> CGGlyph {
        var u = Array(String(c).utf16)
        var g = [CGGlyph](repeating: 0, count: u.count)
        CTFontGetGlyphsForCharacters(font, &u, &g, u.count)
        return g[0]
    }

    @Test func labelsUseLowestScalarAndNames() throws {
        let font = try load(TempFonts.sfns)
        let labels = GlyphLabels(font: font)
        #expect(labels.character(for: glyph("A", font)) == "A")
        #expect(labels.characters(for: [glyph("A", font), glyph("b", font)]) == "Ab")
        let count = CTFontGetGlyphCount(font)
        let unmapped = try #require((1..<count).map { CGGlyph($0) }.first { labels.character(for: $0) == nil })
        #expect(!labels.label(for: unmapped).isEmpty)
        #expect(labels.characters(for: [unmapped]) == nil)
    }

    @Test func unmappedInputHasNoCharacters() throws {
        let font = try load(TempFonts.sfns)
        let labels = GlyphLabels(font: font)
        let unmapped = try #require((1..<CTFontGetGlyphCount(font)).map { CGGlyph($0) }.first { labels.character(for: $0) == nil })
        let rule = GSUBRule(kind: .single, input: [unmapped], outputs: [[glyph("a", font)]])
        #expect(GSUBRuleCheck.check(rule, tag: "ss01", font: font, labels: labels, language: nil) == [.noCharacters])
    }

    @Test func realRuleChecksPlain() throws {
        let font = try load(TempFonts.sfns)
        let labels = GlyphLabels(font: font)
        let reader = try #require(GSUBRuleReader.read(font))
        let counts = reader.counts(selection: .all)
        var found: (String, GSUBRule)?
        for tag in counts.keys.sorted() where (tag.hasPrefix("ss") || tag.hasPrefix("cv")) && found == nil {
            if let r = reader.rules(for: tag, selection: .all).rules.first(where: {
                $0.kind == .single && !$0.isContextual && labels.characters(for: $0.input) != nil
            }) { found = (tag, r) }
        }
        let (tag, rule) = try #require(found)
        #expect(GSUBRuleCheck.check(rule, tag: tag, font: font, labels: labels, language: nil) == [.plain])
    }

    /// CoreText returns right-to-left runs in visual order; the check compares in logical order.
    @Test func rtlMultipleRulesArePlain() throws {
        let font = try load("/System/Library/Fonts/SFArabic.ttf")
        let labels = GlyphLabels(font: font)
        let reader = try #require(GSUBRuleReader.read(font))
        let rules = reader.rules(for: "rclt", selection: .all).rules.filter {
            $0.kind == .multiple && !$0.isContextual && labels.characters(for: $0.input) != nil
        }
        try #require(!rules.isEmpty)
        let statuses = rules.map {
            GSUBRuleCheck.check($0, tag: "rclt", font: font, labels: labels, language: nil)
        }
        #expect(statuses.allSatisfy { $0 == [.plain] }, "\(statuses.filter { $0 != [.plain] }.count) of \(rules.count)")
    }

    @Test func contextualRuleIsContextOnly() throws {
        let font = try load(TempFonts.sfns)
        let labels = GlyphLabels(font: font)
        let rule = GSUBRule(kind: .single, input: [glyph("a", font)], outputs: [[glyph("b", font)]])
        #expect(GSUBRuleCheck.check(rule, tag: "ss01", font: font, labels: labels, language: nil) == [.contextOnly])
        let empty = GSUBRule(kind: .alternate, input: [glyph("a", font)], outputs: [[]])
        #expect(GSUBRuleCheck.check(empty, tag: "salt", font: font, labels: labels, language: nil) == [.contextOnly])
    }

    @Test func aatFontsAreUnchecked() throws {
        let hoefler = try load(TempFonts.hoeflerText)
        let newYork = try load(TempFonts.newYork)
        #expect(GSUBRuleCheck.hasAATLayout(hoefler))
        #expect(!GSUBRuleCheck.hasAATLayout(newYork))
        let rule = GSUBRule(kind: .single, input: [glyph("a", hoefler)], outputs: [[glyph("b", hoefler)]])
        #expect(GSUBRuleCheck.check(rule, tag: "ss01", font: hoefler, labels: GlyphLabels(font: hoefler), language: nil) == [.unchecked])
    }

    @Test func alternateUsesIndexedValues() throws {
        // SFArmenian's aalt alternates are honoured by CoreText only at their own 1-based value, so every output is
        // .plain only when the check shapes output i with value i + 1.
        let path = "/System/Library/Fonts/SFArmenian.ttf"
        try #require(FileManager.default.fileExists(atPath: path))
        let font = try load(path)
        let labels = GlyphLabels(font: font)
        let reader = try #require(GSUBRuleReader.read(font))
        let rule = try #require(reader.rules(for: "aalt", selection: .all).rules.first {
            $0.kind == .alternate && !$0.isContextual && $0.outputs.count >= 2
                && Set($0.outputs).count == $0.outputs.count && labels.characters(for: $0.input) != nil
        })
        let got = GSUBRuleCheck.check(rule, tag: "aalt", font: font, labels: labels, language: nil)
        #expect(got == Array(repeating: .plain, count: rule.outputs.count))
    }
}
