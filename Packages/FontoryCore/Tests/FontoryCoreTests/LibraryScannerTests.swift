import Foundation
import Testing
@testable import FontoryCore

@Suite struct LibraryScannerTests {
    struct Env {
        let t: TempFonts
        let store: FontStore
        let loc: LocationRecord
    }

    private func makeEnv(_ populate: (TempFonts) throws -> Void) throws -> Env {
        let t = try TempFonts()
        try populate(t)
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        return Env(t: t, store: store, loc: loc)
    }

    private func fixtures(_ t: TempFonts) throws {
        try t.copy(TempFonts.arialBold, as: "Arial Bold.ttf")
        try t.copy(TempFonts.avenirNext, as: "sub/Avenir Next.ttc")
        try t.copy(TempFonts.sfns, as: "SFNS.ttf")
        _ = try t.junk("junk.ttf")
        try t.write(Data(), as: "empty.otf")
    }

    private func run(_ scanner: LibraryScanner, _ id: Int64) async -> [ScanProgress] {
        var out: [ScanProgress] = []
        for await p in await scanner.scan(locationID: id) { out.append(p) }
        return out
    }

    private func faceCount(_ store: FontStore) throws -> Int { try store.faceIDs(for: LibraryQuery()).count }

    @Test func firstScanIndexesFixtureFolder() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        let events = await run(scanner, e.loc.id)
        let last = try #require(events.last)
        #expect(last.phase == .done)
        #expect(last.failed == 2)
        #expect(last.total == 5)
        #expect(last.processed == 5)
        let expected = try [TempFonts.arialBold, TempFonts.avenirNext, TempFonts.sfns]
            .reduce(0) { $0 + (try FontParser.parse(url: URL(fileURLWithPath: $1))).count }
        #expect(try faceCount(e.store) == expected)
        #expect(try e.store.files(in: e.loc.id).count == 3)
        #expect(try e.store.locations().first?.lastScan != nil)
    }

    @Test func rescanUnchangedIsNoOp() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        let before = try e.store.faceIDs(for: LibraryQuery())
        let events = await run(scanner, e.loc.id)
        #expect(events.last?.phase == .done)
        #expect(try e.store.faceIDs(for: LibraryQuery()) == before)
    }

    @Test func rescanMovesKeepActivation() async throws {
        let e = try makeEnv({ try $0.copy(TempFonts.arialBold, as: "Arial Bold.ttf") }); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        let faceID = try #require(try e.store.faceIDs(for: LibraryQuery()).first)
        try e.store.setActivation(faceIDs: [faceID], state: .on, at: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("moved"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Arial Bold.ttf"), to: root.appendingPathComponent("moved/Arial Bold.ttf"))
        let events = await run(scanner, e.loc.id)
        #expect(events.last?.phase == .done)
        let ids = try e.store.faceIDs(for: LibraryQuery())
        #expect(ids == [faceID])
        let row = try #require(try e.store.rows(ids: ids)[faceID])
        #expect(row.activation == .on)
        #expect(try e.store.files(in: e.loc.id).map(\.relativePath) == ["moved/Arial Bold.ttf"])
        let moved = try #require(events.last?.movedActiveFiles)
        #expect(moved.count == 1)
        #expect(moved.first?.fileID == row.fileID)
        #expect(moved.first?.oldURL.standardizedFileURL.path == root.appendingPathComponent("Arial Bold.ttf").standardizedFileURL.path)
        #expect(moved.first?.newURL.standardizedFileURL.path == root.appendingPathComponent("moved/Arial Bold.ttf").standardizedFileURL.path)
        #expect(events.last?.removedActiveFileURLs.isEmpty == true)
    }

    @Test func movedInactiveFileIsNotReported() async throws {
        let e = try makeEnv({ try $0.copy(TempFonts.arialBold, as: "Arial Bold.ttf") }); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        try FileManager.default.moveItem(at: root.appendingPathComponent("Arial Bold.ttf"), to: root.appendingPathComponent("Renamed.ttf"))
        let events = await run(scanner, e.loc.id)
        #expect(events.last?.phase == .done)
        #expect(try e.store.files(in: e.loc.id).map(\.relativePath) == ["Renamed.ttf"])
        #expect(events.last?.movedActiveFiles.isEmpty == true)
    }

    @Test func genuinelyRemovedFileIsDeletedAndCountsUserData() async throws {
        let e = try makeEnv({ try $0.copy(TempFonts.arialBold, as: "Arial Bold.ttf"); try $0.copy(TempFonts.sfns, as: "SFNS.ttf") }); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        let arial = try #require(try e.store.files(in: e.loc.id).first { $0.relativePath == "Arial Bold.ttf" })
        let arialFace = try #require(try e.store.rows(ids: try e.store.faceIDs(for: LibraryQuery())).values.first { $0.fileID == arial.id })
        try e.store.setActivation(faceIDs: [arialFace.id], state: .temporary, at: Date())
        try FileManager.default.removeItem(at: root.appendingPathComponent("Arial Bold.ttf"))
        let events = await run(scanner, e.loc.id)
        let last = try #require(events.last)
        #expect(last.phase == .done)
        #expect(last.removedWithUserData == 1)
        #expect(try e.store.files(in: e.loc.id).map(\.relativePath) == ["SFNS.ttf"])
        #expect(last.removedActiveFileURLs.map(\.standardizedFileURL.path) == [root.appendingPathComponent("Arial Bold.ttf").standardizedFileURL.path])
        #expect(last.movedActiveFiles.isEmpty)
    }

    @Test func changedFileKeepsFaceIdentity() async throws {
        let e = try makeEnv({ try $0.copy(TempFonts.arialBold, as: "Arial Bold.ttf") }); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        let before = try e.store.faceIDs(for: LibraryQuery())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5_000_000)], ofItemAtPath: root.appendingPathComponent("Arial Bold.ttf").path)
        let events = await run(scanner, e.loc.id)
        #expect(events.last?.phase == .done)
        #expect(events.last?.total == 1)
        #expect(try e.store.faceIDs(for: LibraryQuery()) == before)
        #expect(try e.store.files(in: e.loc.id).first?.mtime == Date(timeIntervalSince1970: 5_000_000))
    }

    private func isAborted(_ p: ScanProgress?) -> Bool {
        if case .aborted = p?.phase { return true }
        return false
    }

    @Test func missingRootAbortsWithoutDeleting() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        _ = await run(LibraryScanner(store: e.store, rootURL: { _ in root }), e.loc.id)
        let before = try faceCount(e.store)
        #expect(before > 0)
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let events = await run(LibraryScanner(store: e.store, rootURL: { _ in gone }), e.loc.id)
        #expect(isAborted(events.last))
        #expect(try faceCount(e.store) == before)
    }

    @Test func unresolvableRootAbortsWithoutDeleting() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        _ = await run(LibraryScanner(store: e.store, rootURL: { _ in root }), e.loc.id)
        let before = try faceCount(e.store)
        let events = await run(LibraryScanner(store: e.store, rootURL: { _ in nil }), e.loc.id)
        #expect(isAborted(events.last))
        #expect(try faceCount(e.store) == before)
    }

    @Test func rootVanishesMidScanAbortsWithoutDeleting() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        _ = await run(LibraryScanner(store: e.store, rootURL: { _ in root }), e.loc.id)
        let before = try faceCount(e.store)
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root }, onPhase: { phase in
            if phase == .enumerating { try? FileManager.default.removeItem(at: root) }
        })
        let events = await run(scanner, e.loc.id)
        #expect(isAborted(events.last))
        #expect(try faceCount(e.store) == before)
        #expect(try e.store.files(in: e.loc.id).count == 3)
    }

    @Test func rootVanishesBeforeRemovalsAbortsWithoutDeleting() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        _ = await run(LibraryScanner(store: e.store, rootURL: { _ in root }), e.loc.id)
        let before = try faceCount(e.store)
        // Enumeration completes (and finds nothing new), then the drive disappears before removals are applied.
        try FileManager.default.removeItem(at: root.appendingPathComponent("SFNS.ttf"))
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root }, onPhase: { phase in
            if phase == .applying { try? FileManager.default.removeItem(at: root) }
        })
        let events = await run(scanner, e.loc.id)
        #expect(isAborted(events.last))
        #expect(try faceCount(e.store) == before)
    }

    @Test func emptyEnumerationOfPopulatedIndexAbortsWithoutDeleting() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        _ = await run(LibraryScanner(store: e.store, rootURL: { _ in root }), e.loc.id)
        let before = try faceCount(e.store)
        let ghost = try TempFonts(); defer { ghost.cleanup() }  // exists but empty, like an unmounted volume's mount point
        let events = await run(LibraryScanner(store: e.store, rootURL: { _ in ghost.root }), e.loc.id)
        #expect(isAborted(events.last))
        #expect(try faceCount(e.store) == before)
    }

    @Test func cancelAbortsWithoutDeleting() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        _ = await run(LibraryScanner(store: e.store, rootURL: { _ in root }), e.loc.id)
        let before = try faceCount(e.store)
        try FileManager.default.removeItem(at: root.appendingPathComponent("SFNS.ttf"))
        let holder = Holder()
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root }, onPhase: { phase in
            if phase == .enumerating { holder.cancel() }
        })
        holder.scanner = scanner
        holder.id = e.loc.id
        let events = await run(scanner, e.loc.id)
        #expect(isAborted(events.last))
        #expect(try faceCount(e.store) == before)
    }

    private func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    @Test func unreadableSubfolderDoesNotBlockAddsButSkipsRemovals() async throws {
        let e = try makeEnv({
            try $0.copy(TempFonts.arialBold, as: "locked/Arial Bold.ttf")
            try $0.copy(TempFonts.sfns, as: "gone/SFNS.ttf")
        }); defer { e.t.cleanup() }
        let root = e.t.root
        let locked = root.appendingPathComponent("locked")
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        let before = try faceCount(e.store)
        try e.t.copy(TempFonts.avenirNext, as: "new/Avenir Next.ttc")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone/SFNS.ttf"))
        try chmod(locked, 0o000)
        defer { try? chmod(locked, 0o755) }

        let events = await run(scanner, e.loc.id)
        let last = try #require(events.last)
        #expect(last.phase == .done)
        #expect(last.unreadableCount == 1)
        #expect(last.unreadablePaths == ["locked"])
        #expect(last.skippedRemovals == 2)  // the deleted file and the unseen locked file
        let paths = Set(try e.store.files(in: e.loc.id).map(\.relativePath))
        #expect(paths == ["locked/Arial Bold.ttf", "gone/SFNS.ttf", "new/Avenir Next.ttc"])
        #expect(try faceCount(e.store) > before)
    }

    @Test func unreadableMovedFileKeepsOldRecord() async throws {
        let e = try makeEnv({ try $0.copy(TempFonts.arialBold, as: "a.ttf") }); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        _ = await run(scanner, e.loc.id)
        let before = try faceCount(e.store)
        let moved = root.appendingPathComponent("b.ttf")
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.ttf"), to: moved)
        try chmod(moved, 0o000)
        defer { try? chmod(moved, 0o644) }
        let events = await run(scanner, e.loc.id)
        let last = try #require(events.last)
        #expect(last.phase == .done)
        #expect(last.skippedRemovals == 1)
        #expect(last.unreadableCount >= 1)
        #expect(try faceCount(e.store) == before)
        #expect(try e.store.files(in: e.loc.id).map(\.relativePath) == ["a.ttf"])
    }

    @Test func restartedScanDoesNotOverlapCancelledRun() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        let first = await scanner.scan(locationID: e.loc.id)
        let second = await scanner.scan(locationID: e.loc.id)
        var firstEvents: [ScanProgress] = []
        for await p in first { firstEvents.append(p) }
        var secondEvents: [ScanProgress] = []
        for await p in second { secondEvents.append(p) }
        #expect(secondEvents.last?.phase == .done)
        #expect(secondEvents.last?.failed == 2)
        let expected = try [TempFonts.arialBold, TempFonts.avenirNext, TempFonts.sfns]
            .reduce(0) { $0 + (try FontParser.parse(url: URL(fileURLWithPath: $1))).count }
        #expect(try faceCount(e.store) == expected)
        #expect(firstEvents.last != nil)
    }

    @Test func droppingTheStreamCancelsTheScan() async throws {
        let e = try makeEnv(fixtures); defer { e.t.cleanup() }
        let root = e.t.root
        let scanner = LibraryScanner(store: e.store, rootURL: { _ in root })
        do { _ = await scanner.scan(locationID: e.loc.id) }  // stream dropped without iterating
        // A following scan waits for the cancelled one, so it must still complete normally.
        let events = await run(scanner, e.loc.id)
        #expect(events.last?.phase == .done)
    }

    final class Holder: @unchecked Sendable {
        var scanner: LibraryScanner?
        var id: Int64 = 0
        func cancel() { if let s = scanner { let i = id; Task { await s.cancel(locationID: i) } } }
    }
}
