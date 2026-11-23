import CoreGraphics
import CoreText
import Foundation

/// The Characters tab's general-category groups (Unicode general category, first letter).
public enum GlyphCategory: String, CaseIterable, Sendable, Hashable {
    case letters, numbers, punctuation, symbols, marks, separatorsOther

    public init(_ scalar: Unicode.Scalar) {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            self = .letters
        case .decimalNumber, .letterNumber, .otherNumber:
            self = .numbers
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation:
            self = .punctuation
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            self = .symbols
        case .nonspacingMark, .spacingMark, .enclosingMark:
            self = .marks
        default:   // separators (Z*), controls, format, private use, surrogates, unassigned
            self = .separatorsOther
        }
    }

    public var title: String {
        switch self {
        case .letters: "Letters"
        case .numbers: "Numbers"
        case .punctuation: "Punctuation"
        case .symbols: "Symbols"
        case .marks: "Marks"
        case .separatorsOther: "Separators & Other"
        }
    }
}

/// The scripts the Characters tab filters by. Names follow `ScriptCoverage` (Kana is its "Hiragana/Katakana").
///
/// Swift exposes no Unicode Script property, so membership is by block ranges, which matches the Script property
/// closely for these scripts. Latin blocks also hold common characters (digits, punctuation, ×, ÷), so a Latin
/// scalar must also be alphabetic; the other blocks are taken whole.
public enum GlyphScript: String, CaseIterable, Sendable, Hashable {
    case latin, greek, cyrillic, arabic, hebrew, thai, devanagari, han, kana, hangul

    public var title: String {
        switch self {
        case .latin: "Latin"
        case .greek: "Greek"
        case .cyrillic: "Cyrillic"
        case .arabic: "Arabic"
        case .hebrew: "Hebrew"
        case .thai: "Thai"
        case .devanagari: "Devanagari"
        case .han: "Han"
        case .kana: "Kana"
        case .hangul: "Hangul"
        }
    }

    /// The matching entry of `ScriptCoverage.scripts`.
    var coverageName: String { self == .kana ? "Hiragana/Katakana" : title }

    private var ranges: [ClosedRange<UInt32>] {
        switch self {
        case .latin:
            [0x41...0x5A, 0x61...0x7A, 0xAA...0xAA, 0xBA...0xBA, 0xC0...0x24F, 0x250...0x2AF, 0x2B0...0x2B8,
             0x1D00...0x1DBF, 0x1E00...0x1EFF, 0x2071...0x2071, 0x207F...0x207F, 0x2090...0x209C, 0x212A...0x212B,
             0x2132...0x2132, 0x214E...0x214E, 0x2160...0x2188, 0x2C60...0x2C7F, 0xA722...0xA7FF, 0xAB30...0xAB6F,
             0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A]
        case .greek: [0x370...0x3FF, 0x1F00...0x1FFF, 0x2126...0x2126]
        case .cyrillic: [0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F]
        case .arabic: [0x600...0x6FF, 0x750...0x77F, 0x870...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF]
        case .hebrew: [0x591...0x5FF, 0xFB1D...0xFB4F]
        case .thai: [0xE01...0xE7F]
        case .devanagari: [0x900...0x97F, 0xA8E0...0xA8FF]
        case .han:
            [0x2E80...0x2FDF, 0x3005...0x3005, 0x3007...0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF]
        case .kana: [0x3041...0x309F, 0x30A1...0x30FF, 0x31F0...0x31FF, 0x32D0...0x32FE, 0xFF66...0xFF9D,
                     0x1AFF0...0x1B16F]
        case .hangul: [0x1100...0x11FF, 0x3131...0x318E, 0x3200...0x321E, 0x3260...0x327E, 0xA960...0xA97F,
                       0xAC00...0xD7FF, 0xFFA0...0xFFDC]
        }
    }

    public static func of(_ scalar: Unicode.Scalar) -> GlyphScript? {
        let v = scalar.value
        for script in allCases where script.ranges.contains(where: { $0.contains(v) }) {
            if script == .latin, !scalar.properties.isAlphabetic { return nil }
            return script
        }
        return nil
    }
}

