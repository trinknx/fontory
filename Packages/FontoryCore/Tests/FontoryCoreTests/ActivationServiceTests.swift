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

    @Test func fontoryOwnActiveFaceIsNotAConflict() async throws {
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
        var f = try Fixture.make()
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
        _ = f.faceIDs  // silence unused-mutation
        f.faceIDs = [:]
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
}
