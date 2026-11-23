import Foundation
import Testing
@testable import FontoryCore

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func increment() { lock.withLock { n += 1 } }
}

@Suite struct SystemFontInventoryTests {
    /// Reads nothing from disk: every file has one face named after the file.
    static func reader(_ url: URL) -> SystemFontInventory.FileContents? {
        let name = url.deletingPathExtension().lastPathComponent
        return SystemFontInventory.FileContents(
            size: 10, mtime: Date(timeIntervalSince1970: 1000), format: url.pathExtension.lowercased(),
            fingerprint: "fp-\(url.path)", faces: [Fixture.face(name, family: name, style: "Regular", weight: 400)])
    }

    func inventory(_ f: Fixture) -> SystemFontInventory {
        SystemFontInventory(
            store: f.store, readFile: Self.reader,
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0 })
    }

    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func ids(_ f: Fixture, _ scope: LibraryQuery.Scope) throws -> Set<Int64> {
        Set(try f.store.faceIDs(for: LibraryQuery(scope: scope)))
    }

    func names(_ f: Fixture, _ scope: LibraryQuery.Scope) throws -> Set<String> {
        let ids = try f.store.faceIDs(for: LibraryQuery(scope: scope))
        return Set(try f.store.rows(ids: ids).values.map(\.postScriptName))
    }

    @Test func flagsLibraryFilesRegisteredByOthersButNotFontorysOwn() async throws {
        let f = try Fixture.make()
        let own = f.faceIDs["Alpha-Regular"]!
        try f.store.setActivation(faceIDs: [own], state: .on, at: Date())
        let inv = inventory(f)
        // CoreText lists one URL per face, with a fragment; a collection appears several times.
        let snapshot = [
            url("/Volumes/A/Fonts/Alpha-Regular.otf"),
            URL(string: "file:///Volumes/A/Fonts/Alpha-Bold.otf#postscript-name=Alpha-Bold")!,
            URL(string: "file:///Volumes/A/Fonts/Alpha-Bold.otf#postscript-name=Alpha-BoldAlt")!,
        ]
        let first = try await inv.reconcile(available: snapshot)
        #expect(first.changed)
        #expect(first.indexedFiles == 0)

        let rows = try f.store.rows(ids: [own, f.faceIDs["Alpha-Bold"]!])
        #expect(rows[own]?.externalActive == false)
        #expect(rows[f.faceIDs["Alpha-Bold"]!]?.externalActive == true)
        #expect(try names(f, .user) == ["Alpha-Bold"])
        #expect(try names(f, .activated) == ["Alpha-Regular", "Alpha-Bold"])
        #expect(try names(f, .deactivated) == ["Alpha-Italic", "Beta-Light", "Beta-Regular", "Beta-Black"])
        #expect(rows[f.faceIDs["Alpha-Bold"]!]?.activationStatus == .external)
        #expect(rows[f.faceIDs["Alpha-Bold"]!]?.isActivationReadOnly == true)
        #expect(rows[own]?.activationStatus == .on)

        let again = try await inv.reconcile(available: snapshot)
        #expect(!again.changed)
    }

    @Test func indexesActiveFontsOutsideEveryLocationAsReadOnly() async throws {
        let f = try Fixture.make()
        let inv = inventory(f)
        let before = try f.store.faceIDs(for: LibraryQuery(scope: .recentImport))
        let result = try await inv.reconcile(available: [
            url("/System/Library/AssetsV2/Font7/Sys1.ttc"),
            url("/Users/me/Library/Application Support/Adobe/CoreSync/Ext1.otf"),
            url("/Users/me/Library/Application Support/Adobe/CoreSync/Ext2.otf"),
        ])
        #expect(result.indexedFiles == 3)
        #expect(result.locationsChanged)

        let auto = try f.store.locations().filter(\.autoIndexed)
        #expect(auto.count == 2)
        let sys = try #require(auto.first { $0.lastKnownPath == "/System/Library/AssetsV2/Font7" })
        #expect(sys.kind == .system)
        #expect(sys.displayName == "Font7")
        let user = try #require(auto.first { $0.lastKnownPath == "/Users/me/Library/Application Support/Adobe/CoreSync" })
        #expect(user.kind == .userInstalled)

        #expect(try names(f, .system) == ["Sys1"])
        #expect(try names(f, .user) == ["Ext1", "Ext2"])
        #expect(try names(f, .activated) == ["Sys1", "Ext1", "Ext2"])
        #expect(try f.store.faceIDs(for: LibraryQuery(scope: .deactivated)).count == 6)
        // Indexing what is active elsewhere is not an import.
        #expect(try f.store.faceIDs(for: LibraryQuery(scope: .recentImport)) == before)
        let rows = try f.store.rows(ids: try f.store.faceIDs(for: LibraryQuery(scope: .user)))
        #expect(rows.values.allSatisfy { $0.isActivationReadOnly && $0.activationStatus == .external })

        #expect(!(try await inv.reconcile(available: [
            url("/System/Library/AssetsV2/Font7/Sys1.ttc"),
            url("/Users/me/Library/Application Support/Adobe/CoreSync/Ext1.otf"),
            url("/Users/me/Library/Application Support/Adobe/CoreSync/Ext2.otf"),
        ])).changed)
    }

    @Test func clearsFlagsAndForgetsAutoIndexedFilesWhenNoLongerActive() async throws {
        let f = try Fixture.make()
        let inv = inventory(f)
        _ = try await inv.reconcile(available: [
            url("/Volumes/A/Fonts/Alpha-Bold.otf"),
            url("/Users/me/Fonts/Ext1.otf"),
            url("/Users/me/Fonts/Ext2.otf"),
        ])
        #expect(try names(f, .user) == ["Alpha-Bold", "Ext1", "Ext2"])

        let partly = try await inv.reconcile(available: [url("/Users/me/Fonts/Ext2.otf")])
        #expect(partly.changed)
        #expect(partly.removedFiles == 1)
        #expect(try names(f, .user) == ["Ext2"])
        #expect(try f.store.rows(ids: [f.faceIDs["Alpha-Bold"]!])[f.faceIDs["Alpha-Bold"]!]?.externalActive == false)

        let none = try await inv.reconcile(available: [])
        #expect(none.locationsChanged)
        #expect(try names(f, .user).isEmpty)
        #expect(try f.store.locations().filter(\.autoIndexed).isEmpty)
        #expect(try f.store.faceIDs(for: LibraryQuery()).count == 6)
    }

    @Test func unindexedFileInScannedLocationIsLeftToItsScan() async throws {
        let f = try Fixture.make()
        let inv = inventory(f)
        let result = try await inv.reconcile(available: [url("/Volumes/A/Fonts/sub/New.otf")])
        #expect(result.pendingLocationIDs == [f.locA.id])
        #expect(result.pendingPaths == [f.locA.id: ["/Volumes/A/Fonts/sub/New.otf"]])
        #expect(result.indexedFiles == 0)
        #expect(try f.store.locations().filter(\.autoIndexed).isEmpty)
    }

    @Test func neverWritesIntoAUsersFileSet() async throws {
        let f = try Fixture.make()
        let set = try f.store.upsertLocation(kind: .fileSet, volumeUUID: "ROOT", relativePath: "Volumes/C/Set", displayName: "Set",
                                             lastKnownPath: "/Volumes/C/Set")
        let inv = inventory(f)
        let result = try await inv.reconcile(available: [
            url("/Volumes/C/Set/Other.otf"),      // beside the set's files, not one of them
            url("/Volumes/C/Set/sub/Deep.otf"),   // in a subfolder of the set's folder
        ])
        #expect(try f.store.files(in: set.id).isEmpty)
        #expect(try f.store.locations().first { $0.id == set.id }?.autoIndexed == false)
        #expect(try f.store.locations().first { $0.id == set.id }?.kind == .fileSet)
        // The subfolder is outside every location: read-only auto-indexed. The set's own folder is the user's: skipped.
        #expect(result.indexedFiles == 1)
        let auto = try f.store.locations().filter(\.autoIndexed)
        #expect(auto.map(\.lastKnownPath) == ["/Volumes/C/Set/sub"])
        #expect(try names(f, .user) == ["Deep"])
        #expect(try names(f, .deactivated).isDisjoint(with: ["Other", "Deep"]))
    }

    @Test func aFolderTheUserAddsDuringAPassStaysTheUsers() async throws {
        let f = try Fixture.make()
        let store = f.store
        // The user adds the folder (with an activated font) while the inventory is reading the new file.
        let inv = SystemFontInventory(
            store: store,
            readFile: { url in
                if let loc = try? store.upsertLocation(kind: .folder, volumeUUID: "ROOT", relativePath: "Users/me/Fonts",
                                                       displayName: "Fonts", lastKnownPath: "/Users/me/Fonts"),
                   (try? store.files(in: loc.id))?.isEmpty == true {
                    _ = try? store.insertFile(FileRecord(locationID: loc.id, relativePath: "Mine.otf", size: 1, mtime: Date(),
                                                         format: "otf", fingerprint: "mine"),
                                              faces: [Fixture.face("Mine", family: "Mine", style: "Regular", weight: 400)],
                                              importBatch: 7)
                    let ids = (try? store.faceIDs(for: LibraryQuery(scope: .location(id: loc.id, subfolder: nil)))) ?? []
                    try? store.setActivation(faceIDs: ids, state: .on, at: Date())
                }
                return Self.reader(url)
            },
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0 })
        _ = try await inv.reconcile(available: [url("/Users/me/Fonts/Ext1.otf")])
        let loc = try #require(try store.locations().first { $0.lastKnownPath == "/Users/me/Fonts" })
        #expect(loc.kind == .folder)
        #expect(!loc.autoIndexed)
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["Mine.otf"])

        // Later passes leave the user's files (and their activation) alone.
        _ = try await inv.reconcile(available: [])
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["Mine.otf"])
        #expect(try store.faceIDs(state: .on).count == 1)
    }

    @Test func autoIndexedUpsertNeverClaimsAUserLocation() throws {
        let f = try Fixture.make()
        let claimed = try f.store.upsertLocation(kind: .userInstalled, volumeUUID: "VOL-A", relativePath: "Fonts",
                                                 displayName: "Auto", lastKnownPath: "/elsewhere", autoIndexed: true)
        #expect(claimed.id == f.locA.id)
        #expect(!claimed.autoIndexed && claimed.kind == .folder && claimed.displayName == "A")
        #expect(try f.store.files(in: f.locA.id).count == 3)
        // The other way round, the user taking over an auto-indexed folder, converts it.
        let auto = try f.store.upsertLocation(kind: .userInstalled, volumeUUID: "X", relativePath: "x", displayName: "x",
                                              lastKnownPath: "/x", autoIndexed: true)
        let mine = try f.store.upsertLocation(kind: .folder, volumeUUID: "X", relativePath: "x", displayName: "x", lastKnownPath: "/x")
        #expect(mine.id == auto.id && !mine.autoIndexed && mine.kind == .folder)
    }

    @Test func externalFlagIsNeverSetOnAFileFontoryActivated() throws {
        let f = try Fixture.make()
        try f.store.setActivation(faceIDs: [f.faceIDs["Alpha-Bold"]!], state: .on, at: Date())
        try f.store.setExternalActive(fileIDs: [f.fileIDs["Alpha-Bold.otf"]!, f.fileIDs["Alpha-Italic.otf"]!], true)
        let rows = try f.store.rows(ids: [f.faceIDs["Alpha-Bold"]!, f.faceIDs["Alpha-Italic"]!])
        #expect(rows[f.faceIDs["Alpha-Bold"]!]?.externalActive == false)
        #expect(rows[f.faceIDs["Alpha-Italic"]!]?.externalActive == true)
    }

    @Test func unreadableFilesAreNotReadAgainThisSession() async throws {
        let f = try Fixture.make()
        let calls = Counter()
        let inv = SystemFontInventory(
            store: f.store, readFile: { _ in calls.increment(); return nil },
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0 })
        let first = try await inv.reconcile(available: [url("/Users/me/Fonts/Broken.otf")])
        #expect(first.failedFiles == 1)
        let second = try await inv.reconcile(available: [url("/Users/me/Fonts/Broken.otf")])
        #expect(second.failedFiles == 0)
        #expect(calls.value == 1)
    }

    @Test func adobeFontsHiddenFilesAreIndexedAsUser() async throws {
        let f = try Fixture.make()
        let inv = SystemFontInventory(
            store: f.store,
            readFile: { url in
                SystemFontInventory.FileContents(size: 10, mtime: Date(timeIntervalSince1970: 1000), format: "otf", fingerprint: "fp-\(url.path)",
                                                 faces: [Fixture.face("AdobeSans-Regular", family: "Adobe Sans", style: "Regular", weight: 400)])
            },
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0 })
        let path = "/Users/me/Library/Application Support/Adobe/CoreSync/plugins/livetype/.r/.12345.otf"
        let result = try await inv.reconcile(available: [URL(string: "file://" + path.replacingOccurrences(of: " ", with: "%20") + "#postscript-name=AdobeSans-Regular")!])
        #expect(result.indexedFiles == 1)
        #expect(try names(f, .user) == ["AdobeSans-Regular"])
        #expect(try names(f, .activated) == ["AdobeSans-Regular"])
        let loc = try #require(try f.store.locations().first(where: \.autoIndexed))
        #expect(loc.kind == .userInstalled && loc.lastKnownPath.hasSuffix("/livetype/.r"))
        // Still active: kept on the next pass.
        #expect(!(try await inv.reconcile(available: [url(path)])).changed)
    }

    @Test func unreadableFileIsReadAgainOnceItChanges() async throws {
        let f = try Fixture.make()
        let temp = try TempFonts()
        defer { temp.cleanup() }
        let file = try temp.write(Data([1, 2, 3]), as: "Syncing.otf")
        let calls = Counter()
        let inv = SystemFontInventory(
            store: f.store, readFile: { _ in calls.increment(); return nil },
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0 })
        _ = try await inv.reconcile(available: [file])
        _ = try await inv.reconcile(available: [file])
        #expect(calls.value == 1)
        // The sync finishes: the file grows, so it is read again.
        try Data(repeating: 7, count: 64).write(to: file)
        _ = try await inv.reconcile(available: [file])
        #expect(calls.value == 2)
    }

    @Test func privateFacesAreIgnored() async throws {
        let f = try Fixture.make()
        let inv = SystemFontInventory(
            store: f.store,
            readFile: { url in
                var c = Self.reader(url)!
                c.faces.append(Fixture.face(".Hidden-Face", family: ".Hidden", style: "Regular", weight: 400, index: 1))
                return c
            },
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0 })
        let result = try await inv.reconcile(available: [
            url("/System/Library/PrivateFrameworks/FontServices.framework/Versions/A/Resources/Reserved/Res.ttc"),
            url("/System/Library/AssetsV2/Font7/.Secret.otf"),
            URL(string: "file:///Users/me/Other/Priv.otf#postscript-name=.PrivFace")!,
            url("/Users/me/Fonts/Public.otf"),
        ])
        #expect(result.indexedFiles == 1)
        #expect(try names(f, .user) == ["Public"])
        #expect(try names(f, .system).isEmpty)
    }
    @Test func offlineLocationsAreNeverFlagged() async throws {
        let f = try Fixture.make()
        try f.store.setLocationOnline(f.locB.id, online: false, lastKnownPath: nil)
        let inv = inventory(f)
        let result = try await inv.reconcile(available: [url("/Volumes/B/Type/Beta-Light.otf")])
        #expect(try names(f, .user).isEmpty)
        // A file on the offline location's old path is not indexed elsewhere either.
        #expect(result.indexedFiles == 0)
    }

    @Test func pathsMatchThroughSymlinkResolution() async throws {
        let f = try Fixture.make()
        let inv = SystemFontInventory(
            store: f.store, readFile: Self.reader,
            volumeRef: { VolumeRef(volumeUUID: "ROOT", relativePath: String($0.path.dropFirst())) },
            resolvePath: { $0.hasPrefix("/private/A/") ? "/Volumes/A/" + $0.dropFirst("/private/A/".count) : $0 })
        _ = try await inv.reconcile(available: [url("/private/A/Fonts/Alpha-Italic.otf")])
        #expect(try names(f, .user) == ["Alpha-Italic"])
        #expect(try f.store.locations().filter(\.autoIndexed).isEmpty)
    }
}
