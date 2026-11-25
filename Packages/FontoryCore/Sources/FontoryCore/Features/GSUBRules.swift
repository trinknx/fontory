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
        var groups: [[GSUBRule]] = []
        for index in lookups.sorted() {
            if walk.exhausted { break }
            walk.emitted = []
            groups.append(lookupRules(index, depth: 0, &walk))
        }
        var composeSteps = budget
        let rules = Self.compose(groups, steps: &composeSteps)
        if composeSteps < 0 { walk.exhausted = true }
        return walk.result(rules)
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

    /// The state of one feature's walk: budget, failures, and the nested lookups of contextual lookups.
    struct Walk {
        var budget: Int
        var failed = false
        var exhausted = false
        /// Some nested lookup was deeper than `maxNesting` and not read.
        var truncated = false
        /// Rules of nested lookups (already flagged contextual), by lookup index; each is parsed once.
        var nested: [Int: [GSUBRule]] = [:]
        /// Nested lookups being read, to stop cycles.
        var active = Set<Int>()
        /// Nested lookups already emitted for the lookup being read, so one lookup lists them once.
        var emitted = Set<Int>()

        init(budget: Int) { self.budget = budget }

        /// Counts `n` steps; false (and `exhausted`) once the budget is spent.
        mutating func spend(_ n: Int) -> Bool {
            budget -= n
            if budget < 0 { exhausted = true }
            return !exhausted
        }

        /// The final list: distinct rules in first-seen order, capped at `listLimit`.
        func result(_ all: [GSUBRule]) -> GSUBFeatureRules {
            var seen = Set<GSUBRule>()
            var rules: [GSUBRule] = []
            for r in all where seen.insert(r).inserted && rules.count < GSUBFeatureRules.listLimit { rules.append(r) }
            return GSUBFeatureRules(rules: rules, totalCount: seen.count, isIncomplete: failed || exhausted || truncated,
                                    isUnreadable: seen.isEmpty && failed)
        }
    }

    /// Nested lookups deeper than this are not read.
    static let maxNesting = 8

    /// A subtable's rules, or nil when it is malformed (it then contributes nothing).
    private typealias Parsed = [GSUBRule]?

    /// The rules of LookupList entry `index`. An unreadable lookup or subtable sets `failed` and contributes nothing.
    private func lookupRules(_ index: Int, depth: Int, _ walk: inout Walk) -> [GSUBRule] {
        guard index < lookupCount, walk.spend(1), let offset = gsub.u16(lookupList + 2 + index * 2),
              case let lookup = lookupList + Int(offset), let type = gsub.u16(lookup),
              let count = gsub.u16(lookup + 4), walk.spend(Int(count)) else {
            if !walk.exhausted { walk.failed = true }
            return []
        }
        var out: [GSUBRule] = []
        for i in 0..<Int(count) {
            guard let sub = gsub.u16(lookup + 6 + i * 2) else { walk.failed = true; return out }
            if let rules = readSubtable(type: Int(type), at: lookup + Int(sub), depth: depth, &walk, extensionDepth: 0) {
                out += rules
            } else if !walk.exhausted {
                // A nil caused by the budget running out is incompleteness, not a malformed lookup.
                walk.failed = true
            }
            if walk.exhausted { return out }
        }
        return out
    }

    /// Dispatches on the lookup type. Contextual types (5, 6) list the rules of the lookups they call; 8 lists
    /// its own singles. All of these are flagged contextual. Unknown types contribute nothing.
    private func readSubtable(type: Int, at offset: Int, depth: Int, _ walk: inout Walk, extensionDepth: Int) -> Parsed {
        switch type {
        case 1: return single(at: offset, &walk)
        case 2: return sequences(at: offset, kind: .multiple, &walk)
        case 3: return sequences(at: offset, kind: .alternate, &walk)
        case 4: return ligatures(at: offset, &walk)
        case 5, 6:
            guard let calls = type == 5 ? contextCalls(at: offset, &walk) : chainCalls(at: offset, &walk)
            else { return nil }
            var out: [GSUBRule] = []
            for index in calls {
                guard let rules = nestedRules(index, depth: depth + 1, &walk) else { return nil }
                out += rules
            }
            return out
        case 7:
            // Extension: format 1, wrapped type, 32-bit offset from this subtable. Nesting is not allowed.
            guard extensionDepth == 0, gsub.u16(offset) == 1, let inner = gsub.u16(offset + 2),
                  let delta = gsub.u32(offset + 4), delta <= UInt32(Int32.max) else { return nil }
            return readSubtable(type: Int(inner), at: offset + Int(delta), depth: depth, &walk, extensionDepth: 1)
        case 8: return reverseChain(at: offset, &walk)
        default: return []
        }
    }

    /// The rules of a lookup called from a contextual lookup, flagged contextual. Each nested lookup is parsed
    /// once per feature; listing it again still costs one step per rule. A lookup already being read (a cycle),
    /// or already listed for the current lookup, gives nothing. nil: the budget ran out.
    private func nestedRules(_ index: Int, depth: Int, _ walk: inout Walk) -> [GSUBRule]? {
        guard walk.emitted.insert(index).inserted else { return [] }
        guard depth <= Self.maxNesting else { walk.truncated = true; return [] }
        let rules: [GSUBRule]
        if let cached = walk.nested[index] {
            rules = cached
        } else {
            guard walk.active.insert(index).inserted else { return [] }
            let outer = walk.emitted
            walk.emitted = []
            rules = lookupRules(index, depth: depth, &walk).map {
                GSUBRule(kind: $0.kind, input: $0.input, outputs: $0.outputs, isContextual: true)
            }
            walk.emitted = outer
            walk.active.remove(index)
            if walk.exhausted { return nil }
            walk.nested[index] = rules
        }
        return walk.spend(rules.count) ? rules : nil
    }

    // MARK: Contextual subtables

    /// The lookup indices of `count` SubstLookupRecords (sequence index, lookup index) at `offset`.
    private func lookupRecords(at offset: Int, count: Int, _ walk: inout Walk) -> [Int]? {
        guard walk.spend(count) else { return nil }
        var out: [Int] = []
        for i in 0..<count {
            guard gsub.u16(offset + i * 4) != nil, let index = gsub.u16(offset + i * 4 + 2) else { return nil }
            out.append(Int(index))
        }
        return out
    }

    /// A ClassDef table's header is readable and of format 1 or 2. Classes themselves are not shown.
    private func classDefIsValid(at offset: Int) -> Bool {
        guard let format = gsub.u16(offset) else { return false }
        switch format {
        case 1: return gsub.u16(offset + 4) != nil
        case 2: return gsub.u16(offset + 2) != nil
        default: return false
        }
    }

    /// Offsets `count` u16 offsets at `offset` are all readable.
    private func offsetsReadable(at offset: Int, count: Int, _ walk: inout Walk) -> Bool {
        guard walk.spend(count) else { return false }
        return (0..<count).allSatisfy { gsub.u16(offset + $0 * 2) != nil }
    }

    /// Rule sets (formats 1 and 2 of types 5 and 6): `count` offsets at `offset`, from `base`; null sets are
    /// skipped. Each rule's lookup indices come from `rule(at:)`.
    private func ruleSets(base: Int, countAt offset: Int, _ walk: inout Walk,
                          rule: (Int, inout Walk) -> [Int]?) -> [Int]? {
        guard let count = gsub.u16(offset), walk.spend(Int(count)) else { return nil }
        var calls: [Int] = []
        for i in 0..<Int(count) {
            guard let setOffset = gsub.u16(offset + 2 + i * 2) else { return nil }
            if setOffset == 0 { continue }
            let set = base + Int(setOffset)
            guard let rules = gsub.u16(set), walk.spend(Int(rules)) else { return nil }
            for k in 0..<Int(rules) {
                guard let ruleOffset = gsub.u16(set + 2 + k * 2), let found = rule(set + Int(ruleOffset), &walk)
                else { return nil }
                calls += found
            }
        }
        return calls
    }

    /// Context substitution (5), formats 1–3: the lookups it calls.
    private func contextCalls(at offset: Int, _ walk: inout Walk) -> [Int]? {
        // SequenceRule / ClassSequenceRule: glyphCount, seqLookupCount, inputSequence[glyphCount - 1], records.
        func rule(_ r: Int, _ walk: inout Walk) -> [Int]? {
            guard let glyphs = gsub.u16(r), glyphs >= 1, let records = gsub.u16(r + 2) else { return nil }
            return lookupRecords(at: r + 4 + (Int(glyphs) - 1) * 2, count: Int(records), &walk)
        }
        switch gsub.u16(offset) {
        case 1:
            return ruleSets(base: offset, countAt: offset + 4, &walk, rule: rule)
        case 2:
            guard let classDef = gsub.u16(offset + 4), classDef != 0, classDefIsValid(at: offset + Int(classDef))
            else { return nil }
            return ruleSets(base: offset, countAt: offset + 6, &walk, rule: rule)
        case 3:
            guard let glyphs = gsub.u16(offset + 2), glyphs >= 1, let records = gsub.u16(offset + 4),
                  offsetsReadable(at: offset + 6, count: Int(glyphs), &walk) else { return nil }
            return lookupRecords(at: offset + 6 + Int(glyphs) * 2, count: Int(records), &walk)
        default:
            return nil
        }
    }

    /// Chained context substitution (6), formats 1–3: the lookups it calls.
    private func chainCalls(at offset: Int, _ walk: inout Walk) -> [Int]? {
        // ChainedSequenceRule: backtrack count + glyphs, input count + glyphs (count - 1), lookahead count +
        // glyphs, seqLookupCount, records.
        func rule(_ r: Int, _ walk: inout Walk) -> [Int]? {
            guard let back = gsub.u16(r), case let p1 = r + 2 + Int(back) * 2,
                  let input = gsub.u16(p1), input >= 1, case let p2 = p1 + 2 + (Int(input) - 1) * 2,
                  let ahead = gsub.u16(p2), case let p3 = p2 + 2 + Int(ahead) * 2,
                  let records = gsub.u16(p3), walk.spend(Int(back) + Int(input) + Int(ahead)) else { return nil }
            return lookupRecords(at: p3 + 2, count: Int(records), &walk)
        }
        switch gsub.u16(offset) {
        case 1:
            return ruleSets(base: offset, countAt: offset + 4, &walk, rule: rule)
        case 2:
            // Backtrack, input and lookahead ClassDefs; only the input one is required.
            for (k, required) in [(4, false), (6, true), (8, false)] {
                guard let classDef = gsub.u16(offset + k) else { return nil }
                if classDef == 0 { if required { return nil } else { continue } }
                guard classDefIsValid(at: offset + Int(classDef)) else { return nil }
            }
            return ruleSets(base: offset, countAt: offset + 10, &walk, rule: rule)
        case 3:
            guard let back = gsub.u16(offset + 2), offsetsReadable(at: offset + 4, count: Int(back), &walk),
                  case let p1 = offset + 4 + Int(back) * 2, let input = gsub.u16(p1), input >= 1,
                  offsetsReadable(at: p1 + 2, count: Int(input), &walk), case let p2 = p1 + 2 + Int(input) * 2,
                  let ahead = gsub.u16(p2), offsetsReadable(at: p2 + 2, count: Int(ahead), &walk),
                  case let p3 = p2 + 2 + Int(ahead) * 2, let records = gsub.u16(p3) else { return nil }
            return lookupRecords(at: p3 + 2, count: Int(records), &walk)
        default:
            return nil
        }
    }

    /// Reverse chaining single substitution (8): coverage glyph → substitute, flagged contextual.
    private func reverseChain(at offset: Int, _ walk: inout Walk) -> Parsed {
        guard gsub.u16(offset) == 1, let covOffset = gsub.u16(offset + 2),
              let back = gsub.u16(offset + 4), offsetsReadable(at: offset + 6, count: Int(back), &walk),
              case let p1 = offset + 6 + Int(back) * 2, let ahead = gsub.u16(p1),
              offsetsReadable(at: p1 + 2, count: Int(ahead), &walk), case let p2 = p1 + 2 + Int(ahead) * 2,
              let count = gsub.u16(p2), let cov = coverage(at: offset + Int(covOffset), &walk) else { return nil }
        var out: [GSUBRule] = []
        for (g, index) in cov {
            guard index < Int(count), let sub = gsub.u16(p2 + 2 + index * 2) else { return nil }
            out.append(GSUBRule(kind: .single, input: [g], outputs: [[sub]], isContextual: true))
        }
        return out
    }

    // MARK: Composition

    /// Composes chains inside one feature. `groups` are the rules of each lookup, in lookup order. Each output of
    /// a non-contextual single or alternate rule is passed through the non-contextual singles of later lookups,
    /// in order; a later single that was composed this way (its input was the earlier rule's output) is dropped.
    /// Contextual rules are never composed or dropped. Each step through a later lookup costs one of `steps`;
    /// when they run out, the remaining outputs are left as they are.
    static func compose(_ groups: [[GSUBRule]], steps: inout Int) -> [GSUBRule] {
        // Per glyph, the later lookups that substitute it singly: (group, output), in group order. Within one
        // lookup the first subtable covering a glyph wins.
        var singles: [CGGlyph: [(group: Int, output: CGGlyph)]] = [:]
        for (k, group) in groups.enumerated() {
            var inGroup = Set<CGGlyph>()
            for r in group where !r.isContextual && r.kind == .single && r.outputs.count == 1 && r.outputs[0].count == 1 {
                if inGroup.insert(r.input[0]).inserted { singles[r.input[0], default: []].append((k, r.outputs[0][0])) }
            }
        }
        if singles.isEmpty { return groups.flatMap { $0 } }

        var dropped = Set<Int>()  // group << 16 | input glyph
        var out: [GSUBRule] = []
        for (k, group) in groups.enumerated() {
            for r in group {
                guard !r.isContextual, r.kind == .single || r.kind == .alternate else { out.append(r); continue }
                if r.kind == .single, dropped.contains(k << 16 | Int(r.input[0])) { continue }
                var outputs = r.outputs
                for o in outputs.indices where outputs[o].count == 1 {
                    var glyph = outputs[o][0], after = k
                    while steps > 0, let next = singles[glyph]?.first(where: { $0.group > after }) {
                        steps -= 1
                        dropped.insert(next.group << 16 | Int(glyph))
                        glyph = next.output
                        after = next.group
                    }
                    if steps <= 0, singles[glyph]?.contains(where: { $0.group > after }) == true { steps = -1 }
                    outputs[o] = [glyph]
                }
                out.append(GSUBRule(kind: r.kind, input: r.input, outputs: outputs))
            }
        }
        return out
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
