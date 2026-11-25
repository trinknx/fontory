import CoreGraphics
import CoreText
import Foundation

/// One substitution a `GSUB` feature can make, as the glyphs it reads and the glyphs it writes.
public struct GSUBRule: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case single, multiple, alternate, ligature }
    public let kind: Kind
    /// One glyph, or a ligature's components in order.
    public let input: [CGGlyph]
    /// single / ligature: `[[g]]`; multiple: `[[g1, g2…]]`; alternate: `[[a1], [a2], …]`.
    public let outputs: [[CGGlyph]]
    public let isContextual: Bool

    public init(kind: Kind, input: [CGGlyph], outputs: [[CGGlyph]], isContextual: Bool = false) {
        self.kind = kind
        self.input = input
        self.outputs = outputs
        self.isContextual = isContextual
    }
}

/// The rules of one feature.
public struct GSUBFeatureRules: Sendable, Equatable {
    /// At most `listLimit`, in lookup order then coverage order.
    public var rules: [GSUBRule]
    /// Distinct rules found (at least `rules.count`).
    public var totalCount: Int
    /// The budget ran out, or some referenced lookup was unreadable.
    public var isIncomplete: Bool
    /// No rule could be read and at least one lookup failed.
    public var isUnreadable: Bool

    public static let listLimit = 2_000
    static let empty = GSUBFeatureRules(rules: [], totalCount: 0, isIncomplete: false, isUnreadable: false)
}

/// Reads the substitutions behind `GSUB` features. Parsing is strict and budgeted: malformed data makes the
/// affected lookup unreadable, never a crash.
public struct GSUBRuleReader: Sendable {
    private let gsub: SfntReader
    private let table: LayoutFeatureInventory.Table
    private let lookupList: Int
    private let lookupCount: Int

    /// Steps one feature may spend (records and glyphs visited).
    static let featureBudget = 500_000

    /// nil: no `GSUB`, or its header or lists are unreadable.
    public static func read(_ font: CTFont) -> GSUBRuleReader? {
        SfntReader.table("GSUB", of: font).flatMap { GSUBRuleReader(gsub: $0) }
    }

    init?(gsub: SfntReader) {
        guard let table = LayoutFeatureInventory.parseTable(gsub), let list = gsub.u16(8), list != 0,
              let count = gsub.u16(Int(list)) else { return nil }
        self.gsub = gsub
        self.table = table
        self.lookupList = Int(list)
        self.lookupCount = Int(count)
    }

    // MARK: Queries

    /// Every GSUB feature tag of the selection with at least one rule, and its count.
    public func counts(selection: LayoutSelection) -> [String: Int] {
        var out: [String: Int] = [:]
        for tag in tags(of: selection) {
            let n = rules(for: tag, selection: selection).totalCount
            if n > 0 { out[tag] = n }
        }
        return out
    }

    public func rules(for tag: String, selection: LayoutSelection) -> GSUBFeatureRules {
        rules(for: tag, selection: selection, budget: Self.featureBudget)
    }

    func rules(for tag: String, selection: LayoutSelection, budget: Int) -> GSUBFeatureRules {
        var lookups = Set<Int>()
        for i in featureIndices(selection) where table.features[i].tag == tag {
            for l in table.features[i].lookups { lookups.insert(Int(l)) }
        }
        var walk = Walk(budget: budget)
        for index in lookups.sorted() {
            if walk.exhausted { break }
            readLookup(index, &walk)
        }
        return walk.result
    }

    private func featureIndices(_ selection: LayoutSelection) -> [Int] {
        switch selection {
        case .all: Array(table.features.indices)
        case let .languageSystem(script, language): table.indices(script: script, language: language)
        }
    }

    private func tags(of selection: LayoutSelection) -> [String] {
        var seen = Set<String>()
        return featureIndices(selection).map { table.features[$0].tag }.filter { seen.insert($0).inserted }
    }

    // MARK: Walking

    /// The state of one feature's walk: budget, distinct rules in first-seen order, and failures.
    struct Walk {
        var budget: Int
        var rules: [GSUBRule] = []
        var seen = Set<GSUBRule>()
        var failed = false
        var exhausted = false

        init(budget: Int) { self.budget = budget }

        /// Counts `n` steps; false (and `exhausted`) once the budget is spent.
        mutating func spend(_ n: Int) -> Bool {
            budget -= n
            if budget < 0 { exhausted = true }
            return !exhausted
        }

        mutating func add(_ rule: GSUBRule) {
            if seen.insert(rule).inserted, rules.count < GSUBFeatureRules.listLimit { rules.append(rule) }
        }

        var result: GSUBFeatureRules {
            GSUBFeatureRules(rules: rules, totalCount: seen.count, isIncomplete: failed || exhausted,
                             isUnreadable: seen.isEmpty && failed)
        }
    }

    /// A subtable's rules, or nil when it is malformed (it then contributes nothing).
    private typealias Parsed = [GSUBRule]?

    /// Reads LookupList entry `index` and adds the rules of its subtables to `walk`.
    private func readLookup(_ index: Int, _ walk: inout Walk) {
        guard index < lookupCount, walk.spend(1), let offset = gsub.u16(lookupList + 2 + index * 2),
              case let lookup = lookupList + Int(offset), let type = gsub.u16(lookup),
              let count = gsub.u16(lookup + 4), walk.spend(Int(count)) else {
            walk.failed = true
            return
        }
        for i in 0..<Int(count) {
            guard let sub = gsub.u16(lookup + 6 + i * 2) else { walk.failed = true; return }
            readSubtable(type: Int(type), at: lookup + Int(sub), &walk, extensionDepth: 0)
            if walk.exhausted { return }
        }
    }

