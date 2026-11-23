import CoreText
import Foundation

/// The default digits of a face (`faces.figure_style`).
public enum FigureStyle: Int, Sendable, CaseIterable {
    case unknown = 0, lining, oldstyle
}

/// What the library stores about a face beyond `ParsedFace`'s basics, so filters run from the database without
/// opening font files: its character coverage, its layout feature tags, and its default figure style.
/// Bump `version` to re-extract every face in the background (`FaceBackfill`).
public struct FaceMetadata: Sendable, Hashable {
    public static let version = 2

    /// The face's cmap as merged scalar ranges.
    public var coverage: CoverageRanges
    /// GSUB/GPOS feature tags (all scripts and languages) plus the AAT features that map exactly to an OpenType tag;
    /// sorted, unique, each 4 printable ASCII characters.
    public var features: [String]
    public var figureStyle: FigureStyle

    public init(coverage: CoverageRanges, features: [String], figureStyle: FigureStyle) {
        self.coverage = coverage
        self.features = features
        self.figureStyle = figureStyle
    }

    /// What a present but unparsable file gets: nothing, stamped with the current version so it is not retried.
    public static let empty = FaceMetadata(coverage: CoverageRanges(scalars: []), features: [], figureStyle: .unknown)

    public static func read(_ font: CTFont, styleClass: StyleClass? = nil) -> FaceMetadata {
        read(font, tables: FontParser.availableTables(font), styleClass: styleClass)
    }

    /// `tables`: the face's table tags (`CTFontCopyAvailableTables`), when the caller already has them.
    /// `styleClass`: the face's class when the caller has computed it; symbol faces get `.unknown` figures.
    static func read(_ font: CTFont, tables: Set<UInt32>, styleClass: StyleClass? = nil) -> FaceMetadata {
        FaceMetadata(coverage: CoverageRanges(characterSet: CTFontCopyCharacterSet(font)),
                     features: features(font, tables: tables),
                     figureStyle: styleClass == .symbol ? .unknown : figureStyle(font))
    }

    /// `faces.features`: `" liga smcp "`, a space before the first tag and after each; empty for no tags.
    public static func featuresText(_ tags: [String]) -> String {
        tags.isEmpty ? "" : " " + tags.joined(separator: " ") + " "
    }

    // MARK: Features

    static func features(_ font: CTFont, tables: Set<UInt32>) -> [String] {
        var tags = Set(LayoutFeatureInventory.read(font).allTags)
        // AAT layout lives in morx (or the older mort); CoreText only reports AAT-style features for other fonts by
        // translating their OpenType ones, which the inventory already has.
        if tables.contains(FontParser.tag("morx")) || tables.contains(FontParser.tag("mort")) {
            tags.formUnion(aatTags(font))
        }
        return tags.filter(isValidTag).sorted()
    }

    /// OpenType tags of the face's AAT selectors, where an exact equivalent exists. For non-exclusive feature types
    /// only the "on" (even) selectors count; for exclusive ones every selector, default or not, is a setting the
    /// face supports.
    static func aatTags(_ font: CTFont) -> Set<String> {
        guard let types = CTFontCopyFeatures(font) as? [[String: Any]] else { return [] }
        var out = Set<String>()
        for type in types {
            guard let typeID = (type[kCTFontFeatureTypeIdentifierKey as String] as? NSNumber)?.intValue,
                  let selectors = type[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] else { continue }
            let exclusive = (type[kCTFontFeatureTypeExclusiveKey as String] as? NSNumber)?.boolValue ?? false
            for s in selectors {
                guard let selector = (s[kCTFontFeatureSelectorIdentifierKey as String] as? NSNumber)?.intValue else { continue }
                if !exclusive && selector % 2 != 0 { continue }
                if let tag = openTypeTag(aatType: typeID, selector: selector) { out.insert(tag) }
            }
        }
        return out
    }

    /// `FontFeatureSet.aatTag`, plus the exact mappings it leaves out (SFNTLayoutTypes.h numbering).
    static func openTypeTag(aatType type: Int, selector: Int) -> String? {
        if let tag = FontFeatureSet.aatTag(type: type, selector: selector) { return tag }
        switch (type, selector) {
        case (1, 20): return "hlig"   // historical ligatures
        case (14, 4): return "zero"   // slashed zero
        case (21, 0): return "onum"   // lower case (oldstyle) numbers
        case (21, 1): return "lnum"   // upper case (lining) numbers
        case (33, 0): return "case"   // case-sensitive layout
        case (33, 2): return "cpsp"   // case-sensitive spacing
        case (36, 2): return "swsh"   // swash alternates
        case (36, 4): return "cswh"   // contextual swash alternates
        default: return nil
        }
    }

