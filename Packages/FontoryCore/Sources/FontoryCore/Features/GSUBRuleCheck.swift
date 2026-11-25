import CoreGraphics
import CoreText
import Foundation

/// Glyph to text lookups for showing GSUB rules: the lowest Unicode scalar that maps to a glyph, and its name.
public struct GlyphLabels: Sendable {
    private let characters: [CGGlyph: String]
    private let names: [CGGlyph: String]

    public init(font: CTFont) {
        var chars: [CGGlyph: String] = [:]
        let scalars = GlyphInventory.scalars(in: CTFontCopyCharacterSet(font) as CharacterSet)
        var utf16: [UniChar] = []
        var owners: [(start: Int, scalar: Unicode.Scalar)] = []
        for s in scalars {
            owners.append((utf16.count, s))
            utf16.append(contentsOf: Array(String(Character(s)).utf16))
        }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        if !utf16.isEmpty { _ = CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) }
        // Ascending scalars: the first writer is the lowest scalar.
        for (start, scalar) in owners {
            let g = glyphs[start]
            if g != 0, chars[g] == nil { chars[g] = String(Character(scalar)) }
        }
        characters = chars

        let graphics = CTFontCopyGraphicsFont(font, nil)
        var names: [CGGlyph: String] = [:]
        for g in 0..<CTFontGetGlyphCount(font) {
            if let n = graphics.name(for: CGGlyph(g)) as String?, !n.isEmpty { names[CGGlyph(g)] = n }
        }
        self.names = names
    }

    public func character(for glyph: CGGlyph) -> String? { characters[glyph] }

    /// nil when any glyph has no character.
    public func characters(for glyphs: [CGGlyph]) -> String? {
        var out = ""
        for g in glyphs {
            guard let c = characters[g] else { return nil }
            out += c
        }
        return out
    }

    /// The character, else the glyph name, else `#<gid>`.
    public func label(for glyph: CGGlyph) -> String {
        characters[glyph] ?? names[glyph] ?? "#\(glyph)"
    }
}

public enum GSUBRuleStatus: Sendable, Hashable {
    /// CoreText produces the output from the input characters alone.
    case plain
    /// Only in some context (or not reachable by typing the input).
    case contextOnly
    /// The input has no character, so it cannot be typed.
    case noCharacters
    /// An AAT font: CoreText's result cannot be compared.
    case unchecked
}

public enum GSUBRuleCheck {
    /// Has `morx` or `mort`.
    public static func hasAATLayout(_ font: CTFont) -> Bool {
        [("morx" as String), "mort"].contains { tag in
            let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return CTFontCopyTable(font, CTFontTableTag(code), []) != nil
        }
    }

    /// One status per entry of `rule.outputs`.
    public static func check(_ rule: GSUBRule, tag: String, font: CTFont, labels: GlyphLabels,
                             language: String?) -> [GSUBRuleStatus] {
        let count = rule.outputs.count
        if hasAATLayout(font) { return Array(repeating: .unchecked, count: count) }
        guard let text = labels.characters(for: rule.input), !text.isEmpty else {
            return Array(repeating: .noCharacters, count: count)
        }
        return rule.outputs.enumerated().map { index, output in
            guard !output.isEmpty else { return .contextOnly }
            let value = rule.kind == .alternate ? index + 1 : 1
            return shape(text, tag: tag, value: value, font: font, language: language) == output ? .plain : .contextOnly
        }
    }

    private static func shape(_ text: String, tag: String, value: Int, font: CTFont, language: String?) -> [CGGlyph] {
        let setting = FontFeatureSetting.openType(tag: tag, value: value).attribute
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute as String: [setting]] as CFDictionary)
        let featured = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): featured]
        if let language { attrs[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var glyphs: [CGGlyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let n = CTRunGetGlyphCount(run)
            var buf = [CGGlyph](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &buf)
            glyphs += buf
        }
        return glyphs
    }
}
