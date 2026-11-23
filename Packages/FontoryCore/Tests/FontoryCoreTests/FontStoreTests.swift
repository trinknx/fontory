import Foundation
import Testing
@testable import FontoryCore

@Suite struct FontStoreTests {
    @Test func faceIDsFilterByScopeAndSort() throws {
        let f = try Fixture.make()
        let ids = f.faceIDs
        try f.store.setActivation(faceIDs: [ids["Beta-Black"]!, ids["Alpha-Bold"]!], state: .on, at: Date())
        let on = try f.store.faceIDs(for: LibraryQuery(scope: .activated))
        #expect(Set(on) == [ids["Beta-Black"]!, ids["Alpha-Bold"]!])
        #expect(try f.store.faceIDs(for: LibraryQuery(scope: .deactivated)).count == 4)

        let order = try f.store.faceIDs(for: LibraryQuery())
        let names = try f.store.rows(ids: order)
        #expect(order.map { names[$0]!.postScriptName } == ["Alpha-Regular", "Alpha-Italic", "Alpha-Bold", "Beta-Light", "Beta-Regular", "Beta-Black"])
        let desc = try f.store.faceIDs(for: LibraryQuery(ascending: false))
        #expect(desc == order.reversed())

        let byWeight = try f.store.faceIDs(for: LibraryQuery(sort: .weight))
        #expect(byWeight.first == ids["Beta-Light"]!)
        #expect(byWeight.last == ids["Beta-Black"]!)
        let rnd1 = try f.store.faceIDs(for: LibraryQuery(sort: .random(seed: 42)))
        let rnd2 = try f.store.faceIDs(for: LibraryQuery(sort: .random(seed: 42)))
        #expect(rnd1 == rnd2 && Set(rnd1) == Set(order))
    }

    @Test func includeSystemFalseHidesSystemLocations() throws {
        let f = try Fixture.make()
        let sys = try f.store.upsertLocation(kind: .system, volumeUUID: "SYS", relativePath: "", displayName: "System", lastKnownPath: "/System/Library/Fonts")
        _ = try f.store.insertFile(FileRecord(locationID: sys.id, relativePath: "Sys.ttf", size: 1, mtime: Date(), format: "ttf", fingerprint: "s"),
                                   faces: [Fixture.face("Sys", family: "Sys", style: "Regular", weight: 400)], importBatch: 9)
        #expect(try f.store.faceIDs(for: LibraryQuery()).count == 7)
        #expect(try f.store.faceIDs(for: LibraryQuery(includeSystem: false)).count == 6)
    }

    @Test func familiesGroupsAndPicksRepresentative() throws {
        let f = try Fixture.make()
        let fams = try f.store.families(for: LibraryQuery())
        #expect(fams.map(\.name) == ["Alpha", "Beta"])
        let alpha = fams[0]
        #expect(alpha.id == "alpha")
        #expect(alpha.faceIDs.count == 3)
        #expect(alpha.representativeID == f.faceIDs["Alpha-Regular"]!)
        #expect(fams[1].representativeID == f.faceIDs["Beta-Regular"]!)
        // within a family: weight order, regular before bold
        #expect(alpha.faceIDs.last == f.faceIDs["Alpha-Bold"]!)

        try f.store.setRepresentative(familyKey: "alpha", faceID: f.faceIDs["Alpha-Bold"]!)
        #expect(try f.store.families(for: LibraryQuery())[0].representativeID == f.faceIDs["Alpha-Bold"]!)
        try f.store.setRepresentative(familyKey: "alpha", faceID: nil)
        #expect(try f.store.families(for: LibraryQuery())[0].representativeID == f.faceIDs["Alpha-Regular"]!)
    }

    @Test func offlineLocationHidesURL() throws {
        let f = try Fixture.make()
        let id = f.faceIDs["Alpha-Regular"]!
        let online = try f.store.rows(ids: [id])[id]!
        #expect(online.online)
        #expect(online.fileURL?.path == "/Volumes/A/Fonts/Alpha-Regular.otf")

        try f.store.setLocationOnline(f.locA.id, online: false, lastKnownPath: nil)
        let off = try f.store.rows(ids: [id])[id]!
        #expect(off.fileURL == nil)
        #expect(off.online == false)
        #expect(Set(try f.store.faceIDs(for: LibraryQuery(scope: .offline))) == Set(["Alpha-Regular", "Alpha-Italic", "Alpha-Bold"].map { f.faceIDs[$0]! }))
    }

