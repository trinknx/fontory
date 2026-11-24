import Testing
import Foundation
@testable import FontoryCore

@Suite("Export") struct ExportTests {
    final class Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FontoryExportTests-\(UUID().uuidString)")
        let dest: URL
        let store: FontStore
        var loc: LocationRecord?
        var batch: Int64 = 0
        init() throws {
            dest = root.appendingPathComponent("dest")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            store = try FontStore(database: Database(path: ":memory:"))
            batch = try store.nextImportBatch()
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// Makes a real file at `<root>/src/<rel>` and indexes it with the given faces.
        func add(_ rel: String, content: String = "x", family: String = "Fam", faces: Int = 1, online: Bool = true) throws -> [Int64] {
            let src = root.appendingPathComponent("src")
            let url = src.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
            let l = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "src", displayName: "S", lastKnownPath: src.path)
            if !online { try store.setLocationOnline(l.id, online: false, lastKnownPath: nil) }
            let ps = (0..<faces).map { Fixture.face("\(rel)-\($0)", family: family, style: "R\($0)", weight: 400, index: $0) }
            let rec = FileRecord(locationID: l.id, relativePath: rel, size: 1, mtime: Date(timeIntervalSince1970: 1), format: "otf", fingerprint: "fp-\(rel)")
            _ = try store.insertFile(rec, faces: ps, importBatch: batch)
            let ids = try store.faceIDs(for: LibraryQuery())
            let rows = try store.rows(ids: ids)
            return rows.values.filter { $0.postScriptName.hasPrefix("\(rel)-") }.map(\.id).sorted()
        }
    }

    func run(_ files: [ExportFile], _ env: Env, _ o: ExportOptions = ExportOptions(), cancel: @escaping @Sendable () -> Bool = { false }) throws -> ExportResult {
        try FontExporter.export(files, to: env.dest, options: o, progress: { _, _ in }, isCancelled: cancel)
    }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func ttcCopiedOnce() throws {
        let env = try Env()
        let ids = try env.add("Big.ttc", faces: 3)
        #expect(ids.count == 3)
        let files = try env.store.exportFiles(faceIDs: ids)
        #expect(files.count == 1)
        #expect(files[0].fileName == "Big.ttc")
        #expect(files[0].family == "Fam")
    }

    @Test func sameNameGetsNumbered() throws {
        let env = try Env()
        let a = try env.add("A/Name.otf", content: "a")
        let b = try env.add("B/Name.otf", content: "b")
        let ttc = try env.add("T.ttc", faces: 3)
        let files = try env.store.exportFiles(faceIDs: a + b + ttc)
        let r = try run(files, env)
        #expect(r.copied == 3)
        #expect(names(env.dest) == ["Name 2.otf", "Name.otf", "T.ttc"])
    }

    @Test func neverOverwrites() throws {
        let env = try Env()
        try Data("old".utf8).write(to: env.dest.appendingPathComponent("Name.otf"))
        let ids = try env.add("Name.otf", content: "new")
        _ = try run(try env.store.exportFiles(faceIDs: ids), env)
        #expect(try String(contentsOf: env.dest.appendingPathComponent("Name.otf"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: env.dest.appendingPathComponent("Name 2.otf"), encoding: .utf8) == "new")
    }

    @Test func byFamilyFolders() throws {
        let env = try Env()
        let a = try env.add("a.otf", family: "Alpha")
        let b = try env.add("b.otf", family: "Be/ta: X")
        let r = try run(try env.store.exportFiles(faceIDs: a + b), env, ExportOptions(byFamily: true))
        #expect(r.copied == 2)
        #expect(names(env.dest) == ["Alpha", "Be-ta- X"])
        #expect(names(env.dest.appendingPathComponent("Alpha")) == ["a.otf"])
    }

    @Test func zipContainsFiles() throws {
        let env = try Env()
        let a = try env.add("a.otf", family: "Alpha")
        let b = try env.add("b.otf", family: "Beta")
        let files = try env.store.exportFiles(faceIDs: a + b)
        let o = ExportOptions(byFamily: true, zip: true, archiveName: "Fonts")
        let r = try run(files, env, o)
        #expect(r.output.lastPathComponent == "Fonts.zip")
        let r2 = try run(files, env, o)
        #expect(r2.output.lastPathComponent == "Fonts 2.zip")
        let out = env.root.appendingPathComponent("unz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", r.output.path, out.path]
        try p.run(); p.waitUntilExit()
        #expect(names(out) == ["Fonts"])
        #expect(names(out.appendingPathComponent("Fonts")) == ["Alpha", "Beta"])
        #expect(names(out.appendingPathComponent("Fonts/Alpha")) == ["a.otf"])
        #expect(names(env.dest) == ["Fonts 2.zip", "Fonts.zip"])
    }

    @Test func offlineFilesSkipped() throws {
        let env = try Env()
        let ids = try env.add("off.otf", online: false)
        let files = try env.store.exportFiles(faceIDs: ids)
        #expect(files[0].url == nil)
        let r = try run(files, env)
        #expect(r.skipped == 1 && r.copied == 0)
        #expect(names(env.dest).isEmpty)
    }

    @Test func cancelStopsEarly() throws {
        let env = try Env()
        var ids: [Int64] = []
        for i in 0..<4 { ids += try env.add("f\(i).otf") }
        let files = try env.store.exportFiles(faceIDs: ids)
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        let r = try FontExporter.export(files, to: env.dest, options: ExportOptions(), progress: { _, _ in },
                                        isCancelled: { c.n += 1; return c.n > 2 })
        #expect(r.copied == 2)
        #expect(names(env.dest).count == 2)
        // zip: cancel throws and leaves no zip
        let c2 = Counter()
        #expect(throws: CancellationError.self) {
            try FontExporter.export(files, to: env.dest, options: ExportOptions(zip: true, archiveName: "Z"),
                                    progress: { _, _ in }, isCancelled: { c2.n += 1; return c2.n > 1 })
        }
        #expect(!names(env.dest).contains("Z.zip"))
    }
}