    /// Four printable ASCII characters, no spaces (the stored format separates tags with spaces).
    static func isValidTag(_ tag: String) -> Bool {
        tag.utf8.count == 4 && tag.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    // MARK: Figures

    /// Oldstyle when the default glyphs of "3 4 5 7 9" all descend below the baseline by more than 5% of the em, or
    /// when the glyph of "0" is no taller than 1.1 × the x-height (tested only when the x-height is below 0.8 × the
    /// cap height, so caps-only faces, whose x-height is as tall as their caps, are not misread); otherwise lining.
    /// No digits: unknown. Symbol faces never get here (`read` returns unknown for them).
    static func figureStyle(_ font: CTFont) -> FigureStyle {
        let characters = Array("034579".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)  // missing ones stay 0
        var rects = [CGRect](repeating: .zero, count: characters.count)
        CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, &rects, characters.count)
        // A digit counts when the cmap maps it to a glyph with ink.
        let present = (0..<characters.count).filter { glyphs[$0] != 0 && rects[$0].width > 0 && rects[$0].height > 0 }
        guard !present.isEmpty else { return .unknown }
        let em = CTFontGetSize(font)  // font units scaled to the point size: one em = the size
        let descenders = present.filter { $0 != 0 }
        if !descenders.isEmpty && descenders.allSatisfy({ rects[$0].minY < -0.05 * em }) { return .oldstyle }
        let xHeight = CTFontGetXHeight(font), capHeight = CTFontGetCapHeight(font)
        if present.first == 0, xHeight > 0, xHeight < 0.8 * capHeight, rects[0].height <= 1.1 * xHeight { return .oldstyle }
        return .lining
    }
}

/// A set of Unicode scalars as sorted, non-overlapping, non-adjacent inclusive ranges.
public struct CoverageRanges: Sendable, Hashable {
    public var ranges: [ClosedRange<UInt32>]

    /// Merges the scalars (any order, duplicates allowed) into ranges.
    public init(scalars: some Sequence<UInt32>) {
        var builder = Builder()
        for scalar in scalars.sorted() { builder.add(scalar, scalar) }
        ranges = builder.finish()
    }

    /// Decodes `blob`; nil unless it is whole `[start, end]` pairs with start ≤ end, in increasing order without
    /// overlaps.
    public init?(blob: Data) {
        guard blob.count % 8 == 0 else { return nil }
        var out: [ClosedRange<UInt32>] = []
        out.reserveCapacity(blob.count / 8)
        let ok: Bool = blob.withUnsafeBytes { raw in
            var previous: UInt32?
            for i in stride(from: 0, to: raw.count, by: 8) {
                let start = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                let end = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i + 4, as: UInt32.self))
                guard start <= end else { return false }
                if let previous, start <= previous { return false }
                previous = end
                out.append(start...end)
            }
            return true
        }
        guard ok else { return nil }
        ranges = out
    }

    /// Little-endian `UInt32` pairs `[start, end]`.
    public var blob: Data { Self.encode(ranges) }

    static func encode(_ ranges: [ClosedRange<UInt32>]) -> Data {
        var data = Data(count: ranges.count * 8)
        data.withUnsafeMutableBytes { raw in
            for (i, r) in ranges.enumerated() {
                raw.storeBytes(of: r.lowerBound.littleEndian, toByteOffset: i * 8, as: UInt32.self)
                raw.storeBytes(of: r.upperBound.littleEndian, toByteOffset: i * 8 + 4, as: UInt32.self)
            }
        }
        return data
    }

    /// Binary search.
    public func contains(_ scalar: UInt32) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound < scalar { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count && ranges[lo].lowerBound <= scalar
    }

    /// From a character set's bitmap representation: one call, then a scan 64 scalars at a time (empty and full
    /// words skip at once, others add their runs of set bits), instead of a membership test per scalar.
    init(characterSet: CFCharacterSet) {
        let bitmap = CFCharacterSetCreateBitmapRepresentation(nil, characterSet) as Data
        var builder = Builder()
        bitmap.withUnsafeBytes { raw in
            let planeSize = 8192
            guard raw.count >= planeSize else { return }
            var planes: [(plane: UInt32, offset: Int)] = [(0, 0)]
            // BMP, then for each other plane with members: its number, then its 8192 bytes.
            var offset = planeSize
            while offset + 1 + planeSize <= raw.count {
                planes.append((UInt32(raw[offset]), offset + 1))
                offset += 1 + planeSize
            }
            for (plane, start) in planes.sorted(by: { $0.plane < $1.plane }) where plane <= 16 {
                let base = plane << 16
                for w in 0..<(planeSize / 8) {
                    // Bit k of byte j is scalar j * 8 + k: a little-endian word's bit i is scalar i.
                    var bits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: start + w * 8, as: UInt64.self))
                    if bits == 0 { continue }
                    let first = base | UInt32(w) << 6
                    if bits == .max { builder.add(first, first + 63); continue }
                    while bits != 0 {
                        let lo = bits.trailingZeroBitCount
                        let shifted = bits >> lo
                        let length = shifted == .max ? 64 - lo : (~shifted).trailingZeroBitCount
                        builder.add(first + UInt32(lo), first + UInt32(lo + length - 1))
                        bits = lo + length >= 64 ? 0 : bits & ~((UInt64(1) << (lo + length)) - 1)
                    }
                }
            }
        }
        ranges = builder.finish()
    }

    /// Appends runs in increasing order, merging overlapping and adjacent ones.
    private struct Builder {
        var ranges: [ClosedRange<UInt32>] = []
        var start: UInt32 = 0
        var end: UInt32 = 0
        var open = false

        mutating func add(_ lo: UInt32, _ hi: UInt32) {
            if open && (end == .max || lo <= end + 1) {
                end = max(end, hi)
                return
            }
            if open { ranges.append(start...end) }
            start = lo
            end = hi
            open = true
        }

        mutating func finish() -> [ClosedRange<UInt32>] {
            if open { ranges.append(start...end) }
            open = false
            return ranges
        }
    }
}