/// One cell of the Characters tab: a character the cmap maps to a glyph, or a glyph no character maps to.
public struct GlyphEntry: Sendable, Hashable, Identifiable {
    public let glyphID: CGGlyph
    /// The Unicode scalar, nil for an unmapped glyph.
    public let scalarValue: UInt32?
    /// The glyph's name from the `post` table (or CFF charset), when the font has one.
    public let glyphName: String?
    /// Horizontal advance in font units.
    public let advance: Float
    public let category: GlyphCategory?
    public let script: GlyphScript?

    public init(glyphID: CGGlyph, scalarValue: UInt32?, glyphName: String?, advance: Float) {
        self.glyphID = glyphID
        self.scalarValue = scalarValue
        self.glyphName = glyphName
        self.advance = advance
        let scalar = scalarValue.flatMap(Unicode.Scalar.init)
        category = scalar.map(GlyphCategory.init)
        script = scalar.flatMap(GlyphScript.of)
    }

    /// Unique within an inventory: the scalar, or the glyph ID above the Unicode range.
    public var id: UInt32 { scalarValue ?? (0x110000 + UInt32(glyphID)) }
    public var isMapped: Bool { scalarValue != nil }
    public var scalar: Unicode.Scalar? { scalarValue.flatMap(Unicode.Scalar.init) }
    /// The character as a string ("" for an unmapped glyph).
    public var character: String { scalar.map { String($0) } ?? "" }
    /// "U+00E4", or nil for an unmapped glyph.
    public var codePointLabel: String? {
        scalarValue.map { "U+" + String(format: "%04X", $0) }
    }
    /// The Unicode name of the character.
    public var unicodeName: String? { scalar?.properties.name ?? scalar?.properties.nameAlias }
}

/// What the Characters tab shows.
public enum GlyphFilter: Hashable, Sendable {
    case all
    case category(GlyphCategory)
    case script(GlyphScript)
    /// Glyphs no character maps to ("Additional glyphs").
    case unmapped

    public func includes(_ entry: GlyphEntry) -> Bool {
        switch self {
        case .all: true
        case .category(let c): entry.category == c
        case .script(let s): entry.script == s
        case .unmapped: !entry.isMapped
        }
    }
}

public enum GlyphOrder: String, Sendable, Hashable, CaseIterable {
    /// Mapped characters by code point, then the unmapped glyphs by glyph ID.
    case unicode
    /// Everything by glyph ID (a glyph mapped from several characters appears once per character).
    case glyph
}

/// Every glyph of one face: the characters of its cmap (in code point order) followed by the glyphs no character
/// maps to (in glyph-ID order, without .notdef). Pure data, computed once per face off the main thread.
public struct GlyphInventory: Sendable {
    public let entries: [GlyphEntry]
    public let glyphCount: Int
    /// Metrics in font units.
    public let unitsPerEm: Int
    public let ascent: Double
    public let descent: Double
    public let capHeight: Double
    public let xHeight: Double
    private let counts: [GlyphFilter: Int]

    public static func load(fileURL: URL, faceIndex: Int) -> GlyphInventory? {
        FontFile.font(at: fileURL, faceIndex: faceIndex).map(GlyphInventory.init(font:))
    }

