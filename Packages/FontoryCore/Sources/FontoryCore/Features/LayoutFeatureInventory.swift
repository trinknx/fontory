import CoreText
import Foundation

/// The OpenType layout features a face declares in its `GSUB` and `GPOS` tables, by script and language system,
/// plus the UI names of stylistic sets and character variants (`FeatureParams` → `name` table).
///
/// Parsing is strict: a table whose ScriptList or FeatureList is inconsistent (offsets or counts past its end,
/// feature indices out of range) contributes nothing, so a malformed font yields an empty inventory, never a crash.
public struct LayoutFeatureInventory: Sendable, Equatable {
    /// One `ScriptList` entry: its default language system (nil when the script has none) and its languages.
    struct ScriptEntry: Sendable, Equatable {
        var defaultFeatures: [Int]?
        var languages: [String: [Int]]
    }

    /// One parsed `GSUB` or `GPOS` table.
    struct Table: Sendable, Equatable {
        /// FeatureList in order: tag, and the UI name ID from `FeatureParams` for ssXX / cvXX.
        var features: [(tag: String, nameID: UInt16?)]
        var scripts: [String: ScriptEntry]

        static let empty = Table(features: [], scripts: [:])

        static func == (a: Table, b: Table) -> Bool {
            a.scripts == b.scripts && a.features.map(\.tag) == b.features.map(\.tag)
                && a.features.map(\.nameID) == b.features.map(\.nameID)
        }

        /// Feature indices of one language system; a script the table lacks falls back to `DFLT`, a language the
        /// script lacks to the script's default, as shapers do.
        func indices(script: String, language: String?) -> [Int] {
            guard let entry = scripts[script] ?? scripts["DFLT"] else { return [] }
            if let language, let indices = entry.languages[language] { return indices }
            return entry.defaultFeatures ?? []
        }
    }

    var gsub: Table
    var gpos: Table
    /// UI names by tag (stylistic sets, character variants), resolved from the `name` table.
    public private(set) var featureNames: [String: String]

    public static let empty = LayoutFeatureInventory(gsub: .empty, gpos: .empty, featureNames: [:])

    /// True when neither table declares a feature (no OpenType layout, or unreadable tables).
    public var isEmpty: Bool { gsub.features.isEmpty && gpos.features.isEmpty }

    // MARK: Reading

    /// The inventory of a face.
    public static func read(_ font: CTFont) -> LayoutFeatureInventory {
        parse(gsub: SfntReader.table("GSUB", of: font), gpos: SfntReader.table("GPOS", of: font),
              name: SfntReader.table("name", of: font))
    }

    /// The inventory from raw tables (any may be missing).
    public static func parse(gsub: SfntReader?, gpos: SfntReader?, name: SfntReader?) -> LayoutFeatureInventory {
        let sub = gsub.flatMap(parseTable) ?? .empty
        let pos = gpos.flatMap(parseTable) ?? .empty
        var ids: [String: UInt16] = [:]
        for f in sub.features + pos.features {
            if let id = f.nameID, ids[f.tag] == nil { ids[f.tag] = id }
        }
        var names: [String: String] = [:]
        if let name, !ids.isEmpty {
            let table = NameTable(name)
            for (tag, id) in ids {
                if let s = table?.string(id), !s.isEmpty { names[tag] = s }
            }
        }
        return LayoutFeatureInventory(gsub: sub, gpos: pos, featureNames: names)
    }

