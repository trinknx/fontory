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
        #expect(got.isIncomplete)
    }

    @Test func realFontHasRules() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.sfns), faceIndex: 0, size: 12))
        let r = try #require(GSUBRuleReader.read(font))
        let counts = r.counts(selection: .all)
        #expect(counts.contains { ($0.key.hasPrefix("ss") || $0.key.hasPrefix("cv")) && $0.value > 0 })
    }
}