    public init(font: CTFont) {
        let upem = Int(CTFontGetUnitsPerEm(font))
        let unitFont = CTFontCreateCopyWithAttributes(font, CGFloat(max(1, upem)), nil, nil)
        let glyphCount = max(0, CTFontGetGlyphCount(unitFont))
        self.glyphCount = glyphCount
        unitsPerEm = upem
        ascent = Double(CTFontGetAscent(unitFont))
        descent = Double(CTFontGetDescent(unitFont))
        capHeight = Double(CTFontGetCapHeight(unitFont))
        xHeight = Double(CTFontGetXHeight(unitFont))

        // Glyph names and advances, indexed by glyph ID.
        let graphics = CTFontCopyGraphicsFont(unitFont, nil)
        var names = [String?](repeating: nil, count: glyphCount)
        for g in 0..<glyphCount { names[g] = graphics.name(for: CGGlyph(g)) as String? }
        var allGlyphs = (0..<glyphCount).map { CGGlyph($0) }
        var advances = [CGSize](repeating: .zero, count: glyphCount)
        if glyphCount > 0 { CTFontGetAdvancesForGlyphs(unitFont, .horizontal, &allGlyphs, &advances, glyphCount) }

        // Mapped: one UTF-16 buffer for every scalar of the character set; a surrogate pair's glyph lands in its
        // first slot.
        let scalars = Self.scalars(in: CTFontCopyCharacterSet(unitFont) as CharacterSet)
        var units: [UniChar] = []
        units.reserveCapacity(scalars.count + 64)
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count)
        for s in scalars {
            offsets.append(units.count)
            units.append(contentsOf: s.utf16)
        }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if !units.isEmpty { _ = CTFontGetGlyphsForCharacters(unitFont, units, &glyphs, units.count) }

        var entries: [GlyphEntry] = []
        entries.reserveCapacity(max(scalars.count, glyphCount))
        var mapped = [Bool](repeating: false, count: glyphCount)
        for (s, offset) in zip(scalars, offsets) {
            let g = glyphs[offset]
            guard g != 0, Int(g) < glyphCount else { continue }
            mapped[Int(g)] = true
            entries.append(GlyphEntry(glyphID: g, scalarValue: s.value, glyphName: names[Int(g)],
                                      advance: Float(advances[Int(g)].width)))
        }
        for g in 1..<max(1, glyphCount) where !mapped[g] {
            entries.append(GlyphEntry(glyphID: CGGlyph(g), scalarValue: nil, glyphName: names[g],
                                      advance: Float(advances[g].width)))
        }
        self.entries = entries

        var counts: [GlyphFilter: Int] = [.all: entries.count]
        for e in entries {
            if let c = e.category { counts[.category(c), default: 0] += 1 } else { counts[.unmapped, default: 0] += 1 }
            if let s = e.script { counts[.script(s), default: 0] += 1 }
        }
        self.counts = counts
    }

    /// How many entries `filter` shows (without a search).
    public func count(for filter: GlyphFilter) -> Int { counts[filter] ?? 0 }

    /// The entries `filter` and `search` let through, in `order`.
    public func entries(filter: GlyphFilter, search: GlyphSearch?, order: GlyphOrder) -> [GlyphEntry] {
        var out = entries.filter { filter.includes($0) && (search?.matches($0) ?? true) }
        if order == .glyph {
            // Stable: the same glyph from several characters stays in code point order.
            out = out.enumerated().sorted { ($0.element.glyphID, $0.offset) < ($1.element.glyphID, $1.offset) }.map(\.element)
        }
        return out
    }

    /// Every scalar of a character set, ascending, read from its bitmap (one bit per code point: the BMP, then for
    /// each other plane present, a plane byte followed by its 8 KB).
    static func scalars(in set: CharacterSet) -> [Unicode.Scalar] {
        let bitmap = [UInt8](set.bitmapRepresentation)
        let planeSize = 8192
        var out: [Unicode.Scalar] = []
        func readPlane(_ plane: UInt32, from start: Int) {
            guard start + planeSize <= bitmap.count else { return }
            for byteIndex in 0..<planeSize {
                let byte = bitmap[start + byteIndex]
                guard byte != 0 else { continue }
                for bit in 0..<8 where byte & (1 << bit) != 0 {
                    if let s = Unicode.Scalar(plane << 16 | UInt32(byteIndex * 8 + bit)) { out.append(s) }
                }
            }
        }
        readPlane(0, from: 0)
        var i = planeSize
        while i < bitmap.count {
            let plane = UInt32(bitmap[i])
            readPlane(plane, from: i + 1)
            i += 1 + planeSize
        }
        return out
    }
}

