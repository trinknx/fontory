import CoreText
import Foundation
import Testing
@testable import FontoryCore

final class FakeRegistrar: FontRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var _registerCalls: [[URL]] = []
    private var _unregisterCalls: [[URL]] = []
    private var _outcomes: [URL: RegistrationOutcome] = [:]
    private var _available: Set<String> = []

    var registerCalls: [[URL]] { lock.withLock { _registerCalls } }
    var unregisterCalls: [[URL]] { lock.withLock { _unregisterCalls } }
    var available: Set<String> {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }
    func setOutcome(_ o: RegistrationOutcome, for url: URL) { lock.withLock { _outcomes[url] = o } }

    func register(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
        lock.withLock { _registerCalls.append(urls); return Dictionary(uniqueKeysWithValues: urls.map { ($0, _outcomes[$0] ?? .ok) }) }
    }
    func unregister(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
        lock.withLock { _unregisterCalls.append(urls); return Dictionary(uniqueKeysWithValues: urls.map { ($0, _outcomes[$0] ?? .ok) }) }
    }
    func availablePostScriptNames() -> Set<String> { available }
}

@Suite struct ActivationServiceTests {
    let fixed = Date(timeIntervalSince1970: 5000)

    func service(_ f: Fixture, _ fake: FakeRegistrar) -> ActivationService {
        let d = fixed
        return ActivationService(store: f.store, registrar: fake, now: { d })
    }

