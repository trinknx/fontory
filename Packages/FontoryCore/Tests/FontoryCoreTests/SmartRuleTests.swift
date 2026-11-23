import Foundation
import Testing
@testable import FontoryCore

@Suite struct SmartRuleTests {
    typealias C = SmartRule.Condition

    private func rule(_ conds: [C], match: SmartRule.Match = .all, inverted: Bool = false) -> SmartRule {
        var r = SmartRule(); r.match = match; r.inverted = inverted; r.conditions = conds
        return r
    }
    private func c(_ f: SmartRule.Field, _ op: SmartRule.Op, _ v: SmartRule.Value = .none) -> C { C(field: f, op: op, value: v) }

    private func names(_ f: Fixture, _ r: SmartRule, includeSystem: Bool = true) throws -> Set<String> {
        let ids = try f.store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: 0, rule: r)]), includeSystem: includeSystem))
        let inv = Dictionary(uniqueKeysWithValues: f.faceIDs.map { ($0.value, $0.key) })
        return Set(ids.map { inv[$0]! })
    }
    private func sql(_ f: Fixture, _ statement: String) throws {
        try f.store.database.withLock { try f.store.database.execute(statement) }
    }
    private func id(_ f: Fixture, _ ps: String) -> Int64 { f.faceIDs[ps]! }

    @Test func jsonRoundTrip() throws {
        let r = rule([c(.name, .contains, .text("é\"x")), c(.weight, .between, .range(0.1, 0.5)), c(.tag, .has, .int(7)), c(.italic, .yes)],
                     match: .any, inverted: true)
        let back = try #require(SmartRule.decode(r.encoded()))
        #expect(back == r)
        #expect(SmartRule.decode("not json") == nil)
        #expect(SmartRule.decode("{\"conditions\":[{\"field\":\"bogus\",\"op\":\"is\",\"value\":null}]}") == nil)
        #expect(SmartRule.decode("{}") == SmartRule())
    }

    @Test func nameCondition() throws {
        let f = try Fixture.make()
        #expect(try names(f, rule([c(.name, .contains, .text("ALPHA b"))])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.name, .is, .text("beta light"))])) == ["Beta-Light"])
        #expect(try names(f, rule([c(.name, .startsWith, .text("beta"))])) == ["Beta-Light", "Beta-Regular", "Beta-Black"])
        #expect(try names(f, rule([c(.name, .startsWith, .text("lpha"))])).isEmpty)
    }

    @Test func textFoldsNonASCIIAndEscapesWildcards() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE faces SET full_name = 'Élan 100%_x' WHERE id = \(id(f, "Alpha-Bold"))")
        try sql(f, "UPDATE faces SET full_name = 'Élan 100abx' WHERE id = \(id(f, "Alpha-Italic"))")
        #expect(try names(f, rule([c(.name, .contains, .text("éLAN"))])) == ["Alpha-Bold", "Alpha-Italic"])
        #expect(try names(f, rule([c(.name, .contains, .text("100%_"))])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.name, .startsWith, .text("%"))])).isEmpty)
        #expect(try names(f, rule([c(.name, .is, .text("élan 100%_X"))])) == ["Alpha-Bold"])
    }

    @Test func familyCondition() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE faces SET custom_family = 'Gamma' WHERE id = \(id(f, "Alpha-Bold"))")
        #expect(try names(f, rule([c(.family, .is, .text("gamma"))])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.family, .is, .text("alpha"))])) == ["Alpha-Regular", "Alpha-Italic"])
        #expect(try names(f, rule([c(.family, .contains, .text("et"))])) == ["Beta-Light", "Beta-Regular", "Beta-Black"])
    }

    @Test func styleNameCondition() throws {
        let f = try Fixture.make()
        #expect(try names(f, rule([c(.styleName, .is, .text("regular"))])) == ["Alpha-Regular", "Beta-Regular"])
        #expect(try names(f, rule([c(.styleName, .startsWith, .text("bl"))])) == ["Beta-Black"])
    }

    @Test func foundryAndDesignerConditions() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE faces SET vendor = 'Ödd Foundry', designer = 'Ann Lee' WHERE id = \(id(f, "Alpha-Bold"))")
        try sql(f, "UPDATE faces SET designer = 'Lee Ann' WHERE id = \(id(f, "Beta-Black"))")
        #expect(try names(f, rule([c(.foundry, .contains, .text("öDD"))])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.foundry, .is, .text("x"))])).isEmpty)   // NULL vendor never matches
        #expect(try names(f, rule([c(.designer, .contains, .text("lee"))])) == ["Alpha-Bold", "Beta-Black"])
        #expect(try names(f, rule([c(.designer, .startsWith, .text("lee"))])) == ["Beta-Black"])
        #expect(try names(f, rule([c(.designer, .is, .text("ann lee"))])) == ["Alpha-Bold"])
    }

    @Test func styleClassCondition() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE faces SET style_class = \(StyleClass.slab.rawValue) WHERE id IN (\(id(f, "Alpha-Bold")), \(id(f, "Beta-Black")))")
        let slab = SmartRule.Value.int(Int64(StyleClass.slab.rawValue))
        #expect(try names(f, rule([c(.styleClass, .is, slab)])) == ["Alpha-Bold", "Beta-Black"])
        #expect(try names(f, rule([c(.styleClass, .isNot, slab)])).count == 4)
    }

    @Test func tagCondition() throws {
        let f = try Fixture.make()
        let s = f.store
        let parent = try s.createTag(name: "P", parentID: nil)
        let child = try s.createTag(name: "C", parentID: parent)
        try s.addTag(parent, toFaces: [id(f, "Alpha-Bold")])
        try s.addTag(child, toFaces: [id(f, "Beta-Light")])
        #expect(try names(f, rule([c(.tag, .has, .int(parent))])) == ["Alpha-Bold", "Beta-Light"])   // descendants included
        #expect(try names(f, rule([c(.tag, .has, .int(child))])) == ["Beta-Light"])
        #expect(try names(f, rule([c(.tag, .hasNot, .int(parent))])).count == 4)
    }

    @Test func activationCondition() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE faces SET activation = 1 WHERE id = \(id(f, "Alpha-Bold"))")
        #expect(try names(f, rule([c(.activation, .yes)])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.activation, .no)])).count == 5)
        let viaScope = try f.store.faceIDs(for: LibraryQuery(scope: .activated))
        #expect(Set(viaScope) == [id(f, "Alpha-Bold")])
    }

    @Test func booleanConditions() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE faces SET is_variable = 1 WHERE id = \(id(f, "Beta-Light"))")
        try sql(f, "UPDATE faces SET is_color = 1 WHERE id = \(id(f, "Beta-Black"))")
        try f.store.setNote("hello", faceID: id(f, "Alpha-Bold"))
        #expect(try names(f, rule([c(.variable, .yes)])) == ["Beta-Light"])
        #expect(try names(f, rule([c(.variable, .no)])).count == 5)
        #expect(try names(f, rule([c(.italic, .yes)])) == ["Alpha-Italic"])
        #expect(try names(f, rule([c(.italic, .no)])).count == 5)
        #expect(try names(f, rule([c(.color, .yes)])) == ["Beta-Black"])
        #expect(try names(f, rule([c(.color, .no)])).count == 5)
        #expect(try names(f, rule([c(.hasNote, .yes)])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.hasNote, .no)])).count == 5)
    }

    @Test func weightAndWidthConditions() throws {
        let f = try Fixture.make()
        #expect(try names(f, rule([c(.weight, .between, .range(300, 400))])) == ["Alpha-Regular", "Alpha-Italic", "Beta-Light", "Beta-Regular"])
        #expect(try names(f, rule([c(.weight, .between, .range(700, 900))])) == ["Alpha-Bold", "Beta-Black"])
        try sql(f, "UPDATE faces SET width = 2 WHERE id = \(id(f, "Beta-Regular"))")
        #expect(try names(f, rule([c(.width, .between, .range(1, 3))])) == ["Beta-Regular"])
    }

    @Test func formatAndOutlineConditions() throws {
        let f = try Fixture.make()
        try sql(f, "UPDATE files SET format = 'ttf' WHERE id = \(f.fileIDs["Beta-Light.otf"]!)")
        try sql(f, "UPDATE faces SET outline_type = 'cff' WHERE id IN (\(id(f, "Alpha-Bold")), \(id(f, "Alpha-Regular")))")
        #expect(try names(f, rule([c(.format, .is, .text("TTF"))])) == ["Beta-Light"])
        #expect(try names(f, rule([c(.format, .isNot, .text("ttf"))])).count == 5)
        #expect(try names(f, rule([c(.outlineType, .is, .text("cff"))])) == ["Alpha-Bold", "Alpha-Regular"])
        #expect(try names(f, rule([c(.outlineType, .isNot, .text("cff"))])).count == 4)
    }

    @Test func scriptCondition() throws {
        let f = try Fixture.make()
        let greek = try #require(ScriptCoverage.scripts.firstIndex { $0.name == "Greek" })
        try sql(f, "UPDATE faces SET scripts_bitmask = \(Int64(1) << Int64(greek)) | 1 WHERE id = \(id(f, "Alpha-Bold"))")
        try sql(f, "UPDATE faces SET scripts_bitmask = 1 WHERE id = \(id(f, "Beta-Black"))")
        #expect(try names(f, rule([c(.script, .has, .int(Int64(greek)))])) == ["Alpha-Bold"])
        #expect(try names(f, rule([c(.script, .has, .int(0))])) == ["Alpha-Bold", "Beta-Black"])
        #expect(try names(f, rule([c(.script, .hasNot, .int(Int64(greek)))])).count == 5)
        #expect(try names(f, rule([c(.script, .has, .int(999))])).isEmpty)
        #expect(try names(f, rule([c(.script, .has, .int(-1))])).isEmpty)
    }

    @Test func locationCondition() throws {
        let f = try Fixture.make()
        #expect(try names(f, rule([c(.location, .is, .int(f.locB.id))])) == ["Beta-Light", "Beta-Regular", "Beta-Black"])
        #expect(try names(f, rule([c(.location, .isNot, .int(f.locB.id))])).count == 3)
    }

    @Test func dateAddedCondition() throws {
        let f = try Fixture.make()
        let now = Date().timeIntervalSince1970
        try sql(f, "UPDATE files SET added_at = \(now - 10 * 86400) WHERE id = \(f.fileIDs["Alpha-Bold.otf"]!)")
        try sql(f, "UPDATE files SET added_at = \(now - 40 * 86400) WHERE id = \(f.fileIDs["Beta-Black.otf"]!)")
        #expect(try names(f, rule([c(.dateAdded, .withinDays, .int(30))])).count == 5)
        #expect(try names(f, rule([c(.dateAdded, .withinDays, .int(5))])).count == 4)
        #expect(try names(f, rule([c(.dateAdded, .withinDays, .int(60))])).count == 6)
    }

    @Test func matchAnyVsAll() throws {
        let f = try Fixture.make()
        let conds = [c(.family, .is, .text("alpha")), c(.italic, .yes)]
        #expect(try names(f, rule(conds, match: .all)) == ["Alpha-Italic"])
        #expect(try names(f, rule(conds, match: .any)) == ["Alpha-Regular", "Alpha-Italic", "Alpha-Bold"])
    }

    @Test func invertedRule() throws {
        let f = try Fixture.make()
        #expect(try names(f, rule([c(.italic, .yes)], inverted: true)).count == 5)
        #expect(try names(f, rule([c(.italic, .yes)], inverted: true)).contains("Alpha-Italic") == false)
    }

    @Test func emptyRuleMatchesAll() throws {
        let f = try Fixture.make()
        #expect(try names(f, SmartRule()).count == 6)
        #expect(SmartRule().sqlClause().sql == "1")
    }

    @Test func deletedTagMatchesNothing() throws {
        let f = try Fixture.make()
        let t = try f.store.createTag(name: "Gone", parentID: nil)
        try f.store.addTag(t, toFaces: [id(f, "Alpha-Bold")])
        try f.store.deleteTag(t)
        #expect(try names(f, rule([c(.tag, .has, .int(t))])).isEmpty)
        #expect(try names(f, rule([c(.tag, .hasNot, .int(t))])).isEmpty)
        #expect(try names(f, rule([c(.tag, .has, .int(9999))])).isEmpty)
    }

    @Test func invalidPairMatchesNothing() throws {
        let f = try Fixture.make()
        #expect(try names(f, rule([c(.italic, .contains, .text("x"))])).isEmpty)
        #expect(try names(f, rule([c(.name, .yes)])).isEmpty)
        #expect(try names(f, rule([c(.weight, .between, .text("x"))])).isEmpty)
        #expect(try names(f, rule([c(.name, .contains, .int(3))])).isEmpty)
        #expect(try names(f, rule([c(.tag, .has, .text("x"))])).isEmpty)
        #expect(try names(f, rule([c(.dateAdded, .withinDays, .none)])).isEmpty)
        #expect(try names(f, rule([c(.family, .isNot, .text("alpha"))])).isEmpty)
        // An invalid condition poisons "all" but not "any".
        #expect(try names(f, rule([c(.italic, .yes), c(.name, .yes)], match: .any)) == ["Alpha-Italic"])
    }

    @Test func smartPickInTagsScopeUnionsWithPlainTag() throws {
        let f = try Fixture.make()
        let plain = try f.store.createTag(name: "Plain", parentID: nil)
        try f.store.addTag(plain, toFaces: [id(f, "Beta-Black")])
        let smart = try f.store.createTag(name: "Smart", parentID: nil, kind: .smart, ruleJSON: rule([c(.italic, .yes)]).encoded())
        let ids = try f.store.faceIDs(for: LibraryQuery(scope: .tags([
            TagPick(tagID: plain), TagPick(tagID: smart, rule: rule([c(.italic, .yes)]))])))
        #expect(Set(ids) == [id(f, "Beta-Black"), id(f, "Alpha-Italic")])
        let inv = try f.store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: smart, inverted: true, rule: rule([c(.italic, .yes)]))])))
        #expect(inv.count == 5)
    }

    @Test func hashSearchIgnoresSmartTags() throws {
        let f = try Fixture.make()
        let smart = try f.store.createTag(name: "Smarty", parentID: nil, kind: .smart, ruleJSON: "{}")
        try sql(f, "INSERT INTO face_tags(face_id, tag_id) VALUES(\(id(f, "Alpha-Bold")), \(smart))")
        #expect(try f.store.faceIDs(for: { var q = LibraryQuery(); q.search = SearchText("#smarty"); return q }()).isEmpty)
        #expect(try f.store.faceIDs(for: { var q = LibraryQuery(); q.search = SearchText("#!smarty"); return q }()).count == 6)
    }

    @Test func smartQueryFastAt20k() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/F")
        let batch = try store.nextImportBatch()
        for file in 0..<20 {
            let faces = (0..<1000).map { Fixture.face("PS-\(file)-\($0)", family: "Fam\(file)", style: "S\($0)", weight: Double(100 + $0 % 9 * 100), italic: $0 % 5 == 0, index: $0) }
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "f\(file).ttc", size: 1, mtime: Date(), format: "ttc", fingerprint: "fp\(file)"),
                                     faces: faces, importBatch: batch)
        }
        let tag = try store.createTag(name: "T", parentID: nil)
        try store.addTag(tag, toFaces: Array(try store.faceIDs(for: LibraryQuery()).prefix(5000)))
        let r = rule([c(.name, .contains, .text("fam1")), c(.weight, .between, .range(200, 700)), c(.italic, .no),
                      c(.tag, .hasNot, .int(tag)), c(.dateAdded, .withinDays, .int(30))])
        let t = Date()
        let n = try store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: 0, rule: r)]))).count
        let ms = Date().timeIntervalSince(t) * 1000
        #expect(n > 0)
        #expect(ms < 100, "took \(ms) ms")
    }
}
