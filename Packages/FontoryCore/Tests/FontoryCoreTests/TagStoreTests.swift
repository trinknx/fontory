import Foundation
import Testing
@testable import FontoryCore

@Suite struct TagStoreTests {
    private func count(_ store: FontStore, _ sql: String) throws -> Int64 {
        try store.database.withLock {
            let s = try store.database.prepare(sql)
            defer { s.reset() }
            _ = try s.step()
            return s.int64(0)
        }
    }

    @Test func migratesToV3() throws {
        let db = try Database(path: ":memory:")
        try db.execute(Schema.v1)
        try db.execute("PRAGMA user_version = 1")
        try Schema.migrate(db)
        let names = try db.prepare("SELECT name FROM sqlite_master")
        var found = Set<String>()
        while try names.step() { found.insert(names.text(0)) }
        names.reset()
        for n in ["tags", "face_tags", "quick_collection", "face_tags_tag"] { #expect(found.contains(n), "missing \(n)") }
        let cols = try db.prepare("PRAGMA table_info(faces)")
        var faceCols = Set<String>()
        while try cols.step() { faceCols.insert(cols.text(1)) }
        cols.reset()
        #expect(faceCols.isSuperset(of: ["style_class", "class_version"]))
        #expect(Schema.currentVersion >= 3)
    }

    @Test func createRenameMoveDelete() throws {
        let f = try Fixture.make()
        let s = f.store
        let a = try s.createTag(name: "  Serif ", parentID: nil)
        let b = try s.createTag(name: "Didone", parentID: a)
        let c = try s.createTag(name: "Other", parentID: nil)
        #expect(try s.tags().first { $0.id == a }?.name == "Serif")
        try s.renameTag(b, to: "Bodoni")
        try s.moveTag(b, toParent: c)
        #expect(try s.tags().first { $0.id == b }?.parentID == c)
        let smart = try s.createTag(name: "Rule", parentID: nil, kind: .smart, ruleJSON: "{}")
        try s.setTagRule(smart, ruleJSON: "{\"a\":1}")
        let rec = try #require(try s.tags().first { $0.id == smart })
        #expect(rec.kind == .smart && rec.ruleJSON == "{\"a\":1}")

        let face = f.faceIDs["Alpha-Regular"]!
        try s.addTag(c, toFaces: [face])
        try s.addTag(b, toFaces: [face])
        try s.deleteTag(c)
        #expect(try s.tags().map(\.id).contains(b) == false)
        #expect(try s.tagIDs(forFaces: [face]).isEmpty)
        #expect(try count(s, "SELECT COUNT(*) FROM face_tags") == 0)
        #expect(try count(s, "SELECT COUNT(*) FROM faces") == 6)
        #expect(throws: TagError.emptyName) { try s.createTag(name: "  ", parentID: nil) }
        #expect(throws: TagError.notFound) { try s.renameTag(9999, to: "x") }
    }

    @Test func duplicateNamesRefusedAmongSiblingsOnly() throws {
        let s = try Fixture.make().store
        let a = try s.createTag(name: "A", parentID: nil)
        let b = try s.createTag(name: "B", parentID: nil)
        _ = try s.createTag(name: "Fun", parentID: a)
        #expect(throws: TagError.duplicateName) { try s.createTag(name: "fun", parentID: a) }
        _ = try s.createTag(name: "Fun", parentID: b)
        #expect(throws: TagError.duplicateName) { try s.createTag(name: "a", parentID: nil) }
        let other = try s.createTag(name: "Zed", parentID: a)
        #expect(throws: TagError.duplicateName) { try s.renameTag(other, to: "FUN") }
        try s.renameTag(other, to: "ZED")
        let fun = try #require(try s.tags().first { $0.name == "Fun" && $0.parentID == b })
        #expect(throws: TagError.duplicateName) { try s.moveTag(fun.id, toParent: a) }
    }

    @Test func duplicateDetectionIsUnicodeCaseInsensitive() throws {
        let s = try Fixture.make().store
        let a = try s.createTag(name: "A", parentID: nil)
        let b = try s.createTag(name: "B", parentID: nil)
        _ = try s.createTag(name: "Élan", parentID: a)
        _ = try s.createTag(name: "Ärger", parentID: a)
        #expect(throws: TagError.duplicateName) { try s.createTag(name: "élan", parentID: a) }
        #expect(throws: TagError.duplicateName) { try s.createTag(name: "ÄRGER", parentID: a) }
        _ = try s.createTag(name: "élan", parentID: b)
        _ = try s.createTag(name: "Ärger", parentID: nil)
        #expect(throws: TagError.duplicateName) { try s.createTag(name: "ärger", parentID: nil) }
    }

    @Test func cannotNestUnderDescendant() throws {
        let s = try Fixture.make().store
        let a = try s.createTag(name: "A", parentID: nil)
        let b = try s.createTag(name: "B", parentID: a)
        let c = try s.createTag(name: "C", parentID: b)
        #expect(throws: TagError.cycle) { try s.moveTag(a, toParent: c) }
        #expect(throws: TagError.cycle) { try s.moveTag(a, toParent: a) }
        try s.moveTag(c, toParent: nil)
    }

    @Test func addRemoveIsIdempotent() throws {
        let f = try Fixture.make()
        let s = f.store
        let t = try s.createTag(name: "T", parentID: nil)
        let ids = [f.faceIDs["Alpha-Regular"]!, f.faceIDs["Beta-Light"]!]
        try s.addTag(t, toFaces: ids)
        try s.addTag(t, toFaces: ids + [987654])
        #expect(try count(s, "SELECT COUNT(*) FROM face_tags") == 2)
        #expect(try s.tagIDs(forFaces: ids) == [ids[0]: [t], ids[1]: [t]])
        try s.removeTag(t, fromFaces: [ids[0]])
        try s.removeTag(t, fromFaces: [ids[0]])
        #expect(try s.tagIDs(forFaces: ids) == [ids[1]: [t]])
        try s.setQuickCollection(ids, included: true, at: Date(timeIntervalSince1970: 5))
        try s.setQuickCollection(ids, included: true, at: Date(timeIntervalSince1970: 9))
        #expect(try s.quickCollectionFaceIDs() == Set(ids))
        try s.setQuickCollection([ids[0]], included: false, at: Date())
        #expect(try s.quickCollectionFaceIDs() == [ids[1]])
        try s.clearQuickCollection()
        #expect(try s.quickCollectionFaceIDs().isEmpty)
    }

    private func decorate(_ f: Fixture, _ ps: String) throws -> (face: Int64, tag: Int64) {
        let face = f.faceIDs[ps]!
        let tag = try f.store.createTag(name: "Keep", parentID: nil)
        try f.store.addTag(tag, toFaces: [face])
        try f.store.setQuickCollection([face], included: true, at: Date())
        try f.store.setNote("remember me", faceID: face)
        return (face, tag)
    }

    private func assertKept(_ f: Fixture, _ face: Int64, _ tag: Int64) throws {
        #expect(try f.store.tagIDs(forFaces: [face]) == [face: [tag]])
        #expect(try f.store.quickCollectionFaceIDs() == [face])
        #expect(try count(f.store, "SELECT COUNT(*) FROM faces WHERE id = \(face) AND note = 'remember me'") == 1)
    }

    @Test func tagsSurviveInPlaceChange() throws {
        let f = try Fixture.make()
        let (face, tag) = try decorate(f, "Alpha-Regular")
        let fileID = f.fileIDs["Alpha-Regular.otf"]!
        try f.store.replaceFaces(fileID: fileID, size: 99, mtime: Date(), fingerprint: "new",
                                 faces: [Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 410)])
        try assertKept(f, face, tag)
    }

