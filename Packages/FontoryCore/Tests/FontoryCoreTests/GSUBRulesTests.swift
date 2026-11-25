import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

private func be(_ v: [Int]) -> [UInt8] { v.flatMap { [UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] } }

private func cov1(_ glyphs: [Int]) -> [UInt8] { be([1, glyphs.count] + glyphs) }
private func cov2(_ start: Int, _ end: Int) -> [UInt8] { be([2, 1, start, end, 0]) }

private func single1(_ cov: [UInt8], delta: Int) -> [UInt8] { be([1, 6, delta]) + cov }
private func single2(_ glyphs: [Int], _ subs: [Int]) -> [UInt8] {
    be([2, 6 + 2 * subs.count, subs.count] + subs) + cov1(glyphs)
}
/// Multiple (2) or alternate (3) substitution of one glyph.
private func sequence(_ glyph: Int, _ out: [Int]) -> [UInt8] {
    let c = cov1([glyph])
    return be([1, 8, 1, 8 + c.count]) + c + be([out.count] + out)
}
private func ligatures(first: Int, _ ligs: [(glyph: Int, rest: [Int])]) -> [UInt8] {
    let c = cov1([first])
    var set = be([ligs.count])
    var bodies: [UInt8] = []
    let head = 2 + 2 * ligs.count
    for l in ligs {
        set += be([head + bodies.count])
        bodies += be([l.glyph, l.rest.count + 1] + l.rest)
    }
    return be([1, 8, 1, 8 + c.count]) + c + set + bodies
}
private func extensionOf(_ type: Int, _ inner: [UInt8]) -> [UInt8] { be([1, type, 0, 8]) + inner }

/// Chained context (6) format 3; `calls` are the nested lookups, each applied at sequence index 0.
private func chain3(backtrack: [[Int]] = [], input: [[Int]], lookahead: [[Int]] = [], calls: [Int]) -> [UInt8] {
    let covs = (backtrack + input + lookahead).map(cov1)
    var offsets: [Int] = []
    var pos = 2 * (5 + covs.count + 2 * calls.count)
    for c in covs { offsets.append(pos); pos += c.count }
    let b = backtrack.count, i = input.count
    var head = [3, b] + offsets[0..<b] + [i] + offsets[b..<b + i] + [lookahead.count] + offsets[(b + i)...]
    head += [calls.count] + calls.flatMap { [0, $0] }
    return be(head) + covs.flatMap { $0 }
}
/// Context (5) format 1: one rule set for `glyph`, one single-glyph rule calling `call`.
private func context1(_ glyph: Int, call: Int) -> [UInt8] {
    let c = cov1([glyph])
    return be([1, 8, 1, 8 + c.count]) + c + be([1, 4]) + be([1, 1, 0, call])
}
/// Context (5) format 2: ClassDef format 2 puts `glyph` in class 1; class 1's rule calls `call`.
private func context2(_ glyph: Int, call: Int) -> [UInt8] {
    let c = cov1([glyph])
    let classDef = be([2, 1, glyph, glyph, 1])
    let set = 12 + c.count + classDef.count
    return be([2, 12, 12 + c.count, 2, 0, set]) + c + classDef + be([1, 4]) + be([1, 1, 0, call])
}
/// Reverse chaining single (8) with no backtrack or lookahead.
private func reverse(_ glyphs: [Int], _ subs: [Int]) -> [UInt8] {
    be([1, 10 + 2 * subs.count, 0, 0, subs.count] + subs) + cov1(glyphs)
}
private let filler = lookup(1, [single1(cov1([1]), delta: 1)])

/// One lookup; a nil subtable list makes the lookup's offset point past the table.
private func lookup(_ type: Int, _ subs: [[UInt8]]) -> [UInt8] {
    var head = be([type, 0, subs.count])
    var bodies: [UInt8] = []
    let base = 6 + 2 * subs.count
    for s in subs { head += be([base + bodies.count]); bodies += s }
    return head + bodies
}

/// A GSUB with one script (DFLT, default LangSys listing every feature), the given features and lookups.
private func gsub(features: [(String, [Int])], lookups: [[UInt8]?]) -> [UInt8] {
    var scriptList = be([1]) + Array("DFLT".utf8) + be([8])
    scriptList += be([4, 0]) + be([0, 0xFFFF, features.count] + Array(0..<features.count))
    var featureList = be([features.count])
    var tables: [UInt8] = []
    let tablesStart = 2 + 6 * features.count
    for (tag, ls) in features {
        featureList += Array(tag.utf8) + be([tablesStart + tables.count])
        tables += be([0, ls.count] + ls)
    }
    featureList += tables
    var lookupList = be([lookups.count])
    var bodies: [UInt8] = []
    let base = 2 + 2 * lookups.count
    for l in lookups {
        if let l { lookupList += be([base + bodies.count]); bodies += l } else { lookupList += be([0x7000]) }
    }
    lookupList += bodies
    let sl = 10, fl = sl + scriptList.count, ll = fl + featureList.count
    return be([1, 0, sl, fl, ll]) + scriptList + featureList + lookupList
}

