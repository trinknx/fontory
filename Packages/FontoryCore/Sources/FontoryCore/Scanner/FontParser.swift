import CoreText
import Foundation

public enum FontParserError: Error, Equatable {
    case unreadable
}

/// Reads face metadata through CoreText. Stateless, so safe to call from many threads at once.
public enum FontParser {
    public static func parse(url: URL) throws -> [ParsedFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            throw FontParserError.unreadable
        }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        return descriptors.enumerated().map { index, descriptor in
            face(index: index, descriptor: descriptor, fallbackName: fallbackName)
        }
    }

    // MARK: - Per face

    private static let size: CGFloat = 12

    private static func face(index: Int, descriptor: CTFontDescriptor, fallbackName: String) -> ParsedFace {
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)

        var family = CTFontCopyFamilyName(font) as String
        var fullName = CTFontCopyFullName(font) as String
        if family.isEmpty { family = fallbackName }
        if fullName.isEmpty { fullName = fallbackName }
        let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? ""
        let psName = CTFontCopyPostScriptName(font) as String

        let traits = CTFontCopyTraits(font) as NSDictionary
        let weightTrait = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
        let widthTrait = (traits[kCTFontWidthTrait as String] as? NSNumber)?.doubleValue ?? 0
        let slant = (traits[kCTFontSlantTrait as String] as? NSNumber)?.doubleValue ?? 0
        let symbolic = CTFontSymbolicTraits(rawValue: (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0)

        let axesJSON = variationAxesJSON(font)

        let upm = Int(CTFontGetUnitsPerEm(font))
        let scale = Double(upm) / Double(size)
        let metrics = FaceMetrics(
            unitsPerEm: upm,
            ascender: Double(CTFontGetAscent(font)) * scale,
            descender: -Double(CTFontGetDescent(font)) * scale,
            capHeight: Double(CTFontGetCapHeight(font)) * scale,
            xHeight: Double(CTFontGetXHeight(font)) * scale)

        let tables = availableTables(font)
        let outline = outlineType(tables)
        let isColor = !tables.isDisjoint(with: [tag("COLR"), tag("sbix"), tag("SVG "), tag("CBDT")])

        return ParsedFace(
            faceIndex: index, postScriptName: psName, family: family, style: style, fullName: fullName,
            weight: min(900, max(100, 100 + (weightTrait + 1) * 400)),
            width: min(9, max(1, 1 + (widthTrait + 1) * 4)),
            slant: slant,
            isItalic: symbolic.contains(.traitItalic),
            isVariable: axesJSON != nil,
            axesJSON: axesJSON,
            vendor: CTFontCopyName(font, kCTFontManufacturerNameKey) as String?,
            designer: CTFontCopyName(font, kCTFontDesignerNameKey) as String?,
            version: CTFontCopyName(font, kCTFontVersionNameKey) as String?,
            glyphCount: CTFontGetGlyphCount(font),
            scriptsBitmask: ScriptCoverage.bitmask(for: font),
            metrics: metrics,
            fsType: fsType(font),
            outlineType: outline,
            isColor: isColor,
            isBitmap: outline == .bitmap,
            hasGSUB: tables.contains(tag("GSUB")),
            hasGPOS: tables.contains(tag("GPOS")),
            styleClass: classify(font: font, family: family, fullName: fullName, style: style,
                                 monospace: symbolic.contains(.traitMonoSpace), tables: tables))
    }

    /// Style class of one face, read from its descriptor. Used by the background backfill.
    static func styleClass(descriptor: CTFontDescriptor, fallbackName: String) -> StyleClass {
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        var family = CTFontCopyFamilyName(font) as String
        var fullName = CTFontCopyFullName(font) as String
        if family.isEmpty { family = fallbackName }
        if fullName.isEmpty { fullName = fallbackName }
        let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? ""
        let traits = CTFontCopyTraits(font) as NSDictionary
        let symbolic = CTFontSymbolicTraits(rawValue: (traits[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0)
        return classify(font: font, family: family, fullName: fullName, style: style,
                        monospace: symbolic.contains(.traitMonoSpace), tables: availableTables(font))
    }

    private static func classify(font: CTFont, family: String, fullName: String, style: String,
                                 monospace: Bool, tables: Set<UInt32>) -> StyleClass {
        var input = StyleClassifier.Input(isMonospace: monospace, coversLatin: ScriptCoverage.bitmask(for: font) & 1 != 0,
                                          names: [family, fullName, style])
        if let os2 = SfntReader.table("OS/2", of: font) {
            if let fc = os2.u16(30) {
                input.familyClass = Int(fc >> 8)
                input.familySubclass = Int(fc & 0xFF)
            }
            if let p = os2.slice(32, 10) { input.panose = Array(p) }
        }
        if tables.contains(tag("cmap")), let cmap = SfntReader.table("cmap", of: font), let n = cmap.u16(2) {
            for i in 0..<Int(n) {
                let rec = 4 + i * 8
                guard let platform = cmap.u16(rec), let encoding = cmap.u16(rec + 2) else { break }
                if platform == 3 && encoding == 0 { input.hasSymbolCmap = true; break }
            }
        }
        return StyleClassifier.classify(input)
    }

    // MARK: - Helpers

    private static func tag(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func tagString(_ value: Int) -> String {
        let v = UInt32(truncatingIfNeeded: value)
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func availableTables(_ font: CTFont) -> Set<UInt32> {
        guard let array = CTFontCopyAvailableTables(font, []) else { return [] }
        var out = Set<UInt32>()
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            out.insert(UInt32(truncatingIfNeeded: UInt(bitPattern: raw)))
        }
        return out
    }

    private static func outlineType(_ tables: Set<UInt32>) -> OutlineType {
        if tables.contains(tag("glyf")) { return .truetype }
        if tables.contains(tag("CFF ")) { return .cff }
        if tables.contains(tag("CFF2")) { return .cff2 }
        if !tables.isDisjoint(with: [tag("sbix"), tag("CBDT"), tag("EBDT")]) { return .bitmap }
        return .unknown
    }

    private static func fsType(_ font: CTFont) -> Int? {
        guard let data = CTFontCopyTable(font, CTFontTableTag(tag("OS/2")), []) as Data?, data.count >= 10 else { return nil }
        let base = data.startIndex
        return Int(data[base + 8]) << 8 | Int(data[base + 9])
    }

    private static func variationAxesJSON(_ font: CTFont) -> String? {
        guard let axes = CTFontCopyVariationAxes(font) as? [[String: Any]], !axes.isEmpty else { return nil }
        let list: [[String: Any]] = axes.map { axis in
            var entry: [String: Any] = [:]
            if let id = (axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue {
                entry["tag"] = tagString(id)
            }
            if let name = axis[kCTFontVariationAxisNameKey as String] as? String { entry["name"] = name }
            if let v = (axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue { entry["min"] = v }
            if let v = (axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue { entry["max"] = v }
            if let v = (axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue { entry["default"] = v }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