    @Test func tagsSurviveMoveAndOffline() throws {
        let f = try Fixture.make()
        let (face, tag) = try decorate(f, "Beta-Light")
        try f.store.moveFile(fileID: f.fileIDs["Beta-Light.otf"]!, toRelativePath: "Sub/Beta-Light.otf", mtime: Date())
        try assertKept(f, face, tag)
        try f.store.setLocationOnline(f.locB.id, online: false, lastKnownPath: nil)
        try assertKept(f, face, tag)
        try f.store.setLocationOnline(f.locB.id, online: true, lastKnownPath: nil)
        try assertKept(f, face, tag)
    }

    @Test func deletedFaceDropsItsTags() throws {
        let f = try Fixture.make()
        let (face, _) = try decorate(f, "Alpha-Bold")
        try f.store.deleteFiles([f.fileIDs["Alpha-Bold.otf"]!])
        #expect(try f.store.tagIDs(forFaces: [face]).isEmpty)
        #expect(try f.store.quickCollectionFaceIDs().isEmpty)
        #expect(try count(f.store, "SELECT COUNT(*) FROM face_tags") == 0)
    }

    @Test func userDataCountIncludesTagsAndCollection() throws {
        let f = try Fixture.make()
        let s = f.store
        let files = Array(f.fileIDs.values)
        #expect(try s.userDataFaceCount(fileIDs: files) == 0)
        let t = try s.createTag(name: "T", parentID: nil)
        try s.addTag(t, toFaces: [f.faceIDs["Alpha-Regular"]!])
        try s.setQuickCollection([f.faceIDs["Alpha-Italic"]!], included: true, at: Date())
        try s.setNote("n", faceID: f.faceIDs["Alpha-Bold"]!)
        #expect(try s.userDataFaceCount(fileIDs: files) == 3)
        try s.setNote("  ", faceID: f.faceIDs["Alpha-Bold"]!)
        #expect(try s.userDataFaceCount(fileIDs: files) == 2)
    }

    @Test func noteIsSearchable() throws {
        let f = try Fixture.make()
        let face = f.faceIDs["Alpha-Regular"]!
        try f.store.setNote("zebrastripes", faceID: face)
        #expect(try count(f.store, "SELECT COUNT(*) FROM faces_fts WHERE faces_fts MATCH 'zebrastripes'") == 1)
        try f.store.setNote(nil, faceID: face)
        #expect(try count(f.store, "SELECT COUNT(*) FROM faces_fts WHERE faces_fts MATCH 'zebrastripes'") == 0)
    }

    @Test func tagging1000FacesIsFast() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/F")
        let batch = try store.nextImportBatch()
        for file in 0..<20 {
            let faces = (0..<1000).map { Fixture.face("PS-\(file)-\($0)", family: "Fam\(file)", style: "S\($0)", weight: 400, index: $0) }
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "f\(file).ttc", size: 1, mtime: Date(), format: "ttc", fingerprint: "fp\(file)"),
                                     faces: faces, importBatch: batch)
        }
        let all = try store.faceIDs(for: LibraryQuery())
        #expect(all.count == 20_000)
        let tag = try store.createTag(name: "Bulk", parentID: nil)
        let start = Date()
        try store.addTag(tag, toFaces: Array(all.prefix(1000)))
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(ms < 200, "took \(ms) ms")
        #expect(try count(store, "SELECT COUNT(*) FROM face_tags") == 1000)
    }
}
