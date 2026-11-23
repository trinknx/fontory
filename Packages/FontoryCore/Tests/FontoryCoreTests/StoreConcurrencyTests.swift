import Foundation
import Testing
@testable import FontoryCore

@Suite struct StoreConcurrencyTests {
    private static func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("fontory-\(UUID().uuidString).sqlite").path
    }

    private static func removeDatabase(_ path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// Two locations, `files` files with one face each.
    private static func populate(_ store: FontStore, files: Int = 300) throws {
        let a = try store.upsertLocation(kind: .folder, volumeUUID: "VOL-A", relativePath: "Fonts", displayName: "A", lastKnownPath: "/Volumes/A/Fonts")
        let b = try store.upsertLocation(kind: .folder, volumeUUID: "VOL-B", relativePath: "Type", displayName: "B", lastKnownPath: "/Volumes/B/Type")
        let batch = try store.nextImportBatch()
        try store.database.transaction {
            for i in 0..<files {
                let file = FileRecord(locationID: i.isMultiple(of: 2) ? a.id : b.id, relativePath: "F\(i).otf", size: 10,
                                      mtime: Date(timeIntervalSince1970: 1000), format: "otf", fingerprint: "fp-\(i)")
                _ = try store.insertFile(file, faces: [Fixture.face("Face-\(i)", family: "Fam\(i % 17)", style: "S\(i)", weight: Double(100 * (i % 9 + 1)))],
                                         importBatch: batch)
            }
        }
    }

    private static func hammer(_ store: FontStore) async throws {
        let query = LibraryQuery(sort: .weight)
        let expectedIDs = try store.faceIDs(for: query)
        let expectedLocations = try store.locations()
        #expect(expectedIDs.count == 300)

        let mismatches = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var bad = 0
                    for _ in 0..<200 {
                        if (try? store.faceIDs(for: query)) != expectedIDs { bad += 1 }
                        if (try? store.locations()) != expectedLocations { bad += 1 }
                    }
                    return bad
                }
            }
            return await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    @Test func concurrentReadsMatchSingleThreadedInMemory() async throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        try Self.populate(store)
        try await Self.hammer(store)
    }

    @Test func concurrentReadsMatchSingleThreadedOnFile() async throws {
        let path = Self.tempPath()
        defer { Self.removeDatabase(path) }
        let store = try FontStore(database: Database(path: path))
        try Self.populate(store)
        try await Self.hammer(store)
    }

    @Test func readerWaitsForBriefLocks() throws {
        let path = Self.tempPath()
        defer { Self.removeDatabase(path) }
        let store = try FontStore(database: Database(path: path))
        #expect(store.readerBusyTimeout == 2000)
    }

    @Test func readsAreNotBlockedByAnOpenWriteTransaction() throws {
        let path = Self.tempPath()
        defer { Self.removeDatabase(path) }
        let store = try FontStore(database: Database(path: path))
        try Self.populate(store)
        let ids = try store.faceIDs(for: LibraryQuery())
        let locID = try store.locations()[0].id

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let writer = Thread {
            try? store.database.transaction {
                _ = try store.insertFile(
                    FileRecord(locationID: locID, relativePath: "Late.otf", size: 1, mtime: Date(), format: "otf", fingerprint: "late"),
                    faces: [Fixture.face("Late", family: "Late", style: "Regular", weight: 400)], importBatch: 99)
                started.signal()
                release.wait()
            }
            finished.signal()
        }
        writer.start()
        started.wait()

        let clock = ContinuousClock()
        var rows: [Int64: FaceRow] = [:]
        let elapsed = try clock.measure { rows = try store.rows(ids: ids) }
        let idsDuringWrite = try store.faceIDs(for: LibraryQuery())
        release.signal()
        finished.wait()

        #expect(elapsed < .milliseconds(50))
        #expect(rows.count == ids.count)
        #expect(idsDuringWrite == ids)  // the uncommitted insert is invisible to the reader
        #expect(try store.faceIDs(for: LibraryQuery()).count == ids.count + 1)
    }

    @Test func forgetTemporaryTurnsTemporaryOffWithoutRegistrar() async throws {
        let f = try Fixture.make()
        let temp = f.faceIDs["Alpha-Bold"]!, on = f.faceIDs["Beta-Black"]!
        try f.store.setActivation(faceIDs: [temp], state: .temporary, at: Date())
        try f.store.setActivation(faceIDs: [on], state: .on, at: Date())
        let svc = ActivationService(store: f.store, registrar: CoreTextRegistrar(availableFontURLs: { [] }))
        let report = await svc.forgetTemporary()
        #expect(report.changedFaceIDs == [temp])
        #expect(try f.store.faceIDs(state: .temporary).isEmpty)
        #expect(try f.store.faceIDs(state: .on) == [on])
    }

    @Test func faceCountGroupsAndRelink() throws {
        let f = try Fixture.make()
        let groups = try f.store.faceCountGroups()
        #expect(groups.reduce(0) { $0 + $1.count } == 6)
        #expect(groups.filter(\.inLatestImport).reduce(0) { $0 + $1.count } == 3)
        try f.store.relinkLocation(f.locA.id, volumeUUID: "VOL-C", relativePath: "New", displayName: "C", lastKnownPath: "/Volumes/C/New")
        let loc = try f.store.locations().first { $0.id == f.locA.id }!
        #expect(loc.volumeUUID == "VOL-C" && loc.relativePath == "New" && loc.displayName == "C" && loc.online)
        #expect(try f.store.files(in: f.locA.id).count == 3)
    }
}