    /// One `GSUB`/`GPOS` table, or nil when anything is inconsistent.
    static func parseTable(_ r: SfntReader) -> Table? {
        guard let major = r.u16(0), major == 1, let scriptListOffset = r.u16(4), let featureListOffset = r.u16(6)
        else { return nil }
        // FeatureList
        var features: [(tag: String, nameID: UInt16?)] = []
        if featureListOffset != 0 {
            let fl = Int(featureListOffset)
            guard let count = r.u16(fl) else { return nil }
            features.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let record = fl + 2 + i * 6
                guard let tag = r.tag(record), let offset = r.u16(record + 4) else { return nil }
                let featureTable = fl + Int(offset)
                guard let paramsOffset = r.u16(featureTable), r.u16(featureTable + 2) != nil else { return nil }
                var id: UInt16?
                if paramsOffset != 0, isNumbered(tag, prefix: "ss") || isNumbered(tag, prefix: "cv") {
                    let params = featureTable + Int(paramsOffset)
                    guard let version = r.u16(params), let value = r.u16(params + 2) else { return nil }
                    // ssXX: version, UINameID; cvXX: format, FeatUILabelNameID. Only font-specific IDs count.
                    if version == 0, (256...32767).contains(value) { id = value }
                }
                features.append((tag, id))
            }
        }
        // ScriptList
        var scripts: [String: ScriptEntry] = [:]
        if scriptListOffset != 0 {
            let sl = Int(scriptListOffset)
            guard let count = r.u16(sl) else { return nil }
            for i in 0..<Int(count) {
                let record = sl + 2 + i * 6
                guard let tag = r.tag(record), let offset = r.u16(record + 4) else { return nil }
                let script = sl + Int(offset)
                guard let defaultOffset = r.u16(script), let langCount = r.u16(script + 2) else { return nil }
                var entry = ScriptEntry(defaultFeatures: nil, languages: [:])
                if defaultOffset != 0 {
                    guard let indices = langSys(r, at: script + Int(defaultOffset), featureCount: features.count)
                    else { return nil }
                    entry.defaultFeatures = indices
                }
                for j in 0..<Int(langCount) {
                    let langRecord = script + 4 + j * 6
                    guard let langTag = r.tag(langRecord), let langOffset = r.u16(langRecord + 4),
                          let indices = langSys(r, at: script + Int(langOffset), featureCount: features.count)
                    else { return nil }
                    entry.languages[langTag.trimmingCharacters(in: .whitespaces)] = indices
                }
                // A tag listed twice keeps its first entry.
                if scripts[tag] == nil { scripts[tag] = entry }
            }
        }
        return Table(features: features, scripts: scripts)
    }

    /// The feature indices of a LangSys table (required feature first), or nil when any is out of range.
    private static func langSys(_ r: SfntReader, at offset: Int, featureCount: Int) -> [Int]? {
        guard let required = r.u16(offset + 2), let count = r.u16(offset + 4) else { return nil }
        var out: [Int] = []
        if required != 0xFFFF {
            guard Int(required) < featureCount else { return nil }
            out.append(Int(required))
        }
        for k in 0..<Int(count) {
            guard let index = r.u16(offset + 6 + k * 2), Int(index) < featureCount else { return nil }
            out.append(Int(index))
        }
        return out
    }

    static func isNumbered(_ tag: String, prefix: String) -> Bool {
        tag.hasPrefix(prefix) && tag.count == 4 && tag.dropFirst(2).allSatisfy(\.isASCII) && Int(tag.dropFirst(2)) != nil
    }

    // MARK: Queries

    /// Every feature tag of both tables, deduplicated, in FeatureList order (GSUB first).
    public var allTags: [String] {
        var seen = Set<String>()
        return (gsub.features + gpos.features).map(\.tag).filter { seen.insert($0).inserted }
    }

    /// Feature tags of one language system (`language` nil: the script's default), deduplicated.
    public func tags(script: String, language: String?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for table in [gsub, gpos] {
            for i in table.indices(script: script, language: language) {
                let tag = table.features[i].tag
                if seen.insert(tag).inserted { out.append(tag) }
            }
        }
        return out
    }

    /// The tags for a picker selection.
    public func tags(for selection: LayoutSelection) -> [String] {
        switch selection {
        case .all: allTags
        case let .languageSystem(script, language): tags(script: script, language: language)
        }
    }

    /// Script tags declared by either table, sorted with `DFLT` first.
    public var scripts: [String] {
        let all = Set(gsub.scripts.keys).union(gpos.scripts.keys)
        return all.sorted { a, b in
            if a == "DFLT" || b == "DFLT" { return a == "DFLT" && b != "DFLT" }
            return a < b
        }
    }

    /// Language tags declared for a script by either table, sorted.
    public func languages(script: String) -> [String] {
        let a = gsub.scripts[script]?.languages.keys.map { $0 } ?? []
        let b = gpos.scripts[script]?.languages.keys.map { $0 } ?? []
        return Set(a + b).sorted()
    }
}

/// What the Script/Language picker filters by.
public enum LayoutSelection: Sendable, Hashable {
    /// Every feature the font declares.
    case all
    /// The features of one script, in its default language system (`language` nil) or one language.
    case languageSystem(script: String, language: String?)
}

/// The `name` table's records, for looking up font-specific names.
struct NameTable {
    private let r: SfntReader
    private let records: [(platform: UInt16, encoding: UInt16, language: UInt16, nameID: UInt16, length: Int, offset: Int)]

    init?(_ r: SfntReader) {
        guard let count = r.u16(2), let storage = r.u16(4) else { return nil }
        var records: [(UInt16, UInt16, UInt16, UInt16, Int, Int)] = []
        for i in 0..<Int(count) {
            let o = 6 + i * 12
            guard let p = r.u16(o), let e = r.u16(o + 2), let l = r.u16(o + 4), let n = r.u16(o + 6),
                  let len = r.u16(o + 8), let off = r.u16(o + 10) else { return nil }
            records.append((p, e, l, n, Int(len), Int(storage) + Int(off)))
        }
        self.r = r
        self.records = records
    }

    /// The string for `nameID`: English (Windows en-US, then Mac English) preferred, else any decodable record.
    func string(_ nameID: UInt16) -> String? {
        let candidates = records.filter { $0.nameID == nameID }
        func rank(_ c: (platform: UInt16, encoding: UInt16, language: UInt16, nameID: UInt16, length: Int, offset: Int)) -> Int {
            switch (c.platform, c.language) {
            case (3, 0x0409): 0
            case (1, 0): 1
            case (0, _): 2
            case (3, let l) where l & 0xFF == 0x09: 3   // other English variants
            default: 4
            }
        }
        for c in candidates.sorted(by: { rank($0) < rank($1) }) {
            guard let raw = r.slice(c.offset, c.length) else { continue }
            let decoded: String?
            switch c.platform {
            case 0, 3:
                decoded = raw.count % 2 == 0 ? String(bytes: raw, encoding: .utf16BigEndian) : nil
            case 1 where c.encoding == 0:
                decoded = String(bytes: raw, encoding: .macOSRoman)
            default:
                decoded = nil
            }
            if let s = decoded?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return nil
    }
}
