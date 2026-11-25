import Foundation
import Testing
@testable import FontoryCore

@Suite struct GoogleStoreTests {
    private func fam(_ name: String, modified: String = "2024-01-01", designers: [String] = ["A", "B"]) -> GoogleFamily {
        GoogleFamily(family: name, category: "Serif", lastModified: modified, subsets: ["latin", "vietnamese"],
                     designers: designers, popularity: 1, size: nil)
    }

    private func makeStore() throws -> FontStore { try FontStore(database: Database(path: ":memory:")) }

    private func states(_ store: FontStore) throws -> [String: GoogleFamilyState] {
        // Withdrawn rows are visible through this helper only via the raw table.
        try store.database.withLock {
            let s = try store.database.prepare("SELECT family, folder, last_modified, downloaded_modified, status, error, withdrawn FROM google_families")
            defer { s.reset() }
            var out: [String: GoogleFamilyState] = [:]
            while try s.step() {
                out[s.text(0)] = GoogleFamilyState(family: s.text(0), folder: s.text(1), lastModified: s.text(2),
                                                   downloadedModified: s.isNull(3) ? nil : s.text(3), status: Int(s.int64(4)),
                                                   error: s.isNull(5) ? nil : s.text(5), withdrawn: s.int64(6) != 0)
            }
            return out
        }
    }

    @Test func syncInsertsWithUniqueFolders() throws {
        let store = try makeStore()
        let summary = try store.syncGoogleCatalog([fam("Foo"), fam("FOO"), fam("A/B")])
        #expect(summary == GoogleSyncSummary(added: 3, updated: 0, withdrawn: 0))
        let s = try states(store)
        #expect(s["Foo"]?.folder == "Foo")
        #expect(s["FOO"]?.folder == "FOO (2)")
        #expect(s["A/B"]?.folder == "A-B")
        let rows = try store.googleFamiliesNeedingDownload()
        #expect(rows.count == 3)
    }

    @Test func syncUpdatesMetadataKeepsFolderAndDownloadState() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("Foo"), fam("FOO")])
        try store.markGoogleFamilyDone("Foo", modified: "2024-01-01", installedFiles: [])
        #expect(try store.googleFamiliesNeedingDownload().map(\.family) == ["FOO"])
        // Metadata-only change is not an update and keeps the done state.
        var summary = try store.syncGoogleCatalog([fam("Foo", designers: ["Z"]), fam("FOO")])
        #expect(summary == GoogleSyncSummary(added: 0, updated: 0, withdrawn: 0))
        #expect(try store.googleFamiliesNeedingDownload().map(\.family) == ["FOO"])
        summary = try store.syncGoogleCatalog([fam("Foo", modified: "2025-02-02"), fam("FOO")])
        #expect(summary == GoogleSyncSummary(added: 0, updated: 1, withdrawn: 0))
        let s = try states(store)
        #expect(s["Foo"]?.folder == "Foo")
        #expect(s["Foo"]?.downloadedModified == "2024-01-01")
        #expect(s["Foo"]?.lastModified == "2025-02-02")
        #expect(s["Foo"]?.status == 0)
        #expect(try store.googleFamiliesNeedingDownload().map(\.family) == ["FOO", "Foo"])
    }

    @Test func syncFlagsWithdrawnNeverDeletes() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("Foo"), fam("A/B")])
        var summary = try store.syncGoogleCatalog([fam("Foo")])
        #expect(summary == GoogleSyncSummary(added: 0, updated: 0, withdrawn: 1))
        #expect(try states(store)["A/B"]?.withdrawn == true)
        #expect(try store.googleFamiliesNeedingDownload().map(\.family) == ["Foo"])
        #expect(try store.googleProgress() == (0, 1))
        // Already-withdrawn rows are not counted again.
        summary = try store.syncGoogleCatalog([fam("Foo")])
        #expect(summary.withdrawn == 0)
        summary = try store.syncGoogleCatalog([fam("Foo"), fam("A/B")])
        #expect(summary == GoogleSyncSummary(added: 0, updated: 0, withdrawn: 0))
        let s = try states(store)
        #expect(s["A/B"]?.withdrawn == false)
        #expect(s["A/B"]?.folder == "A-B")
        #expect(try store.googleProgress() == (0, 2))
    }

    @Test func doneAndFailedStates() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("Foo"), fam("Bar")])
        try store.markGoogleFamilyDone("Foo", modified: "2024-01-01", installedFiles: [])
        try store.markGoogleFamilyFailed("Bar", error: "boom")
        let need = try store.googleFamiliesNeedingDownload()
        #expect(need.map(\.family) == ["Bar"])
        #expect(need[0].error == "boom")
        #expect(need[0].status == 2)
        let s = try states(store)
        #expect(s["Foo"]?.status == 1)
        #expect(s["Foo"]?.error == nil)
    }

    @Test func progressCounts() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("A"), fam("B"), fam("C")])
        try store.markGoogleFamilyDone("A", modified: "2024-01-01", installedFiles: [])
        #expect(try store.googleProgress() == (1, 3))
    }

    @Test func resetDownloadsMakesEveryFamilyPending() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("A"), fam("B"), fam("C")])
        try store.markGoogleFamilyDone("A", modified: "2024-01-01", installedFiles: [])
        try store.markGoogleFamilyFailed("B", error: "boom")
        _ = try store.syncGoogleCatalog([fam("A"), fam("B")])  // C withdrawn
        try store.resetGoogleDownloads()
        let s = try states(store)
        for name in ["A", "B", "C"] {
            #expect(s[name]?.downloadedModified == nil)
            #expect(s[name]?.status == 0)
            #expect(s[name]?.error == nil)
        }
        // Withdrawn rows keep their flag and stay out of the download list.
        #expect(s["C"]?.withdrawn == true)
        #expect(try store.googleFamiliesNeedingDownload().map(\.family) == ["A", "B"])
        #expect(try store.googleProgress() == (0, 2))
    }

    @Test func doneRecordsInstalledFiles() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("A")])
        try store.markGoogleFamilyDone("A", modified: "2024-01-01", installedFiles: ["OFL.txt", "A-Bold.ttf"])
        _ = try store.syncGoogleCatalog([fam("A", modified: "2025-01-01")])
        let need = try store.googleFamiliesNeedingDownload()
        #expect(need.map(\.family) == ["A"])
        #expect(need[0].installedFiles == ["OFL.txt", "A-Bold.ttf"])
    }

    @Test func resetClearsInstalledFiles() throws {
        let store = try makeStore()
        _ = try store.syncGoogleCatalog([fam("A")])
        try store.markGoogleFamilyDone("A", modified: "2024-01-01", installedFiles: ["OFL.txt", "A-Bold.ttf"])
        try store.resetGoogleDownloads()
        let need = try store.googleFamiliesNeedingDownload()
        #expect(need.map(\.family) == ["A"])
        #expect(need[0].installedFiles.isEmpty)
        try store.database.withLock {
            let s = try store.database.prepare("SELECT installed_files FROM google_families WHERE family = 'A'")
            defer { s.reset() }
            #expect(try s.step())
            #expect(s.isNull(0))
        }
    }
}