private func reader(_ features: [(String, [Int])], _ lookups: [[UInt8]?]) -> GSUBRuleReader? {
    GSUBRuleReader(gsub: SfntReader(bytes: gsub(features: features, lookups: lookups)))
}

private let ss02Inner = single1(cov1([5, 6]), delta: 10)

private func standard(extra: [[UInt8]?] = []) -> GSUBRuleReader? {
    reader([("ss01", [0]), ("liga", [1]), ("salt", [2]), ("ccmp", [3]), ("ss02", [4])], [
        lookup(1, [single1(cov1([5, 6]), delta: 10), single2([7], [40])]),
        lookup(4, [ligatures(first: 3, [(50, [4]), (51, [4, 5])])]),
        lookup(3, [sequence(8, [60, 61, 62])]),
        lookup(2, [sequence(9, [70, 71])]),
        lookup(7, [extensionOf(1, ss02Inner)]),
    ])
}

@Suite struct GSUBRulesTests {
    @Test func singleFormat1And2() throws {
        let r = try #require(standard())
        let got = r.rules(for: "ss01", selection: .all)
        #expect(got.rules == [
            GSUBRule(kind: .single, input: [5], outputs: [[15]]),
            GSUBRule(kind: .single, input: [6], outputs: [[16]]),
            GSUBRule(kind: .single, input: [7], outputs: [[40]]),
        ])
        #expect(!got.isIncomplete && !got.isUnreadable)
    }

    @Test func ligatureRules() throws {
        let got = try #require(standard()).rules(for: "liga", selection: .all)
        #expect(got.rules == [
            GSUBRule(kind: .ligature, input: [3, 4], outputs: [[50]]),
            GSUBRule(kind: .ligature, input: [3, 4, 5], outputs: [[51]]),
        ])
    }

    @Test func alternateRules() throws {
        let got = try #require(standard()).rules(for: "salt", selection: .all)
        #expect(got.rules == [GSUBRule(kind: .alternate, input: [8], outputs: [[60], [61], [62]])])
    }

    @Test func multipleRules() throws {
        let got = try #require(standard()).rules(for: "ccmp", selection: .all)
        #expect(got.rules == [GSUBRule(kind: .multiple, input: [9], outputs: [[70, 71]])])
    }

    @Test func extensionIsUnwrapped() throws {
        let r = try #require(standard())
        let wrapped = r.rules(for: "ss02", selection: .all)
        let plain = try #require(reader([("ss03", [0])], [lookup(1, [ss02Inner])]))
        #expect(wrapped == plain.rules(for: "ss03", selection: .all))
        #expect(wrapped.totalCount == 2)
    }

    @Test func duplicateRulesListedOnce() throws {
        let r = try #require(reader([("ss01", [0, 0])], [lookup(1, [single1(cov1([5, 6]), delta: 10), single2([7], [40])])]))
        let got = r.rules(for: "ss01", selection: .all)
        #expect(got.totalCount == 3 && got.rules.count == 3)
    }

    @Test func countsBySelection() throws {
        let r = try #require(standard())
        #expect(r.counts(selection: .all) == ["ss01": 3, "liga": 2, "salt": 1, "ccmp": 1, "ss02": 2])
        // The only script is DFLT, which any other script falls back to.
        #expect(r.counts(selection: .languageSystem(script: "latn", language: nil)) == r.counts(selection: .all))
    }

    @Test func listLimitCapsRules() throws {
        let r = try #require(reader([("ss01", [0])], [lookup(1, [single1(cov2(0, 2499), delta: 1)])]))
        let got = r.rules(for: "ss01", selection: .all)
        #expect(got.rules.count == 2000 && got.totalCount == 2500)
    }

    @Test func truncatedLookupIsIncomplete() throws {
        let r = try #require(reader([("ss01", [0]), ("liga", [1])], [
            nil, lookup(4, [ligatures(first: 3, [(50, [4])])]),
        ]))
        let bad = r.rules(for: "ss01", selection: .all)
        #expect(bad.isUnreadable && bad.isIncomplete && bad.rules.isEmpty)
        let good = r.rules(for: "liga", selection: .all)
        #expect(!good.isUnreadable && good.totalCount == 1)
        #expect(r.counts(selection: .all) == ["liga": 1])
    }

    @Test func budgetExhaustionIsIncomplete() throws {
        let r = try #require(reader([("ss01", [0])], [lookup(1, [single1(cov2(0, 2499), delta: 1)])]))
        let got = r.rules(for: "ss01", selection: .all, budget: 100)
        #expect(got.isIncomplete && !got.isUnreadable)
    }

    // MARK: Contextual lookups and composition

    @Test func chainedContextFormat3CallsNestedLookup() throws {
        let lookups = Array(repeating: filler, count: 5) + [lookup(6, [chain3(input: [[10]], calls: [6])]),
                                                           lookup(1, [single2([10], [80])])]
        let got = try #require(reader([("calt", [5])], lookups)).rules(for: "calt", selection: .all)
        #expect(got.rules == [GSUBRule(kind: .single, input: [10], outputs: [[80]], isContextual: true)])
        #expect(!got.isIncomplete)
    }

    @Test func contextFormat1And2() throws {
        let r = try #require(reader([("calt", [0, 1])], [
            lookup(5, [context1(10, call: 2)]), lookup(5, [context2(11, call: 3)]),
            lookup(1, [single2([10], [80])]), lookup(1, [single2([11], [81])]),
        ]))
        let got = r.rules(for: "calt", selection: .all)
        #expect(got.rules == [
            GSUBRule(kind: .single, input: [10], outputs: [[80]], isContextual: true),
            GSUBRule(kind: .single, input: [11], outputs: [[81]], isContextual: true),
        ])
        #expect(!got.isIncomplete)
    }

    @Test func reverseChaining() throws {
        let got = try #require(reader([("rclt", [0])], [lookup(8, [reverse([11, 12], [90, 91])])]))
            .rules(for: "rclt", selection: .all)
        #expect(got.rules == [
            GSUBRule(kind: .single, input: [11], outputs: [[90]], isContextual: true),
            GSUBRule(kind: .single, input: [12], outputs: [[91]], isContextual: true),
        ])
    }

    @Test(.timeLimit(.minutes(1))) func nestedLookupCycleTerminates() throws {
        let r = try #require(reader([("calt", [0])], [
            lookup(6, [chain3(input: [[10]], calls: [1])]), lookup(6, [chain3(input: [[10]], calls: [0])]),
        ]))
        let got = r.rules(for: "calt", selection: .all)
        #expect(got.rules.allSatisfy { $0.isContextual })
    }

    @Test(.timeLimit(.minutes(1))) func budgetStopsLargeFeature() throws {
        let callers = Array(repeating: lookup(6, [chain3(input: [[1]], calls: [200])]), count: 200)
        let r = try #require(reader([("calt", Array(0..<200))], callers + [lookup(1, [single1(cov2(0, 1999), delta: 1)])]))
        let got = r.rules(for: "calt", selection: .all, budget: 10_000)
        #expect(got.isIncomplete)
        #expect(got.rules.count > 0)
    }

    private func chains() -> GSUBRuleReader? {
        reader([("ss03", [20, 21]), ("ss04", [22, 23])], Array(repeating: filler, count: 20) + [
            lookup(1, [single2([30], [31])]), lookup(1, [single2([31, 33], [32, 34])]),
            lookup(3, [sequence(40, [41, 42])]), lookup(1, [single2([42], [43])]),
        ])
    }

    @Test func chainsAreComposed() throws {
        let got = try #require(chains()).rules(for: "ss03", selection: .all)
        #expect(got.rules == [
            GSUBRule(kind: .single, input: [30], outputs: [[32]]),
            GSUBRule(kind: .single, input: [33], outputs: [[34]]),
        ])
        #expect(got.totalCount == 2)
    }

    @Test func alternatesAreComposedPerOutput() throws {
        let got = try #require(chains()).rules(for: "ss04", selection: .all)
        #expect(got.rules == [GSUBRule(kind: .alternate, input: [40], outputs: [[41], [43]])])
    }

    @Test func realFontHasRules() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.sfns), faceIndex: 0, size: 12))
        let r = try #require(GSUBRuleReader.read(font))
        let counts = r.counts(selection: .all)
        #expect(counts.contains { ($0.key.hasPrefix("ss") || $0.key.hasPrefix("cv")) && $0.value > 0 })
    }
}