    /// Dispatches on the lookup type. Types 5, 6 and 8 (contextual, chaining, reverse chaining) are not read yet.
    private func readSubtable(type: Int, at offset: Int, _ walk: inout Walk, extensionDepth: Int) {
        let parsed: Parsed
        switch type {
        case 1: parsed = single(at: offset, &walk)
        case 2: parsed = sequences(at: offset, kind: .multiple, &walk)
        case 3: parsed = sequences(at: offset, kind: .alternate, &walk)
        case 4: parsed = ligatures(at: offset, &walk)
        case 7:
            // Extension: format 1, wrapped type, 32-bit offset from this subtable. Nesting is not allowed.
            guard extensionDepth == 0, gsub.u16(offset) == 1, let inner = gsub.u16(offset + 2),
                  let delta = gsub.u32(offset + 4), delta <= UInt32(Int32.max) else { walk.failed = true; return }
            readSubtable(type: Int(inner), at: offset + Int(delta), &walk, extensionDepth: 1)
            return
        default:
            return
        }
        if let rules = parsed {
            for r in rules { walk.add(r) }
        } else {
            walk.failed = true
        }
    }

    /// The glyphs of a Coverage table with their coverage indices, in coverage order.
    private func coverage(at offset: Int, _ walk: inout Walk) -> [(glyph: UInt16, index: Int)]? {
        guard let format = gsub.u16(offset), let count = gsub.u16(offset + 2) else { return nil }
        var out: [(UInt16, Int)] = []
        switch format {
        case 1:
            guard walk.spend(Int(count)) else { return nil }
            for i in 0..<Int(count) {
                guard let g = gsub.u16(offset + 4 + i * 2) else { return nil }
                out.append((g, i))
            }
        case 2:
            guard walk.spend(Int(count)) else { return nil }
            for i in 0..<Int(count) {
                let r = offset + 4 + i * 6
                guard let start = gsub.u16(r), let end = gsub.u16(r + 2), let first = gsub.u16(r + 4), end >= start,
                      walk.spend(Int(end - start) + 1) else { return nil }
                for g in start...end { out.append((g, Int(first) + Int(g - start))) }
            }
        default:
            return nil
        }
        return out
    }

    private func single(at offset: Int, _ walk: inout Walk) -> Parsed {
        guard let format = gsub.u16(offset), let covOffset = gsub.u16(offset + 2),
              let cov = coverage(at: offset + Int(covOffset), &walk) else { return nil }
        var out: [GSUBRule] = []
        switch format {
        case 1:
            guard let delta = gsub.u16(offset + 4) else { return nil }
            for (g, _) in cov {
                out.append(GSUBRule(kind: .single, input: [g], outputs: [[g &+ delta]]))
            }
        case 2:
            guard let count = gsub.u16(offset + 4) else { return nil }
            for (g, index) in cov {
                guard index < Int(count), let sub = gsub.u16(offset + 6 + index * 2) else { return nil }
                out.append(GSUBRule(kind: .single, input: [g], outputs: [[sub]]))
            }
        default:
            return nil
        }
        return out
    }

    /// Glyph array at `offset`: a count, then that many glyph IDs.
    private func glyphArray(at offset: Int, _ walk: inout Walk) -> [UInt16]? {
        guard let count = gsub.u16(offset), walk.spend(Int(count) + 1) else { return nil }
        var out: [UInt16] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            guard let g = gsub.u16(offset + 2 + i * 2) else { return nil }
            out.append(g)
        }
        return out
    }

    /// Multiple (2) and alternate (3) substitution: per covered glyph, a glyph array.
    private func sequences(at offset: Int, kind: GSUBRule.Kind, _ walk: inout Walk) -> Parsed {
        guard gsub.u16(offset) == 1, let covOffset = gsub.u16(offset + 2), let count = gsub.u16(offset + 4),
              let cov = coverage(at: offset + Int(covOffset), &walk) else { return nil }
        var out: [GSUBRule] = []
        for (g, index) in cov {
            guard index < Int(count), let setOffset = gsub.u16(offset + 6 + index * 2),
                  let glyphs = glyphArray(at: offset + Int(setOffset), &walk) else { return nil }
            out.append(GSUBRule(kind: kind, input: [g], outputs: kind == .multiple ? [glyphs] : glyphs.map { [$0] }))
        }
        return out
    }

    private func ligatures(at offset: Int, _ walk: inout Walk) -> Parsed {
        guard gsub.u16(offset) == 1, let covOffset = gsub.u16(offset + 2), let setCount = gsub.u16(offset + 4),
              let cov = coverage(at: offset + Int(covOffset), &walk) else { return nil }
        var out: [GSUBRule] = []
        for (first, index) in cov {
            guard index < Int(setCount), let setOffset = gsub.u16(offset + 6 + index * 2),
                  case let set = offset + Int(setOffset), let count = gsub.u16(set), walk.spend(Int(count) + 1)
            else { return nil }
            for k in 0..<Int(count) {
                guard let ligOffset = gsub.u16(set + 2 + k * 2), case let lig = set + Int(ligOffset),
                      let glyph = gsub.u16(lig), let components = gsub.u16(lig + 2), components >= 1,
                      walk.spend(Int(components))
                else { return nil }
                var input = [first]
                for c in 0..<Int(components) - 1 {
                    guard let g = gsub.u16(lig + 4 + c * 2) else { return nil }
                    input.append(g)
                }
                out.append(GSUBRule(kind: .ligature, input: input, outputs: [[glyph]]))
            }
        }
        return out
    }
}
