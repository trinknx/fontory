import Foundation
import Testing
@testable import FontoryCore

@Suite struct FamilyEditTests {
    private func custom(_ f: Fixture, _ ps: String) throws -> String? {
        let s = try f.store.database.prepare("SELECT custom_family FROM faces WHERE id = ?")
        defer { s.reset() }
        try s.bind([.int(f.faceIDs[ps]!)])
        #expect(try s.step())
        return s.isNull(0) ? nil : s.text(0)
    }

    private func groups(_ f: Fixture) throws -> [String: Set<Int64>] {
        Dictionary(uniqueKeysWithValues: try f.store.families(for: LibraryQuery()).map { ($0.name, Set($0.faceIDs)) })
    }

    @Test func renameSetsCustomFamilyAndGroups() throws {
        let f = try Fixture.make()
        let ids = ["Alpha-Regular", "Alpha-Italic", "Alpha-Bold"].map { f.faceIDs[$0]! }
        try f.store.setCustomFamily("  Beta  ", faceIDs: Array(ids.prefix(2)))
        var g = try groups(f)
        #expect(g["Beta"] == Set(ids.prefix(2)) .union([f.faceIDs["Beta-Light"]!, f.faceIDs["Beta-Regular"]!, f.faceIDs["Beta-Black"]!]))
        try f.store.setCustomFamily("Gamma", faceIDs: ids)
        g = try groups(f)
        #expect(g["Gamma"] == Set(ids))
        #expect(g["Alpha"] == nil)
        #expect(try custom(f, "Alpha-Bold") == "Gamma")
    }

    @Test func nameEqualToOriginalClears() throws {
        let f = try Fixture.make()
        let ids = [f.faceIDs["Alpha-Regular"]!, f.faceIDs["Alpha-Bold"]!]
        try f.store.setCustomFamily("Zed", faceIDs: ids)
        try f.store.setCustomFamily("Alpha", faceIDs: ids)
        #expect(try custom(f, "Alpha-Regular") == nil && custom(f, "Alpha-Bold") == nil)
        try f.store.setCustomFamily("Zed", faceIDs: ids)
        try f.store.setCustomFamily("   ", faceIDs: ids)
        #expect(try custom(f, "Alpha-Regular") == nil && custom(f, "Alpha-Bold") == nil)
        try f.store.setCustomFamily("Zed", faceIDs: ids)
        try f.store.setCustomFamily(nil, faceIDs: ids)
        #expect(try custom(f, "Alpha-Regular") == nil)
    }

    @Test func mergeAndSplit() throws {
        var f = try Fixture.make()
        let b = try f.store.nextImportBatch()
        try f.add(f.locA.id, "GB.otf", [Fixture.face("GothamBook", family: "Gotham Book", style: "Regular", weight: 400)], b)
        try f.add(f.locA.id, "GBo.otf", [Fixture.face("GothamBold", family: "Gotham Bold", style: "Bold", weight: 700)], b)
        let ids = [f.faceIDs["GothamBook"]!, f.faceIDs["GothamBold"]!]
        try f.store.setCustomFamily("Gotham", faceIDs: ids)
        #expect(try groups(f)["Gotham"] == Set(ids))
        try f.store.setCustomFamily("Gotham Narrow", faceIDs: [ids[1]])
        let g = try groups(f)
        #expect(g["Gotham"] == [ids[0]] && g["Gotham Narrow"] == [ids[1]])
    }

    @Test func clearOnlyTouchesEdited() throws {
        let f = try Fixture.make()
        let reg = f.faceIDs["Alpha-Regular"]!, bold = f.faceIDs["Alpha-Bold"]!
        try f.store.setCustomFamily("Zed", faceIDs: [bold])
        let prev = try f.store.clearCustomFamilies(faceIDs: [reg, bold])
        #expect(prev.count == 1 && prev[bold] == .some("Zed"))
        #expect(try custom(f, "Alpha-Regular") == nil && custom(f, "Alpha-Bold") == nil)
        #expect(try groups(f)["Alpha"]?.contains(bold) == true)
        #expect(try f.store.clearCustomFamilies(faceIDs: [reg]).isEmpty)
    }

    @Test func undoRestoresPrevious() throws {
        let f = try Fixture.make()
        let reg = f.faceIDs["Alpha-Regular"]!, bold = f.faceIDs["Alpha-Bold"]!
        try f.store.setCustomFamily("One", faceIDs: [reg])
        let prev = try f.store.setCustomFamily("Two", faceIDs: [reg, bold])
        #expect(prev[reg] == .some("One") && prev[bold] == .some(nil))
        #expect(try custom(f, "Alpha-Regular") == "Two")
        try f.store.restoreCustomFamilies(prev)
        #expect(try custom(f, "Alpha-Regular") == "One" && custom(f, "Alpha-Bold") == nil)
        let cleared = try f.store.clearCustomFamilies(faceIDs: [reg])
        try f.store.restoreCustomFamilies(cleared)
        #expect(try custom(f, "Alpha-Regular") == "One")
    }