    @Test func activateRegistersFileAndMarksAllFacesInFile() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locA.id, "Multi.ttc", (0..<3).map { Fixture.face("Multi-\($0)", family: "Multi", style: "S\($0)", weight: 400, index: $0) }, batch)
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        let ids = ["Multi-0", "Multi-1", "Multi-2"].map { f.faceIDs[$0]! }
        let report = await svc.set([ids[1]], to: .on)
        #expect(fake.registerCalls.count == 1)
        #expect(fake.registerCalls[0].count == 1)
        #expect(fake.registerCalls[0][0].lastPathComponent == "Multi.ttc")
        #expect(Set(report.changedFaceIDs) == Set(ids))
        let rows = try f.store.rows(ids: ids)
        for id in ids {
            #expect(rows[id]?.activation == .on)
            #expect(rows[id]?.lastActivated == fixed)
        }
    }

    @Test func temporaryThenClearTemporaryUnregisters() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        let id = f.faceIDs["Alpha-Regular"]!
        _ = await svc.set([id], to: .temporary)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .temporary)
        let report = await svc.clearTemporary()
        #expect(report.changedFaceIDs == [id])
        #expect(fake.unregisterCalls.count == 1)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .off)
    }

    @Test func restoreOnLaunchRegistersOnAndResetsTemp() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        let on = f.faceIDs["Alpha-Regular"]!, temp = f.faceIDs["Beta-Light"]!
        try f.store.setActivation(faceIDs: [on], state: .on, at: fixed)
        try f.store.setActivation(faceIDs: [temp], state: .temporary, at: fixed)
        _ = await svc.restoreOnLaunch()
        #expect(fake.registerCalls.count == 1)
        #expect(fake.registerCalls[0].map(\.lastPathComponent) == ["Alpha-Regular.otf"])
        let rows = try f.store.rows(ids: [on, temp])
        #expect(rows[on]?.activation == .on)
        #expect(rows[temp]?.activation == .off)
    }

    @Test func conflictIsReportedNotRegistered() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        fake.available = ["Alpha-Regular"]
        let svc = service(f, fake)
        let id = f.faceIDs["Alpha-Regular"]!
        let report = await svc.set([id], to: .on)
        #expect(report.conflicts == [id: "Alpha-Regular"])
        #expect(fake.registerCalls.isEmpty)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .off)
        let forced = await svc.set([id], to: .on, force: true)
        #expect(forced.conflicts.isEmpty)
        #expect(fake.registerCalls.count == 1)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .on)
    }

    /// The id of the (first) face stored in the file at `path`.
    func faceID(_ f: Fixture, file path: String) throws -> Int64 {
        let fileID = try #require(f.fileIDs[path])
        let rows = try f.store.rows(ids: try f.store.faceIDs(for: LibraryQuery()))
        return try #require(rows.values.filter { $0.fileID == fileID }.min { $0.faceIndex < $1.faceIndex }?.id)
    }

    @Test func sameFileAlreadyActiveIsNotAConflict() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        let id = f.faceIDs["Alpha-Regular"]!
        _ = await svc.set([id], to: .on)
        fake.available = ["Alpha-Regular"]  // now visible to the system because Fontory registered it
        let report = await svc.set([id], to: .temporary)
        #expect(report.conflicts.isEmpty)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .temporary)
    }

    @Test func secondFileWithSameNameAlreadyOnIsAConflict() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locB.id, "Copy/Alpha-Regular.otf", [Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400)], batch)
        let a = try faceID(f, file: "Alpha-Regular.otf"), b = try faceID(f, file: "Copy/Alpha-Regular.otf")
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        _ = await svc.set([a], to: .on)
        fake.available = ["Alpha-Regular"]
        let report = await svc.set([b], to: .on)
        #expect(report.conflicts == [b: "Alpha-Regular"])
        #expect(fake.registerCalls.count == 1)
        #expect(try f.store.rows(ids: [b])[b]?.activation == .off)
    }

    @Test func secondFileIsAConflictEvenWhenTheFirstIsNotVisibleToTheSystem() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locB.id, "Copy/Alpha-Regular.otf", [Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400)], batch)
        let a = try faceID(f, file: "Alpha-Regular.otf"), b = try faceID(f, file: "Copy/Alpha-Regular.otf")
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        _ = await svc.set([a], to: .on)  // registrar reports nothing available: e.g. the first copy is offline
        let report = await svc.set([b], to: .temporary)
        #expect(report.conflicts == [b: "Alpha-Regular"])
    }

    @Test func twoSameNameFilesInOneBatchFirstWins() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locB.id, "Copy/Alpha-Regular.otf", [Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400)], batch)
        let a = try faceID(f, file: "Alpha-Regular.otf"), b = try faceID(f, file: "Copy/Alpha-Regular.otf")
        let fake = FakeRegistrar()
        let report = await service(f, fake).set([a, b], to: .on)
        #expect(report.conflicts == [b: "Alpha-Regular"])
        #expect(report.changedFaceIDs == [a])
        #expect(fake.registerCalls.count == 1)
        #expect(fake.registerCalls[0].map(\.lastPathComponent) == ["Alpha-Regular.otf"])
        #expect(fake.registerCalls[0][0].path.contains("Copy") == false)
    }

    @Test func forceRegistersBothSameNameFiles() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locB.id, "Copy/Alpha-Regular.otf", [Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400)], batch)
        let a = try faceID(f, file: "Alpha-Regular.otf"), b = try faceID(f, file: "Copy/Alpha-Regular.otf")
        let fake = FakeRegistrar()
        let report = await service(f, fake).set([a, b], to: .on, force: true)
        #expect(report.conflicts.isEmpty)
        #expect(Set(report.changedFaceIDs) == [a, b])
        #expect(fake.registerCalls.count == 1)
        #expect(fake.registerCalls[0].count == 2)
    }

    @Test func collectionSiblingsSkippedByAConflictAreReported() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locB.id, "Pair.ttc", [
            Fixture.face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400, index: 0),
            Fixture.face("Pair-Bold", family: "Pair", style: "Bold", weight: 700, index: 1),
        ], batch)
        let fileID = try #require(f.fileIDs["Pair.ttc"])
        let rows = try f.store.rows(ids: try f.store.faceIDs(for: LibraryQuery())).values.filter { $0.fileID == fileID }
        let clash = try #require(rows.first { $0.faceIndex == 0 }?.id), sibling = try #require(rows.first { $0.faceIndex == 1 }?.id)
        let fake = FakeRegistrar()
        fake.available = ["Alpha-Regular"]
        let report = await service(f, fake).set([sibling], to: .on)
        #expect(report.conflicts == [clash: "Alpha-Regular", sibling: "Alpha-Regular"])
        #expect(fake.registerCalls.isEmpty)
    }

    @Test func alreadyRegisteredCountsAsSuccess() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        let id = f.faceIDs["Alpha-Regular"]!
        fake.setOutcome(.alreadyRegistered, for: try #require(try f.store.rows(ids: [id])[id]?.fileURL))
        let report = await service(f, fake).set([id], to: .on)
        #expect(report.failures.isEmpty)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .on)
    }

    @Test func failureKeepsState() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        let id = f.faceIDs["Alpha-Regular"]!
        fake.setOutcome(.failed("boom"), for: try #require(try f.store.rows(ids: [id])[id]?.fileURL))
        let report = await service(f, fake).set([id], to: .on)
        #expect(report.failures[id] == "boom")
        #expect(report.changedFaceIDs.isEmpty)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .off)
    }

    @Test func offlineFaceChangesStateWithoutRegistering() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        try f.store.setLocationOnline(f.locA.id, online: false, lastKnownPath: nil)
        let id = f.faceIDs["Alpha-Regular"]!
        let report = await service(f, fake).set([id], to: .on)
        #expect(fake.registerCalls.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(try f.store.rows(ids: [id])[id]?.activation == .on)
    }

    @Test func unmountUnregistersButKeepsState_mountReregisters() async throws {
        let f = try Fixture.make()
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        let id = f.faceIDs["Alpha-Regular"]!
        _ = await svc.set([id], to: .on)
        await svc.volumeUnmounted(locationIDs: [f.locA.id])
        await svc.volumeUnmounted(locationIDs: [f.locA.id])  // idempotent
        #expect(fake.unregisterCalls.count == 2)
        #expect(fake.unregisterCalls[0].map(\.lastPathComponent) == ["Alpha-Regular.otf"])
        #expect(try f.store.rows(ids: [id])[id]?.activation == .on)
        let report = await svc.volumeMounted(locationIDs: [f.locA.id])
        #expect(fake.registerCalls.count == 2)
        #expect(report.changedFaceIDs == [id])
        #expect(report.failures.isEmpty)
        // A location with nothing active is a no-op.
        await svc.volumeUnmounted(locationIDs: [f.locB.id])
        #expect(fake.unregisterCalls.last?.isEmpty == true)
    }

    @Test func batchActivationIsOneCall() async throws {
        let f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.store.database.transaction {
            for i in 0..<500 {
                let file = FileRecord(locationID: f.locA.id, relativePath: "bulk/F\(i).otf", size: 10, mtime: fixed, format: "otf", fingerprint: "bulk-\(i)")
                _ = try f.store.insertFile(file, faces: [Fixture.face("Bulk-\(i)", family: "Bulk", style: "S\(i)", weight: 400)], importBatch: batch)
            }
        }
        let ids = try f.store.faceIDs(for: LibraryQuery()).filter { id in
            (try? f.store.rows(ids: [id])[id]?.postScriptName.hasPrefix("Bulk-")) == true
        }
        #expect(ids.count == 500)
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        let start = Date()
        let report = await svc.set(ids, to: .on)
        let elapsed = Date().timeIntervalSince(start)
        #expect(fake.registerCalls.count == 1)
        #expect(fake.registerCalls[0].count == 500)
        #expect(report.changedFaceIDs.count == 500)
        #expect(elapsed < 0.2, "took \(elapsed)s")
    }

    @Test func coreTextRegistrarRoundTripInProcessScope() async throws {
        let t = try TempFonts()
        defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        let reg = CoreTextRegistrar(scope: .process)
        let r = await reg.register([url])
        #expect(r[url] == .ok || r[url] == .alreadyRegistered)
        let u = await reg.unregister([url])
        #expect(u[url] == .ok || u[url] == .alreadyRegistered)
        let again = await reg.unregister([url])
        #expect(again[url] == .alreadyRegistered || again[url] == .ok)
        #expect(await reg.register([]).isEmpty)
    }

    @Test func registrarAttributesErrorsToInputURLWithDotDotPath() async throws {
        let reg = CoreTextRegistrar(scope: .process)
        let url = URL(fileURLWithPath: "/tmp/../tmp/fontory-missing-\(UUID().uuidString).ttf")
        let r = await reg.register([url])
        guard case .failed = r[url] else { Issue.record("expected .failed, got \(String(describing: r[url]))"); return }
    }

    @Test func restoreOnLaunchNormalisesMixedFileToOn() async throws {
        var f = try Fixture.make()
        let batch = try f.store.nextImportBatch()
        try f.add(f.locA.id, "Mix.ttc", (0..<2).map { Fixture.face("Mix-\($0)", family: "Mix", style: "S\($0)", weight: 400, index: $0) }, batch)
        let a = f.faceIDs["Mix-0"]!, b = f.faceIDs["Mix-1"]!
        try f.store.setActivation(faceIDs: [a], state: .on, at: fixed)
        try f.store.setActivation(faceIDs: [b], state: .temporary, at: fixed)
        let fake = FakeRegistrar()
        let svc = service(f, fake)
        _ = await svc.restoreOnLaunch()
        let rows = try f.store.rows(ids: [a, b])
        #expect(rows[a]?.activation == .on)
        #expect(rows[b]?.activation == .on)
        _ = await svc.clearTemporary()
        #expect(fake.unregisterCalls.flatMap { $0 }.isEmpty)
    }

    @Test func unattributedErrorIsResolvedAgainstAvailability() {
        let a = URL(fileURLWithPath: "/tmp/fontory-a.ttf"), b = URL(fileURLWithPath: "/tmp/fontory-b.ttf")
        let err = CoreTextRegistrar.RegistrationError(code: 101, description: "boom", urls: [])
        let reg = CoreTextRegistrar.outcomes(inputs: [a, b], errors: [err], enabled: true, benign: .alreadyRegistered,
                                             availableURLs: { [a] })
        #expect(reg[a] == .ok)
        #expect(reg[b] == .failed("boom"))
        let unreg = CoreTextRegistrar.outcomes(inputs: [a, b], errors: [err], enabled: false, benign: .notRegistered,
                                               availableURLs: { [a] })
        #expect(unreg[a] == .failed("boom"))
        #expect(unreg[b] == .ok)
    }

    @Test func partiallyMatchedErrorResolvesUnmatchedInputThroughAvailability() {
        let a = URL(fileURLWithPath: "/tmp/fontory-a.ttf"), b = URL(fileURLWithPath: "/tmp/fontory-b.ttf")
        let c = URL(fileURLWithPath: "/tmp/fontory-c.ttf")
        // The error names a (matches) and a path no input has; b and c are left to availability.
        let err = CoreTextRegistrar.RegistrationError(
            code: 101, description: "boom", urls: [a, URL(fileURLWithPath: "/tmp/other/unknown.ttf")])
        let r = CoreTextRegistrar.outcomes(inputs: [a, b, c], errors: [err], enabled: true, benign: .alreadyRegistered,
                                           availableURLs: { [b] })
        #expect(r[a] == .failed("boom"))
        #expect(r[b] == .ok)
        #expect(r[c] == .failed("boom"))
    }

    @Test func attributedBenignErrorIsAlreadyRegisteredWithoutConsultingAvailability() {
        let a = URL(fileURLWithPath: "/tmp/fontory-a.ttf")
        let err = CoreTextRegistrar.RegistrationError(code: Int(CTFontManagerError.alreadyRegistered.rawValue), description: "dup", urls: [a])
        let r = CoreTextRegistrar.outcomes(inputs: [a], errors: [err], enabled: true, benign: .alreadyRegistered,
                                           availableURLs: { Issue.record("should not be called"); return [] })
        #expect(r[a] == .alreadyRegistered)
    }
}
