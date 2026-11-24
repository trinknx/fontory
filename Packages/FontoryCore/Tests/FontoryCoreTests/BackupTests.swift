import Foundation
import Testing
@testable import FontoryCore

@Suite struct BackupTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func manifest(_ f: Fixture) throws -> BackupManifest {
        try f.store.makeBackupManifest(created: when, appVersion: "1.2.3", locationRank: [f.locB.id, 9999, f.locA.id], skipDuplicatesOnImport: true)
    }

    /// Writes a ZIP whose manifest.json holds `json`.
    private func zip(json: String, in dir: URL, name: String = "x.fontorybackup") throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try json.write(to: src.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", src.path, out.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return out
    }

    @Test func manifestListsOnlyUserData() throws {
        let f = try Fixture.make()
        let parent = try f.store.createTag(name: "Serif", parentID: nil)
        let child = try f.store.createTag(name: "Old", parentID: parent)
        let rule = #"{"all":[]}"#
        let smart = try f.store.createTag(name: "Smart", parentID: nil, kind: .smart, ruleJSON: rule)
        try f.store.addTag(child, toFaces: [f.faceIDs["Alpha-Regular"]!])
        try f.store.setNote("hello", faceID: f.faceIDs["Beta-Light"]!)
        let m = try manifest(f)
        #expect(m.format == "fontory-backup" && m.version == 1 && m.appVersion == "1.2.3" && m.created == when)
        #expect(m.faces.count == 2)
        let tagged = try #require(m.faces.first { $0.postScriptName == "Alpha-Regular" })
        #expect(tagged.tagIDs == [child] && tagged.fingerprint == "fp-Alpha-Regular.otf" && tagged.relativePath == "Alpha-Regular.otf")
        #expect(m.faces.first { $0.postScriptName == "Beta-Light" }?.note == "hello")
        #expect(m.tags.count == 3)
        #expect(m.tags.first { $0.id == child }?.parentID == parent)
        #expect(m.tags.first { $0.id == smart }?.rule == rule)
        #expect(m.settings.skipDuplicatesOnImport)
        #expect(m.locations.first { $0.volumeUUID == "VOL-A" }?.id == f.locA.id)
        #expect(m.locations.first { $0.volumeUUID == "VOL-B" }?.id == f.locB.id)
        #expect(m.settings.locationRank == [m.locations.first { $0.volumeUUID == "VOL-B" }!.index, m.locations.first { $0.volumeUUID == "VOL-A" }!.index])
    }

    @Test func userDataKindsAndRepresentatives() throws {
        let f = try Fixture.make()
        let now = Date(timeIntervalSince1970: 5000)
        try f.store.setQuickCollection([f.faceIDs["Alpha-Italic"]!], included: true, at: now)
        try f.store.setCustomFamily("Zed", faceIDs: [f.faceIDs["Alpha-Bold"]!])
        try f.store.setActivation(faceIDs: [f.faceIDs["Beta-Black"]!], state: .temporary, at: now)
        try f.store.setRepresentative(familyKey: "beta", faceID: f.faceIDs["Beta-Regular"]!)
        let m = try manifest(f)
        #expect(Set(m.faces.map(\.postScriptName)) == ["Alpha-Italic", "Alpha-Bold", "Beta-Black", "Beta-Regular"])
        #expect(m.faces.first { $0.postScriptName == "Alpha-Italic" }?.quickCollectionAdded == now)
        #expect(m.faces.first { $0.postScriptName == "Alpha-Bold" }?.customFamily == "Zed")
        #expect(m.faces.first { $0.postScriptName == "Beta-Black" }?.activation == 2)
        let idx = try #require(m.representatives["beta"])
        #expect(m.faces[idx].postScriptName == "Beta-Regular")
    }

    @Test func fileSetListsMembers() throws {
        var f = try Fixture.make()
        let set = try f.store.upsertLocation(kind: .fileSet, volumeUUID: "VOL-S", relativePath: "set1", displayName: "Set", lastKnownPath: "/x/set1")
        let b = try f.store.nextImportBatch()
        try f.add(set.id, "One.otf", [Fixture.face("One", family: "One", style: "Regular", weight: 400)], b)
        try f.add(set.id, "Two.otf", [Fixture.face("Two", family: "Two", style: "Regular", weight: 400)], b)
        let m = try manifest(f)
        let loc = try #require(m.locations.first { $0.volumeUUID == "VOL-S" })
        #expect(loc.kind == 1 && loc.members == ["One.otf", "Two.otf"])
        #expect(m.locations.first { $0.volumeUUID == "VOL-A" }?.members == nil)
    }

    @Test func systemLocationsIncludedForIdentity() throws {
        let f = try Fixture.make()
        _ = try f.store.upsertLocation(kind: .system, volumeUUID: "VOL-SYS", relativePath: "System/Library/Fonts", displayName: "System", lastKnownPath: "/System/Library/Fonts")
        let m = try manifest(f)
        #expect(m.locations.count == 3)
        #expect(m.locations.contains { $0.kind == 2 && $0.displayName == "System" })
        #expect(m.locations.map(\.index) == [0, 1, 2])
    }

    @Test func archiveRoundTrip() throws {
        let f = try Fixture.make()
        let t = try f.store.createTag(name: "T", parentID: nil)
        try f.store.addTag(t, toFaces: [f.faceIDs["Alpha-Regular"]!])
        try f.store.setNote("ünïcode ✓", faceID: f.faceIDs["Beta-Light"]!)
        let m = try manifest(f)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.fontorybackup")
        try BackupArchive.write(m, to: url)
        #expect(try BackupArchive.read(url) == m)
        try BackupArchive.write(m, to: url)  // overwrite works
        #expect(try BackupArchive.read(url) == m)
    }

    @Test func rejectsForeignZip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try zip(json: #"{"format":"other"}"#, in: dir)
        #expect(throws: BackupError.notABackup) { try BackupArchive.read(url) }
    }

    @Test func rejectsFutureVersion() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try zip(json: #"{"format":"fontory-backup","version":2}"#, in: dir)
        #expect(throws: BackupError.unsupportedVersion(2)) { try BackupArchive.read(url) }
    }

    @Test func rejectsTruncatedFile() throws {
        let f = try Fixture.make()
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.fontorybackup")
        try BackupArchive.write(try manifest(f), to: url)
        let cut = dir.appendingPathComponent("cut.fontorybackup")
        try Data(contentsOf: url).prefix(100).write(to: cut)
        #expect(throws: (any Error).self) { try BackupArchive.read(cut) }
        let missing = dir.appendingPathComponent("nope.fontorybackup")
        #expect(throws: (any Error).self) { try BackupArchive.read(missing) }
    }

    @Test func writeFailureKeepsExistingFile() throws {
        let f = try Fixture.make()
        let m = try manifest(f)
        let dir = try tempDir()
        let url = dir.appendingPathComponent("a.fontorybackup")
        try BackupArchive.write(m, to: url)
        var newer = m; newer.appVersion = "9"
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(throws: (any Error).self) { try BackupArchive.write(newer, to: url) }
        #expect(try BackupArchive.read(url) == m)
    }
}
