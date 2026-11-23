import Foundation
import Testing
@testable import FontoryCore

@Suite struct TagQueryTests {
    private func ids(_ s: FontStore, _ scope: LibraryQuery.Scope, search: String? = nil, includeSystem: Bool = true) throws -> Set<Int64> {
        var q = LibraryQuery(scope: scope, includeSystem: includeSystem)
        if let search { q.search = SearchText(search) }
        return Set(try s.faceIDs(for: q))
    }

    private func setStyle(_ s: FontStore, _ face: Int64, _ cls: StyleClass) throws {
        try s.database.withLock { try s.database.execute("UPDATE faces SET style_class = \(cls.rawValue) WHERE id = \(face)") }
    }

    /// Tags: Projects > Client (Alpha-Regular), Projects (Alpha-Italic), Fun (Alpha-Regular, Beta-Light), Modern (Beta-Light, Beta-Black).
    private struct World {
        let f: Fixture
        let projects: Int64, client: Int64, fun: Int64, modern: Int64
        var s: FontStore { f.store }
        func face(_ n: String) -> Int64 { f.faceIDs[n]! }
    }

    private func world() throws -> World {
        let f = try Fixture.make()
        let s = f.store
        let projects = try s.createTag(name: "Projects", parentID: nil)
        let client = try s.createTag(name: "Client", parentID: projects)
        let fun = try s.createTag(name: "Fun", parentID: nil)
        let modern = try s.createTag(name: "Modern", parentID: nil)
        try s.addTag(client, toFaces: [f.faceIDs["Alpha-Regular"]!])
        try s.addTag(projects, toFaces: [f.faceIDs["Alpha-Italic"]!])
        try s.addTag(fun, toFaces: [f.faceIDs["Alpha-Regular"]!, f.faceIDs["Beta-Light"]!])
        try s.addTag(modern, toFaces: [f.faceIDs["Beta-Light"]!, f.faceIDs["Beta-Black"]!])
        return World(f: f, projects: projects, client: client, fun: fun, modern: modern)
    }

    @Test func tagScopeIncludesDescendants() throws {
        let w = try world()
        #expect(try ids(w.s, .tags([TagPick(tagID: w.projects, inverted: false)])) == [w.face("Alpha-Regular"), w.face("Alpha-Italic")])
        #expect(try ids(w.s, .tags([TagPick(tagID: w.client, inverted: false)])) == [w.face("Alpha-Regular")])
    }

    @Test func unionOfTwoTags() throws {
        let w = try world()
        let r = try ids(w.s, .tags([TagPick(tagID: w.client, inverted: false), TagPick(tagID: w.modern, inverted: false)]))
        #expect(r == [w.face("Alpha-Regular"), w.face("Beta-Light"), w.face("Beta-Black")])
    }

    @Test func invertedTagExcludesItsFaces() throws {
        let w = try world()
        let r = try ids(w.s, .tags([TagPick(tagID: w.fun, inverted: true)]))
        #expect(r == Set(w.f.faceIDs.values).subtracting([w.face("Alpha-Regular"), w.face("Beta-Light")]))
        #expect(r.contains(w.face("Beta-Regular")))   // no tags at all
    }

    @Test func untaggedScope() throws {
        let w = try world()
        let smart = try w.s.createTag(name: "Smart", parentID: nil, kind: .smart, ruleJSON: "{}")
        try w.s.addTag(smart, toFaces: [w.face("Beta-Regular")])
        let tagged: Set = [w.face("Alpha-Regular"), w.face("Alpha-Italic"), w.face("Beta-Light"), w.face("Beta-Black")]
        #expect(try ids(w.s, .untagged) == Set(w.f.faceIDs.values).subtracting(tagged))
        #expect(try ids(w.s, .untagged).contains(w.face("Beta-Regular")))
    }

    @Test func quickCollectionScope() throws {
        let w = try world()
        try w.s.setQuickCollection([w.face("Alpha-Bold"), w.face("Beta-Black")], included: true, at: Date())
        #expect(try ids(w.s, .quickCollection) == [w.face("Alpha-Bold"), w.face("Beta-Black")])
    }

