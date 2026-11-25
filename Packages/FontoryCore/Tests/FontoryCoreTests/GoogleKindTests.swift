import Foundation
import Testing
@testable import FontoryCore

@Suite struct GoogleKindTests {
    private func memoryStore() throws -> FontStore { try FontStore(database: Database(path: ":memory:")) }

    private func googleLocation(_ store: FontStore, path: String = "/G") throws -> LocationRecord {
        try store.upsertLocation(kind: .googleFonts, volumeUUID: "V", relativePath: "G", displayName: "Google Fonts", lastKnownPath: path)
    }

    private func insertFake(_ store: FontStore, _ loc: Int64, _ path: String, ps: String) throws -> Int64 {
        let face = Fixture.face(ps, family: ps, style: "Regular", weight: 400, index: 0)
        return try store.insertFile(FileRecord(locationID: loc, relativePath: path, size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                               format: "otf", fingerprint: "fp-\(path)"),
                                    faces: [face], importBatch: 1)
    }

    @Test func googleKindIsToggleable() {
        #expect(LocationKind.googleFonts.rawValue == 4)
        #expect(LocationKind.googleFonts.isToggleable && !LocationKind.googleFonts.isReadOnly)
        #expect(LocationKind.folder.isToggleable && LocationKind.fileSet.isToggleable)
        #expect(!LocationKind.system.isToggleable && !LocationKind.userInstalled.isToggleable)
        #expect(LibraryQuery.toggleableKindsSQL == "0, 1, 4")
        #expect(ActivationStatus(kind: .googleFonts, externalActive: false, activation: .on) == .on)
        #expect(ActivationStatus(kind: .googleFonts, externalActive: false, activation: .off) == .off)
        #expect(ActivationStatus(kind: .googleFonts, externalActive: true, activation: .off) == .external)
    }

    @Test func googleFacesCountInDeactivatedAndActivated() throws {
        let store = try memoryStore()
        let loc = try googleLocation(store)
        let file = try insertFake(store, loc.id, "a.ttf", ps: "Lato-Regular")
        let faceIDs = try store.faceIDs(for: LibraryQuery())
        #expect(faceIDs.count == 1)
        _ = file

        func ids(_ scope: LibraryQuery.Scope) throws -> [Int64] { try store.faceIDs(for: LibraryQuery(scope: scope)) }
        #expect(try ids(.deactivated) == faceIDs)
        #expect(try ids(.activated).isEmpty)
        var c = LibraryCounts(groups: try store.faceCountGroups(), includeSystem: true)
        #expect(c.deactivated == 1 && c.activated == 0)

        try store.setActivation(faceIDs: faceIDs, state: .on, at: Date())
        #expect(try ids(.activated) == faceIDs)
        #expect(try ids(.deactivated).isEmpty)
        c = LibraryCounts(groups: try store.faceCountGroups(), includeSystem: true)
        #expect(c.activated == 1 && c.deactivated == 0 && c.fontoryActive == 1)
    }

    @Test func googleFacesJoinDuplicates() async throws {
        let t1 = try TempFonts(), t2 = try TempFonts()
        defer { t1.cleanup(); t2.cleanup() }
        let store = try memoryStore()
        let folder = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t1.root.path)
        let google = try store.upsertLocation(kind: .googleFonts, volumeUUID: "V", relativePath: "G", displayName: "G", lastKnownPath: t2.root.path)
        try t1.copy(TempFonts.arialBold, as: "a.ttf")
        try t2.copy(TempFonts.arialBold, as: "b.ttf")
        func index(_ loc: LocationRecord, _ t: TempFonts, _ relative: String) throws -> Int64 {
            let url = t.root.appendingPathComponent(relative)
            let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let record = FileRecord(locationID: loc.id, relativePath: relative, size: Int64(size), mtime: Date(), format: "ttf",
                                    fingerprint: try Fingerprint.compute(url: url, size: Int64(size)))
            return try store.insertFile(record, faces: try FontParser.parse(url: url), importBatch: try store.nextImportBatch())
        }
        let a = try index(folder, t1, "a.ttf"), b = try index(google, t2, "b.ttf")
        let finder = DuplicateFinder(store: store)
        for await _ in finder.hashCandidates() {}
        let exact = try finder.groups(includeSystem: false).filter { $0.kind == .exact }
        #expect(exact.count == 1)
        #expect(Set(exact.first?.fileIDs ?? []) == [a, b])
    }
}
