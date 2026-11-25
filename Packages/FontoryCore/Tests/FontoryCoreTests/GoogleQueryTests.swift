import Foundation
import Testing
@testable import FontoryCore

@Suite struct GoogleQueryTests {
    private func fam(_ name: String, category: String = "Sans Serif", subsets: [String] = ["latin"], popularity: Int = 1) -> GoogleFamily {
        GoogleFamily(family: name, category: category, lastModified: "2024-01-01", subsets: subsets,
                     designers: ["D"], popularity: popularity, size: nil)
    }

    private struct Env {
        let store: FontStore
        let google: LocationRecord
        let folder: LocationRecord
        var n = 0
    }

    private func makeEnv() throws -> Env {
        let store = try FontStore(database: Database(path: ":memory:"))
        let g = try store.upsertLocation(kind: .googleFonts, volumeUUID: "V", relativePath: "G", displayName: "Google Fonts", lastKnownPath: "/G")
        let f = try store.upsertLocation(kind: .folder, volumeUUID: "V2", relativePath: "F", displayName: "F", lastKnownPath: "/F")
        return Env(store: store, google: g, folder: f)
    }

    /// Inserts one file with one face; returns the face family name -> id via the postscript name.
    private func add(_ env: Env, _ loc: LocationRecord, _ path: String, family: String) throws {
        let ps = family.replacingOccurrences(of: " ", with: "") + "-" + String(path.hashValue & 0xffff)
        let face = Fixture.face(ps, family: family, style: "Regular", weight: 400)
        _ = try env.store.insertFile(FileRecord(locationID: loc.id, relativePath: path, size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                                format: "ttf", fingerprint: "fp-\(loc.id)-\(path)"),
                                     faces: [face], importBatch: 1)
    }

    private func families(_ env: Env, _ query: LibraryQuery) throws -> [String] {
        let rows = try env.store.rows(ids: try env.store.faceIDs(for: query))
        return try env.store.faceIDs(for: query).compactMap { rows[$0]?.family }
    }

    @Test func googleScopeOnlyKind4() throws {
        let env = try makeEnv()
        _ = try env.store.syncGoogleCatalog([fam("Roboto")])
        try add(env, env.google, "Roboto/Roboto-Bold.ttf", family: "Roboto")
        try add(env, env.folder, "Mine.ttf", family: "Mine")
        #expect(try families(env, LibraryQuery(scope: .googleFonts)) == ["Roboto"])
        #expect(try env.store.faceIDs(for: LibraryQuery(scope: .all)).count == 2)
        let count = LibraryQuery(scope: .googleFonts).countSQL()
        #expect(count.sql.contains("locations.kind = 4"))
    }

    @Test func categoryFilter() throws {
        let env = try makeEnv()
        _ = try env.store.syncGoogleCatalog([fam("Roboto"), fam("Lora", category: "Serif")])
        try add(env, env.google, "Roboto/Roboto-Bold.ttf", family: "Roboto")
        try add(env, env.google, "Lora/Lora-Regular.ttf", family: "Lora")
        var q = LibraryQuery(scope: .googleFonts)
        q.filters.googleCategory = "Serif"
        #expect(try families(env, q) == ["Lora"])
        #expect(q.filters.activeCount == 1 && !q.filters.isEmpty)
    }

    @Test func vietnameseSubsetFilter() throws {
        let env = try makeEnv()
        _ = try env.store.syncGoogleCatalog([
            fam("Foo", subsets: ["latin", "vietnamese"]), fam("FOO", subsets: ["latin"]),
            fam("Bar", subsets: ["latin", "vietnamese", "cyrillic"]), fam("Baz", subsets: ["latin"]),
        ])
        try add(env, env.google, "Foo/Foo-Regular.ttf", family: "Foo")
        try add(env, env.google, "FOO (2)/FOO-Regular.ttf", family: "FOO")
        try add(env, env.google, "Bar/Bar-Regular.ttf", family: "Bar")
        try add(env, env.google, "Baz/Baz-Regular.ttf", family: "Baz")
        var q = LibraryQuery(scope: .googleFonts)
        q.filters.googleVietnamese = true
        #expect(Set(try families(env, q)) == ["Foo", "Bar"])
        #expect(q.filters.activeCount == 1)

        // A family whose folder is "Foo (2)" matches its own row.
        let env2 = try makeEnv()
        _ = try env2.store.syncGoogleCatalog([fam("Foo", subsets: ["latin"]), fam("FOO", subsets: ["latin", "vietnamese"])])
        try add(env2, env2.google, "Foo/Foo-Regular.ttf", family: "Foo")
        try add(env2, env2.google, "FOO (2)/FOO-Regular.ttf", family: "FOO")
        #expect(try families(env2, q) == ["FOO"])
    }

    @Test func popularitySort() throws {
        let env = try makeEnv()
        _ = try env.store.syncGoogleCatalog([fam("Rare", popularity: 300), fam("Top", popularity: 5)])
        try add(env, env.google, "Rare/Rare-Regular.ttf", family: "Rare")
        try add(env, env.google, "Top/Top-Regular.ttf", family: "Top")
        try add(env, env.folder, "Aaa.ttf", family: "Aaa")
        #expect(try families(env, LibraryQuery(scope: .all, sort: .popularity)) == ["Top", "Rare", "Aaa"])
    }

    @Test func filtersInactiveOutsideGoogle() throws {
        let env = try makeEnv()
        _ = try env.store.syncGoogleCatalog([fam("Foo", subsets: ["latin", "vietnamese"])])
        try add(env, env.google, "Foo/Foo-Regular.ttf", family: "Foo")
        try add(env, env.folder, "Mine.ttf", family: "Mine")
        var q = LibraryQuery(scope: .all)
        q.filters.googleVietnamese = true
        #expect(try families(env, q) == ["Foo"])
    }
}