    @Test func styleClassScope() throws {
        let w = try world()
        try setStyle(w.s, w.face("Alpha-Bold"), .slab)
        try setStyle(w.s, w.face("Beta-Light"), .slab)
        try setStyle(w.s, w.face("Beta-Black"), .script)
        #expect(try ids(w.s, .styleClass(.slab)) == [w.face("Alpha-Bold"), w.face("Beta-Light")])
        #expect(try ids(w.s, .styleClass(.script)) == [w.face("Beta-Black")])
        #expect(try ids(w.s, .styleClass(.mono)).isEmpty)
        #expect(StyleClass.browsable == [.serif, .sans, .slab, .script, .mono, .display, .symbol])
        #expect(StyleClass.sans.title == "Sans" && StyleClass.unknown.title == "Unknown")
    }

    @Test func hashTagSearch() throws {
        let w = try world()
        #expect(try ids(w.s, .all, search: "#fun") == [w.face("Alpha-Regular"), w.face("Beta-Light")])
        #expect(try ids(w.s, .all, search: "#FUN") == [w.face("Alpha-Regular"), w.face("Beta-Light")])
        #expect(try ids(w.s, .all, search: "#Projects/Client") == [w.face("Alpha-Regular")])
        #expect(try ids(w.s, .all, search: "#projects") == [w.face("Alpha-Regular"), w.face("Alpha-Italic")])
        #expect(try ids(w.s, .all, search: "#fun #modern") == [w.face("Beta-Light")])
        #expect(try ids(w.s, .all, search: "#!fun") == Set(w.f.faceIDs.values).subtracting([w.face("Alpha-Regular"), w.face("Beta-Light")]))
        #expect(try ids(w.s, .all, search: "#fun alpha") == [w.face("Alpha-Regular")])
        #expect(SearchText("#!fun").terms == [.init(text: "fun", mode: .notTag)])
    }

    @Test func unknownHashTagMatchesNothing() throws {
        let w = try world()
        #expect(try ids(w.s, .all, search: "#nosuchtag").isEmpty)
    }

    @Test func unknownNotTagFiltersNothing() throws {
        let w = try world()
        #expect(try ids(w.s, .all, search: "#!nosuchtag") == Set(w.f.faceIDs.values))
    }

    @Test func hashStyleSearch() throws {
        let w = try world()
        try setStyle(w.s, w.face("Alpha-Bold"), .serif)
        try setStyle(w.s, w.face("Beta-Black"), .sans)
        #expect(try ids(w.s, .all, search: "#serif") == [w.face("Alpha-Bold")])
        #expect(try ids(w.s, .all, search: "#Sans") == [w.face("Beta-Black")])
        #expect(try ids(w.s, .all, search: "#!serif").count == 5)
    }

    @Test func tagNamesAreBoundNotInterpolated() throws {
        let w = try world()
        #expect(try ids(w.s, .all, search: "#a'b\"--").isEmpty)
    }

    private func assertCountsMatch(_ w: World, includeSystem: Bool) throws {
        let c = try w.s.organizationCounts(includeSystem: includeSystem)
        for t in try w.s.tags() where t.kind == .tag {
            let n = try ids(w.s, .tags([TagPick(tagID: t.id, inverted: false)]), includeSystem: includeSystem).count
            #expect(c.perTag[t.id] == n, "tag \(t.name)")
        }
        #expect(c.untagged == (try ids(w.s, .untagged, includeSystem: includeSystem).count))
        #expect(c.quickCollection == (try ids(w.s, .quickCollection, includeSystem: includeSystem).count))
        for cls in StyleClass.browsable {
            #expect((c.perStyle[cls] ?? 0) == (try ids(w.s, .styleClass(cls), includeSystem: includeSystem).count), "style \(cls)")
        }
    }

