import Foundation
import Testing
@testable import FontoryCore

@Suite struct RestoreTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func manifest(_ f: Fixture) throws -> BackupManifest {
        try f.store.makeBackupManifest(created: when, appVersion: "1", locationRank: [f.locB.id, f.locA.id], skipDuplicatesOnImport: true)
    }

    /// The library's user data, by PostScript name, read through the backup snapshot.
    private func snapshot(_ f: Fixture) throws -> BackupManifest { try manifest(f) }

    private func tagNames(_ m: BackupManifest, _ ps: String) -> Set<String> {
        guard let face = m.faces.first(where: { $0.postScriptName == ps }) else { return [] }
        return Set(face.tagIDs.compactMap { id in m.tags.first { $0.id == id }?.name })
    }

    private func index(_ m: BackupManifest, _ ps: String) -> Int { m.faces.firstIndex { $0.postScriptName == ps }! }

    /// Adds a face named `ps` in another file so the name is no longer unique in the library.
    private func duplicateName(_ g: inout Fixture, _ ps: String) throws {
        try g.add(g.locB.id, "Copy/\(ps).otf", [Fixture.face(ps, family: "Copy", style: "Regular", weight: 400)], try g.store.nextImportBatch())
    }

    /// A backup from `f` with one tag "T" on Alpha-Regular.
    private func taggedBackup() throws -> BackupManifest {
        let f = try Fixture.make()
        let t = try f.store.createTag(name: "T", parentID: nil)
        try f.store.addTag(t, toFaces: [f.faceIDs["Alpha-Regular"]!])
        return try manifest(f)
    }

    @Test func locationMapMatchesByVolumeAndPath() throws {
        let m = try taggedBackup()
        let g = try Fixture.make()
        let map = try g.store.locationMap(for: m)
        let a = m.locations.first { $0.volumeUUID == "VOL-A" }!.index
        let b = m.locations.first { $0.volumeUUID == "VOL-B" }!.index
        #expect(map == [a: g.locA.id, b: g.locB.id])
    }

    @Test func matchesByFingerprintFirst() throws {
        var m = try taggedBackup()
        m.faces[index(m, "Alpha-Regular")].relativePath = "Moved/Alpha-Regular.otf"
        var g = try Fixture.make()
        let original = g.faceIDs["Alpha-Regular"]!
        try duplicateName(&g, "Alpha-Regular")  // rule 3 cannot match; rule 2 has the wrong path
        let r = try g.store.restore(m, locationMap: try g.store.locationMap(for: m))
        #expect(r.notFound.isEmpty && r.restoredFaceCount == 1 && r.tagCount == 1)
        #expect(try g.store.tagIDs(forFaces: [original])[original]?.count == 1)
    }

    @Test func matchesByPathWhenFileChanged() throws {
        var m = try taggedBackup()
        m.faces[index(m, "Alpha-Regular")].fingerprint = "fp-old-version"
        var g = try Fixture.make()
        let original = g.faceIDs["Alpha-Regular"]!
        try duplicateName(&g, "Alpha-Regular")
        let r = try g.store.restore(m, locationMap: try g.store.locationMap(for: m))
        #expect(r.notFound.isEmpty)
        #expect(try g.store.tagIDs(forFaces: [original])[original]?.count == 1)
    }

    @Test func matchesByUniquePostScriptName() throws {
        var m = try taggedBackup()
        let i = index(m, "Alpha-Regular")
        m.faces[i].fingerprint = "fp-other"
        m.faces[i].relativePath = "Elsewhere/x.otf"
        m.faces[i].locationIndex = m.locations.first { $0.volumeUUID == "VOL-B" }!.index
        let g = try Fixture.make()
        let r = try g.store.restore(m, locationMap: try g.store.locationMap(for: m))
        #expect(r.notFound.isEmpty)
        #expect(tagNames(try snapshot(g), "Alpha-Regular") == ["T"])

        var h = try Fixture.make()
        try duplicateName(&h, "Alpha-Regular")
        let r2 = try h.store.restore(m, locationMap: try h.store.locationMap(for: m))
        #expect(r2.notFound == ["Alpha-Regular"] && r2.restoredFaceCount == 0)
        #expect(r2.tagCount == 1)  // the tag itself is still restored
    }

    @Test func replaceClearsUnmentioned() throws {
        let f = try Fixture.make()
        let keep = try f.store.createTag(name: "Keep", parentID: nil)
        try f.store.addTag(keep, toFaces: [f.faceIDs["Beta-Light"]!])
        let m = try manifest(f)

        let g = try Fixture.make()
        let old = try g.store.createTag(name: "Old", parentID: nil)
        try g.store.addTag(old, toFaces: [g.faceIDs["Alpha-Bold"]!])
        try g.store.setNote("stale", faceID: g.faceIDs["Alpha-Italic"]!)
        try g.store.setQuickCollection([g.faceIDs["Beta-Black"]!], included: true, at: when)
        try g.store.setCustomFamily("Zed", faceIDs: [g.faceIDs["Alpha-Regular"]!])
        try g.store.setRepresentative(familyKey: "beta", faceID: g.faceIDs["Beta-Black"]!)
        _ = try g.store.restore(m, locationMap: try g.store.locationMap(for: m))

        #expect(try g.store.tags().map(\.name) == ["Keep"])
        let s = try snapshot(g)
        #expect(s.faces.map(\.postScriptName) == ["Beta-Light"])
        #expect(s.faces[0].note == nil && s.faces[0].quickCollectionAdded == nil && s.faces[0].customFamily == nil)
        #expect(s.representatives.isEmpty)
        #expect(try g.store.quickCollectionFaceIDs().isEmpty)
    }

    @Test func restoresNotesQuickCollectionFamiliesAndRepresentatives() throws {
        let f = try Fixture.make()
        let parent = try f.store.createTag(name: "Serif", parentID: nil)
        let child = try f.store.createTag(name: "Old", parentID: parent)
        try f.store.addTag(child, toFaces: [f.faceIDs["Alpha-Bold"]!])
        try f.store.setNote("hello", faceID: f.faceIDs["Beta-Light"]!)
        let added = Date(timeIntervalSince1970: 4242)
        try f.store.setQuickCollection([f.faceIDs["Alpha-Italic"]!], included: true, at: added)
        try f.store.setCustomFamily("Gamma", faceIDs: [f.faceIDs["Beta-Regular"]!, f.faceIDs["Beta-Black"]!])
        try f.store.setRepresentative(familyKey: "gamma", faceID: f.faceIDs["Beta-Black"]!)
        let m = try manifest(f)

        let g = try Fixture.make()
        let r = try g.store.restore(m, locationMap: try g.store.locationMap(for: m))
        #expect(r.tagCount == 2 && r.notFound.isEmpty && r.restoredFaceCount == 5)
        let tags = try g.store.tags()
        let newParent = try #require(tags.first { $0.name == "Serif" })
        #expect(tags.first { $0.name == "Old" }?.parentID == newParent.id)
        let s = try snapshot(g)
        #expect(tagNames(s, "Alpha-Bold") == ["Old"])
        #expect(s.faces.first { $0.postScriptName == "Beta-Light" }?.note == "hello")
        #expect(s.faces.first { $0.postScriptName == "Alpha-Italic" }?.quickCollectionAdded == added)
        #expect(s.faces.first { $0.postScriptName == "Beta-Regular" }?.customFamily == "Gamma")
        let rep = try #require(s.representatives["gamma"])
        #expect(s.faces[rep].postScriptName == "Beta-Black")
        #expect(r.locationRank == [g.locB.id, g.locA.id] && r.skipDuplicatesOnImport)
        let gamma = try g.store.families(for: LibraryQuery()).first { $0.id == "gamma" }
        #expect(gamma?.representativeID == g.faceIDs["Beta-Black"])
    }

    @Test func remapsSmartRuleIDs() throws {
        let f = try Fixture.make()
        // Burn ids so the backup's tag ids differ from the ones the restore creates.
        let burned = try ["x1", "x2"].map { try f.store.createTag(name: $0, parentID: nil) }
        let target = try f.store.createTag(name: "Target", parentID: nil)
        for t in burned { try f.store.deleteTag(t) }
        var rule = SmartRule()
        rule.conditions = [
            .init(field: .tag, op: .has, value: .int(target)),
            .init(field: .location, op: .is, value: .int(f.locA.id)),
            .init(field: .location, op: .is, value: .int(f.locB.id)),
            .init(field: .name, op: .contains, value: .text("a")),
        ]
        _ = try f.store.createTag(name: "Smart", parentID: nil, kind: .smart, ruleJSON: rule.encoded())
        let m = try manifest(f)

        let g = try Fixture.make()
        try g.store.deleteLocation(g.locA.id)  // re-added below with a new id, so ids differ from the backup's
        let newA = try g.store.upsertLocation(kind: .folder, volumeUUID: "VOL-A", relativePath: "Fonts", displayName: "A", lastKnownPath: "/Volumes/A/Fonts")
        #expect(newA.id != f.locA.id)
        var map = try g.store.locationMap(for: m)
        map.removeValue(forKey: m.locations.first { $0.volumeUUID == "VOL-B" }!.index)
        _ = try g.store.restore(m, locationMap: map)
        let tags = try g.store.tags()
        let newTarget = try #require(tags.first { $0.name == "Target" }).id
        #expect(newTarget != target)
        let smart = try #require(tags.first { $0.name == "Smart" })
        #expect(smart.kind == .smart)
        let restored = try #require(SmartRule.decode(smart.ruleJSON ?? ""))
        #expect(restored.conditions[0].value == .int(newTarget))
        #expect(restored.conditions[2].value == .int(SmartRule.deletedID))
        #expect(restored.conditions[3] == rule.conditions[3])
        #expect(restored.conditions[1].value == .int(newA.id))
    }

    @Test func missingLocationFacesNotFound() throws {
        let f = try Fixture.make()
        let t = try f.store.createTag(name: "T", parentID: nil)
        try f.store.addTag(t, toFaces: [f.faceIDs["Alpha-Regular"]!, f.faceIDs["Beta-Light"]!])
        try f.store.setNote("n", faceID: f.faceIDs["Beta-Black"]!)
        let m = try manifest(f)

        // The library has never seen location B (its drive is unplugged): B's faces cannot match at all.
        let g = try Fixture.make()
        try g.store.deleteLocation(g.locB.id)
        let map = try g.store.locationMap(for: m)
        #expect(map.count == 1)
        let r = try g.store.restore(m, locationMap: map)
        #expect(Set(r.notFound) == ["Beta-Light", "Beta-Black"])
        #expect(r.unreachableLocations == ["B"])
        #expect(r.restoredFaceCount == 1)
        #expect(tagNames(try snapshot(g), "Alpha-Regular") == ["T"])
        #expect(r.locationRank == [g.locA.id])
    }

    @Test func missingLocationStillMatchesByFingerprint() throws {
        let m = try taggedBackup()
        let g = try Fixture.make()
        let r = try g.store.restore(m, locationMap: [:])  // no location mapped; rule 1 still applies
        #expect(r.notFound.isEmpty && r.restoredFaceCount == 1)
        #expect(Set(r.unreachableLocations) == ["A", "B"])
    }

    @Test func failureRollsBack() throws {
        var m = try taggedBackup()
        m.tags.append(.init(id: 77, parentID: 999, name: "Orphan", kind: 0, rule: nil))
        let g = try Fixture.make()
        let old = try g.store.createTag(name: "Old", parentID: nil)
        try g.store.addTag(old, toFaces: [g.faceIDs["Alpha-Bold"]!])
        try g.store.setNote("keep", faceID: g.faceIDs["Beta-Light"]!)
        let before = try snapshot(g)
        let map = try g.store.locationMap(for: m)
        #expect(throws: BackupError.self) { try g.store.restore(m, locationMap: map) }
        #expect(try snapshot(g) == before)

        var bad = try taggedBackup()
        bad.faces[0].locationIndex = 42
        #expect(throws: BackupError.self) { try g.store.restore(bad, locationMap: map) }
        var badRep = try taggedBackup()
        badRep.representatives["x"] = 9
        #expect(throws: BackupError.self) { try g.store.restore(badRep, locationMap: map) }
        #expect(try snapshot(g) == before)
    }

    @Test func activationReturnedNotApplied() throws {
        let f = try Fixture.make()
        try f.store.setActivation(faceIDs: [f.faceIDs["Beta-Black"]!], state: .temporary, at: when)
        try f.store.setActivation(faceIDs: [f.faceIDs["Alpha-Bold"]!], state: .on, at: when)
        let m = try manifest(f)
        let g = try Fixture.make()
        try g.store.setActivation(faceIDs: [g.faceIDs["Alpha-Italic"]!], state: .on, at: when)
        let r = try g.store.restore(m, locationMap: try g.store.locationMap(for: m))
        #expect(r.activations == [g.faceIDs["Beta-Black"]!: 2, g.faceIDs["Alpha-Bold"]!: 1])
        #expect(try g.store.faceIDs(state: .on) == [g.faceIDs["Alpha-Italic"]!])
        #expect(try g.store.faceIDs(state: .temporary).isEmpty)
    }
}