    @Test func clashIsCaseInsensitive() throws {
        var f = try Fixture.make()
        let b = try f.store.nextImportBatch()
        try f.add(f.locA.id, "H.otf", [Fixture.face("Helv", family: "Helvetica", style: "Regular", weight: 400)], b)
        try f.add(f.locA.id, "A.otf", [Fixture.face("Ar", family: "Arial", style: "Regular", weight: 400)], b)
        try f.add(f.locA.id, "A2.otf", [Fixture.face("Ar2", family: "Arial", style: "Bold", weight: 700)], b)
        let arial: [Int64] = [f.faceIDs["Ar"]!, f.faceIDs["Ar2"]!]
        let helv = f.faceIDs["Helv"]!
        #expect(try f.store.existingFamilyFaceIDs(named: " helvetica ", excluding: Set(arial)) == [helv])
        #expect(try f.store.existingFamilyFaceIDs(named: "Arial", excluding: Set(arial)).isEmpty)
        try f.store.setCustomFamily("helvetica", faceIDs: arial)
        #expect(try custom(f, "Helv") == nil)
        let g = try groups(f)
        #expect(g.count == 3 && g["Helvetica"] == Set([helv] + arial))
    }

    @Test func representativeFollowsRename() throws {
        let f = try Fixture.make()
        let ids = ["Alpha-Regular", "Alpha-Italic", "Alpha-Bold"].map { f.faceIDs[$0]! }
        try f.store.setRepresentative(familyKey: "alpha", faceID: f.faceIDs["Alpha-Bold"]!)
        try f.store.setCustomFamily("Omega", faceIDs: ids)
        let omega = try #require(try f.store.families(for: LibraryQuery()).first { $0.name == "Omega" })
        #expect(omega.representativeID == f.faceIDs["Alpha-Bold"]!)
        // An existing representative on the target is kept.
        try f.store.setRepresentative(familyKey: "beta", faceID: f.faceIDs["Beta-Black"]!)
        try f.store.setCustomFamily("Beta", faceIDs: ids)
        let beta = try #require(try f.store.families(for: LibraryQuery()).first { $0.name == "Beta" })
        #expect(beta.representativeID == f.faceIDs["Beta-Black"]!)
        // Old keys are gone.
        let s = try f.store.database.prepare("SELECT family_key FROM family_prefs ORDER BY 1")
        var keys: [String] = []
        while try s.step() { keys.append(s.text(0)) }
        s.reset()
        #expect(keys == ["beta"])
    }

    @Test func originalFamiliesListsEditedOnly() throws {
        let f = try Fixture.make()
        let all = f.faceIDs.values.sorted()
        try f.store.setCustomFamily("X", faceIDs: [f.faceIDs["Beta-Light"]!, f.faceIDs["Alpha-Bold"]!])
        #expect(try f.store.originalFamilies(faceIDs: all) == ["Alpha", "Beta"])
        #expect(try f.store.originalFamilies(faceIDs: [f.faceIDs["Alpha-Regular"]!]).isEmpty)
    }

    @Test func editedFamiliesMapsKeysToOriginals() throws {
        let f = try Fixture.make()
        #expect(try f.store.editedFamilies().isEmpty)
        let alpha = f.faceIDs["Alpha-Regular"]!, beta = f.faceIDs["Beta-Light"]!
        try f.store.setCustomFamily("Merged", faceIDs: [alpha, beta])
        #expect(try f.store.editedFamilies() == ["merged": ["Alpha", "Beta"]])
        try f.store.clearCustomFamilies(faceIDs: [alpha, beta])
        #expect(try f.store.editedFamilies().isEmpty)
    }

    @Test func searchFindsCustomName() throws {
        let f = try Fixture.make()
        let ids = [f.faceIDs["Alpha-Regular"]!, f.faceIDs["Alpha-Bold"]!]
        try f.store.setCustomFamily("Zebra Display", faceIDs: ids)
        var q = LibraryQuery()
        q.search = SearchText("Zebra")
        #expect(Set(try f.store.faceIDs(for: q)) == Set(ids))
        try f.store.setCustomFamily(nil, faceIDs: ids)
        #expect(try f.store.faceIDs(for: q).isEmpty)
    }

    @Test func migratesV4ToV5() throws {
        let db = try Database(path: ":memory:")
        for (i, sql) in [Schema.v1, Schema.v2, Schema.v3, Schema.v4].enumerated() {
            try db.execute(sql)
            try db.execute("PRAGMA user_version = \(i + 1)")
        }
        try db.execute("INSERT INTO locations(id,kind,volume_uuid,relative_path,display_name,last_known_path) VALUES(1,0,'v','p','n','/p')")
        try db.execute("INSERT INTO files(id,location_id,relative_path,size,mtime,format,fingerprint,added_at,import_batch) VALUES(1,1,'a.otf',1,0,'otf','fp',0,0)")
        try db.execute("""
        INSERT INTO faces(id,file_id,face_index,postscript_name,family,custom_family,style,full_name,weight,width,slant,is_italic,is_variable,glyph_count,units_per_em,ascender,descender,cap_height,x_height,outline_type,is_color,is_bitmap,has_gsub,has_gpos)
        VALUES(7,1,0,'Avenir-Regular','Avenir','Zebra Sans','Regular','Avenir Regular',0,0,0,0,0,10,1000,800,-200,700,500,'cff',0,0,0,0)
        """)
        try Schema.migrate(db)
        func match(_ q: String) throws -> [Int64] {
            let s = try db.prepare("SELECT rowid FROM faces_fts WHERE faces_fts MATCH ?")
            try s.bind([.text(q)])
            var ids: [Int64] = []
            while try s.step() { ids.append(s.int64(0)) }
            s.reset()
            return ids
        }
        #expect(try match("aven*") == [7])
        #expect(try match("custom_family : zebra*") == [7])
        try db.execute("UPDATE faces SET custom_family = 'Quokka' WHERE id = 7")
        #expect(try match("zebra*").isEmpty)
        #expect(try match("quokka*") == [7])
        let v = try db.prepare("PRAGMA user_version")
        #expect(try v.step() && v.int64(0) == Int64(Schema.currentVersion))
        v.reset()
    }
}