    @Test func countsMatchQueries() throws {
        let w = try world()
        try w.s.setQuickCollection([w.face("Alpha-Bold"), w.face("Beta-Black")], included: true, at: Date())
        try setStyle(w.s, w.face("Alpha-Bold"), .slab)
        try setStyle(w.s, w.face("Beta-Black"), .slab)
        try setStyle(w.s, w.face("Alpha-Italic"), .serif)
        try assertCountsMatch(w, includeSystem: true)
        let c = try w.s.organizationCounts(includeSystem: true)
        #expect(c.perTag[w.projects] == 2 && c.perTag[w.client] == 1 && c.untagged == 2)
    }

    @Test func countsRespectIncludeSystem() throws {
        let w = try world()
        let sys = try w.s.upsertLocation(kind: .system, volumeUUID: "SYS", relativePath: "System/Library/Fonts", displayName: "System", lastKnownPath: "/System/Library/Fonts")
        let batch = try w.s.nextImportBatch()
        let file = FileRecord(locationID: sys.id, relativePath: "Sys.otf", size: 1, mtime: Date(), format: "otf", fingerprint: "sys")
        _ = try w.s.insertFile(file, faces: [Fixture.face("Sys-Regular", family: "Sys", style: "Regular", weight: 400)], importBatch: batch)
        let sysFace = try #require(try w.s.faceIDs(for: LibraryQuery(scope: .system)).first)
        try w.s.addTag(w.fun, toFaces: [sysFace])
        try w.s.setQuickCollection([sysFace], included: true, at: Date())
        try setStyle(w.s, sysFace, .serif)
        try assertCountsMatch(w, includeSystem: true)
        try assertCountsMatch(w, includeSystem: false)
        #expect(try w.s.organizationCounts(includeSystem: true).perTag[w.fun] == 3)
        #expect(try w.s.organizationCounts(includeSystem: false).perTag[w.fun] == 2)
    }

    @Test func queriesAreFastAt20k() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/F")
        let batch = try store.nextImportBatch()
        for file in 0..<20 {
            let faces = (0..<1000).map { Fixture.face("PS-\(file)-\($0)", family: "Fam\(file)", style: "S\($0)", weight: 400, index: $0) }
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "f\(file).ttc", size: 1, mtime: Date(), format: "ttc", fingerprint: "fp\(file)"),
                                     faces: faces, importBatch: batch)
        }
        let all = try store.faceIDs(for: LibraryQuery())
        #expect(all.count == 20_000)
        let parent = try store.createTag(name: "Parent", parentID: nil)
        var tagIDs = [parent]
        for i in 0..<9 { tagIDs.append(try store.createTag(name: "T\(i)", parentID: i % 2 == 0 ? parent : nil)) }
        for (i, t) in tagIDs.enumerated() { try store.addTag(t, toFaces: Array(all[(i * 1500)..<(i * 1500 + 2000)])) }
        try store.setQuickCollection(Array(all.prefix(500)), included: true, at: Date())
        try store.database.withLock { try store.database.execute("UPDATE faces SET style_class = id % 8") }

        func ms(_ label: String, _ body: () throws -> Void) rethrows {
            let t = Date()
            try body()
            let d = Date().timeIntervalSince(t) * 1000
            #expect(d < 100, "\(label) took \(d) ms")
        }
        try ms("tag") { _ = try store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: parent, inverted: false)]))) }
        try ms("inverted") { _ = try store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: parent, inverted: true)]))) }
        try ms("union") { _ = try store.faceIDs(for: LibraryQuery(scope: .tags(tagIDs.prefix(4).map { TagPick(tagID: $0, inverted: false) }))) }
        try ms("untagged") { _ = try store.faceIDs(for: LibraryQuery(scope: .untagged)) }
        try ms("quick") { _ = try store.faceIDs(for: LibraryQuery(scope: .quickCollection)) }
        try ms("style") { _ = try store.faceIDs(for: LibraryQuery(scope: .styleClass(.serif))) }
        for term in ["#parent", "#parent/t0", "#!t1", "#t1 #t3", "#serif"] {
            try ms(term) {
                var q = LibraryQuery()
                q.search = SearchText(term)
                _ = try store.faceIDs(for: q)
            }
        }
        try ms("counts") { _ = try store.organizationCounts(includeSystem: true) }
    }
}