/// A parsed Characters search. Rules, in order:
/// - Empty (after trimming) searches nothing. A lone space is the space character.
/// - One character searches for that character only (so "7" is the digit, "a" the letter).
/// - `U+XXXX`, `u+xxxx` or `0xXXXX` (1–6 hex digits) is that code point only.
/// - A bare token of 2–6 hex digits is a code point. With a hex letter (`00e4`) it is hex. All decimal digits are
///   read both as decimal and as hex (`228` finds U+00E4 and U+0228), except with a leading zero, which marks
///   hex only (`0041` is U+0041). A token with a hex letter is also searched as text (words like "face" are valid
///   hex, and glyph names like "uni00E4" contain them); an all-digit token is not.
/// - Any other text matches a substring of the Unicode name or of the glyph name, ignoring case. Characters
///   outside ASCII in it are also searched for themselves (pasting "äöü" finds the three letters).
public struct GlyphSearch: Sendable, Equatable {
    public let codePoints: Set<UInt32>
    /// Searched in Unicode names and glyph names; nil for character and `U+` searches.
    public let text: String?
    private let upperText: String?

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard raw.count == 1 else { return nil }
            self.init(codePoints: Set(raw.unicodeScalars.map(\.value)), text: nil)
            return
        }
        if trimmed.count == 1 {
            self.init(codePoints: Set(trimmed.unicodeScalars.map(\.value)), text: nil)
            return
        }
        let lower = trimmed.lowercased()
        for prefix in ["u+", "0x"] where lower.hasPrefix(prefix) {
            let digits = lower.dropFirst(prefix.count)
            if let v = Self.hexValue(digits) {
                self.init(codePoints: v <= 0x10FFFF ? [v] : [], text: nil)
                return
            }
        }
        var points: Set<UInt32> = []
        let allDigits = lower.allSatisfy(\.isASCIIDigit)
        if trimmed.count <= 6, let hex = Self.hexValue(Substring(lower)) {
            if hex <= 0x10FFFF { points.insert(hex) }
            if allDigits, !lower.hasPrefix("0"), let decimal = UInt32(lower), decimal <= 0x10FFFF { points.insert(decimal) }
            if allDigits {
                self.init(codePoints: points, text: nil)
                return
            }
        }
        for s in trimmed.unicodeScalars where !s.isASCII && !s.properties.isWhitespace { points.insert(s.value) }
        self.init(codePoints: points, text: trimmed)
    }

    private init(codePoints: Set<UInt32>, text: String?) {
        self.codePoints = codePoints
        self.text = text
        upperText = text?.uppercased()
    }

    private static func hexValue(_ s: Substring) -> UInt32? {
        guard (1...6).contains(s.count), s.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(s, radix: 16)
    }

    public func matches(_ entry: GlyphEntry) -> Bool {
        if let v = entry.scalarValue, codePoints.contains(v) { return true }
        guard let text, let upperText else { return false }
        if let name = entry.unicodeName, name.contains(upperText) { return true }
        if let glyphName = entry.glyphName, glyphName.range(of: text, options: .caseInsensitive) != nil { return true }
        return false
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isWholeNumber }
}

/// Inventories of the most recently shown faces. Thread-safe; `inventory` computes on the calling thread.
public final class GlyphInventoryCache: Sendable {
    private struct Key: Hashable, Sendable {
        let url: URL
        let faceIndex: Int
    }

    private let cache: LRUCache<Key, GlyphInventory>

    public init(limit: Int = 6) {
        cache = LRUCache(limit: limit)
    }

    public func cached(fileURL: URL, faceIndex: Int) -> GlyphInventory? {
        cache[Key(url: fileURL, faceIndex: faceIndex)]
    }

    /// The cached inventory, or a new one (call off the main thread).
    public func inventory(fileURL: URL, faceIndex: Int) -> GlyphInventory? {
        let key = Key(url: fileURL, faceIndex: faceIndex)
        if let hit = cache[key] { return hit }
        guard let inventory = GlyphInventory.load(fileURL: fileURL, faceIndex: faceIndex) else { return nil }
        cache[key] = inventory
        return inventory
    }

    public func removeAll() { cache.removeAll() }
}
