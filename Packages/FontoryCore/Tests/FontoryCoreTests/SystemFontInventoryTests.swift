import Foundation
import Testing
@testable import FontoryCore

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

    @Test func unindexedFileInScannedLocationIsLeftToItsScanButFileSetsTakeIt() async throws {
        let f = try Fixture.make()
        let set = try f.store.upsertLocation(kind: .fileSet, volumeUUID: "VOL-C", relativePath: "Set", displayName: "Set",
                                             lastKnownPath: "/Volumes/C/Set")
        let inv = inventory(f)
        let result = try await inv.reconcile(available: [
            url("/Volumes/A/Fonts/sub/New.otf"),
            url("/Volumes/C/Set/Other.otf"),
        ])
        #expect(result.pendingLocationIDs == [f.locA.id])
        #expect(result.pendingPaths == ["/Volumes/A/Fonts/sub/New.otf"])
        #expect(result.indexedFiles == 1)
        #expect(try f.store.files(in: set.id).map(\.relativePath) == ["Other.otf"])
        #expect(try names(f, .user) == ["Other"])
        #expect(try f.store.locations().filter(\.autoIndexed).isEmpty)
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
