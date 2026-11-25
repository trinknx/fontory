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
        var checked = false
        for path in [TempFonts.sfns, TempFonts.newYork] {
            let font = try load(path)
            let labels = GlyphLabels(font: font)
            guard let reader = GSUBRuleReader.read(font) else { continue }
            for tag in reader.counts(selection: .all).keys.sorted() {
                guard let rule = reader.rules(for: tag, selection: .all).rules.first(where: {
                    $0.kind == .alternate && labels.characters(for: $0.input) != nil
                }) else { continue }
                let got = GSUBRuleCheck.check(rule, tag: tag, font: font, labels: labels, language: nil)
                #expect(got.count == rule.outputs.count)
                #expect(got.allSatisfy { $0 == .plain || $0 == .contextOnly })
                checked = true
            }
        }
        // Neither system font has alternate rules, so also exercise the indexed path with a hand-made rule.
        let font = try load(TempFonts.sfns)
        let rule = GSUBRule(kind: .alternate, input: [glyph("a", font)], outputs: [[glyph("b", font)], [glyph("c", font)]])
        let got = GSUBRuleCheck.check(rule, tag: "salt", font: font, labels: GlyphLabels(font: font), language: nil)
        #expect(got.count == 2)
        #expect(got.allSatisfy { $0 == .plain || $0 == .contextOnly })
        _ = checked
    }
}