    @Test func replaceFacesKeepsActivationByPostScriptName() throws {
        let f = try Fixture.make()
        let id = f.faceIDs["Alpha-Regular"]!
        try f.store.setActivation(faceIDs: [id], state: .on, at: Date(timeIntervalSince1970: 5000))
        try f.store.database.execute("UPDATE faces SET note = 'keep me' WHERE id = \(id)")
        var updated = Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400)
        updated.glyphCount = 999
        let extra = Fixture.face("Alpha-Extra", family: "Alpha", style: "Extra", weight: 500, index: 1)
        try f.store.replaceFaces(fileID: f.fileIDs["Alpha-Regular.otf"]!, size: 77, mtime: Date(timeIntervalSince1970: 2000), fingerprint: "new", faces: [extra, updated])

        let row = try f.store.rows(ids: [id])[id]!
        #expect(row.activation == .on)
        #expect(row.glyphCount == 999)
        #expect(row.lastActivated == Date(timeIntervalSince1970: 5000))
        let note = try f.store.database.prepare("SELECT note FROM faces WHERE id = \(id)")
        #expect(try note.step())
        #expect(note.text(0) == "keep me")
        note.reset()
        #expect(try f.store.faceIDs(for: LibraryQuery()).count == 7)
        let file = try f.store.files(in: f.locA.id).first { $0.relativePath == "Alpha-Regular.otf" }!
        #expect(file.size == 77 && file.fingerprint == "new")
    }

    @Test func recentImportUsesLatestBatch() throws {
        let f = try Fixture.make()
        let recent = try f.store.faceIDs(for: LibraryQuery(scope: .recentImport))
        #expect(Set(recent) == Set(["Beta-Light", "Beta-Regular", "Beta-Black"].map { f.faceIDs[$0]! }))
        #expect(try f.store.nextImportBatch() == 3)
    }

    @Test func locationSubfolderScopeAndListing() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "Root", displayName: "Root", lastKnownPath: "/r")
        let batch = try store.nextImportBatch()
        for p in ["a/x.ttf", "a/b/y.ttf", "c/z.ttf", "top.ttf", "ab/w.ttf"] {
            let name = (p as NSString).lastPathComponent
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: p, size: 1, mtime: Date(), format: "ttf", fingerprint: p),
                                     faces: [Fixture.face(name, family: name, style: "Regular", weight: 400)], importBatch: batch)
        }
        #expect(try store.subfolders(locationID: loc.id, parent: nil) == ["a", "ab", "c"])
        #expect(try store.subfolders(locationID: loc.id, parent: "a") == ["b"])
        let ids = try store.faceIDs(for: LibraryQuery(scope: .location(id: loc.id, subfolder: "a")))
        let names = try store.rows(ids: ids).values.map(\.postScriptName)
        #expect(Set(names) == ["x.ttf", "y.ttf"])
        #expect(try store.faceIDs(for: LibraryQuery(scope: .location(id: loc.id, subfolder: nil))).count == 5)
    }

    @Test func faceIDs20kUnder100ms() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "R", displayName: "R", lastKnownPath: "/r")
        let batch = try store.nextImportBatch()
        try store.database.transaction {
            for i in 0..<20_000 {
                let fam = "Family \(i / 4)"
                _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "f\(i).otf", size: 1, mtime: Date(), format: "otf", fingerprint: "\(i)"),
                                         faces: [Fixture.face("PS-\(i)", family: fam, style: "S\(i % 4)", weight: Double(100 * (i % 4 + 1)))], importBatch: batch)
            }
        }
        let clock = ContinuousClock()
        var ids: [Int64] = []
        let elapsed = try clock.measure { ids = try store.faceIDs(for: LibraryQuery()) }
        #expect(ids.count == 20_000)
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }

    private func searchStore() throws -> FontStore {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "R", displayName: "R", lastKnownPath: "/r")
        let batch = try store.nextImportBatch()
        let defs: [(String, String, String, String?)] = [
            ("AvenirNext-Regular", "Avenir Next", "Regular", nil),
            ("CafeSans-Regular", "Caf\u{E9} Sans", "Regular", nil),
            ("HelveticaNeue-Italic", "Helvetica Neue", "Italic", nil),
            ("Helvetica-Bold", "Helvetica", "Bold", nil),
            ("Foo-Italic", "Foo", "Italic", "Zed"),
        ]
        for (i, d) in defs.enumerated() {
            var face = Fixture.face(d.0, family: d.1, style: d.2, weight: 400)
            face.designer = d.3
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "f\(i).otf", size: 1, mtime: Date(), format: "otf", fingerprint: "\(i)"), faces: [face], importBatch: batch)
        }
        return store
    }

    private func names(_ store: FontStore, _ q: String, scope: Set<SearchText.Field> = Set(SearchText.Field.allCases)) throws -> [String] {
        var query = LibraryQuery()
        query.search = SearchText(q, scope: scope)
        let ids = try store.faceIDs(for: query)
        let rows = try store.rows(ids: ids)
        return ids.map { rows[$0]!.fullName }
    }

    @Test func searchContainsAndDiacritics() throws {
        let store = try searchStore()
        #expect(try names(store, "avenir") == ["Avenir Next Regular"])
        #expect(try names(store, "cafe") == ["Caf\u{E9} Sans Regular"])
        #expect(try names(store, "helv ital") == ["Helvetica Neue Italic"])
        #expect(try names(store, "zed") == ["Foo Italic"])
        #expect(try names(store, "zed", scope: [.family]).isEmpty)
        #expect(try names(store, "#tag").count == 5)
    }

    @Test func searchExactAndSuffix() throws {
        let store = try searchStore()
        #expect(try names(store, "\"helvetica\"") == ["Helvetica Bold"])
        #expect(try names(store, "\"HELVETICA NEUE\"") == ["Helvetica Neue Italic"])
        #expect(try names(store, "\"Helvetica Neue Italic\"") == ["Helvetica Neue Italic"])
        #expect(try names(store, "*italic").sorted() == ["Foo Italic", "Helvetica Neue Italic"])
        #expect(try names(store, "helv* *bold") == ["Helvetica Bold"])
        #expect(try names(store, "*100%").isEmpty)
    }

    @Test func search20kUnder100ms() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "R", displayName: "R", lastKnownPath: "/r")
        let batch = try store.nextImportBatch()
        try store.database.transaction {
            for i in 0..<20_000 {
                _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "f\(i).otf", size: 1, mtime: Date(), format: "otf", fingerprint: "\(i)"),
                                         faces: [Fixture.face("PS-\(i)", family: "Family\(i / 4) Grotesk", style: "S\(i % 4)", weight: 400)], importBatch: batch)
            }
        }
        var q = LibraryQuery()
        q.search = SearchText("family12 grot")
        var ids: [Int64] = []
        let elapsed = try ContinuousClock().measure { ids = try store.faceIDs(for: q) }
        #expect(ids.count == 444)
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }

    @Test func lastActivatedSortsNeverActivatedLast() throws {
        let f = try Fixture.make()
        let ids = f.faceIDs
        try f.store.setActivation(faceIDs: [ids["Beta-Black"]!], state: .on, at: Date(timeIntervalSince1970: 100))
        try f.store.setActivation(faceIDs: [ids["Alpha-Bold"]!], state: .on, at: Date(timeIntervalSince1970: 200))
        let asc = try f.store.faceIDs(for: LibraryQuery(sort: .lastActivated))
        #expect(Array(asc.prefix(2)) == [ids["Beta-Black"]!, ids["Alpha-Bold"]!])
        let desc = try f.store.faceIDs(for: LibraryQuery(sort: .lastActivated, ascending: false))
        #expect(Array(desc.prefix(2)) == [ids["Alpha-Bold"]!, ids["Beta-Black"]!])
        #expect(desc.count == 6)
    }

    @Test func rowsHandlesMoreThanOneChunk() throws {
        let f = try Fixture.make()
        let id = f.faceIDs["Alpha-Bold"]!
        let rows = try f.store.rows(ids: Array(repeating: id, count: 1203))
        #expect(rows.count == 1 && rows[id]?.postScriptName == "Alpha-Bold")
        #expect(try f.store.rows(ids: []).isEmpty)
    }
}
