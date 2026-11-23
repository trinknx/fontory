import CryptoKit
import Foundation
import os
import Testing
@testable import FontoryCore

@Suite struct DuplicatesTests {
    // MARK: Helpers

    private func memoryStore() throws -> FontStore { try FontStore(database: Database(path: ":memory:")) }

    /// Indexes a real file already in `t` at `relative`, with its real fingerprint and faces.
    @discardableResult
    private func index(_ store: FontStore, _ loc: LocationRecord, _ t: TempFonts, _ relative: String) throws -> Int64 {
        let url = t.root.appendingPathComponent(relative)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let record = FileRecord(locationID: loc.id, relativePath: relative, size: Int64(size), mtime: Date(),
                                format: url.pathExtension.lowercased(), fingerprint: try Fingerprint.compute(url: url, size: Int64(size)))
        return try store.insertFile(record, faces: try FontParser.parse(url: url), importBatch: try store.nextImportBatch())
    }

    /// A copy of Arial Bold with one byte flipped in the middle: same size, head and tail (so the same fingerprint), other content.
    private func alteredArial(_ t: TempFonts, as relative: String) throws {
        var data = try Data(contentsOf: URL(fileURLWithPath: TempFonts.arialBold))
        #expect(data.count > 2 * Fingerprint.window)
        data[data.count / 2] ^= 0xFF
        try t.write(data, as: relative)
    }

    private func hashAll(_ finder: DuplicateFinder) async -> BackfillProgress? {
        var last: BackfillProgress?
        for await p in finder.hashCandidates() { last = p }
        return last
    }

    private func scan(_ scanner: LibraryScanner, _ id: Int64) async -> ScanProgress? {
        var last: ScanProgress?
        for await p in await scanner.scan(locationID: id) { last = p }
        return last
    }

    private func insertFake(_ store: FontStore, _ loc: Int64, _ path: String, ps: [String], fingerprint: String? = nil,
                            format: String = "otf") throws -> Int64 {
        let faces = ps.enumerated().map { Fixture.face($1, family: $1, style: "Regular", weight: 400, index: $0) }
        return try store.insertFile(FileRecord(locationID: loc, relativePath: path, size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                               format: format, fingerprint: fingerprint ?? "fp-\(path)"),
                                    faces: faces, importBatch: 1)
    }

    // MARK: Groups

    @Test func exactGroupsNeedEqualHash() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        try t.copy(TempFonts.arialBold, as: "a.ttf")
        try t.copy(TempFonts.arialBold, as: "b.ttf")
        try alteredArial(t, as: "c.ttf")
        try t.copy(TempFonts.sfns, as: "s.ttf")
        let a = try index(store, loc, t, "a.ttf"), b = try index(store, loc, t, "b.ttf")
        let c = try index(store, loc, t, "c.ttf"), s = try index(store, loc, t, "s.ttf")
        let fps = Dictionary(uniqueKeysWithValues: try store.files(in: loc.id).map { ($0.id, $0.fingerprint) })
        #expect(fps[a] == fps[c] && fps[a] == fps[b])

        let finder = DuplicateFinder(store: store)
        let last = await hashAll(finder)
        #expect(last == BackfillProgress(done: 3, total: 3))
        // Only files sharing a fingerprint are hashed; the hash is the full-file SHA-256.
        #expect(try store.contentHash(fileID: s) == nil)
        let full = SHA256.hash(data: try Data(contentsOf: t.root.appendingPathComponent("a.ttf"))).map { String(format: "%02x", $0) }.joined()
        #expect(try store.contentHash(fileID: a) == full)
        #expect(try store.contentHash(fileID: b) == full)
        #expect(try store.contentHash(fileID: c) != full)
        #expect(await hashAll(finder) == nil)  // nothing left to hash

        let groups = try finder.groups(includeSystem: false)
        let exact = groups.filter { $0.kind == .exact }
        #expect(exact.count == 1)
        #expect(exact.first?.id == full)
        #expect(Set(exact.first?.fileIDs ?? []) == [a, b])
        #expect(exact.first?.faceIDs.count == 2)
        // c has the same PostScript name but other content: a same-font group of c and one copy of the a/b content.
        let same = groups.filter { $0.kind == .sameFont }
        #expect(same.count == 1)
        #expect(same.first?.fileIDs.count == 2)
        #expect(same.first?.fileIDs.contains(c) == true)
        #expect(groups.first?.kind == .exact)
    }

    @Test func sameFontGroups() throws {
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/f")
        let sys = try store.upsertLocation(kind: .system, volumeUUID: "S", relativePath: "Sys", displayName: "S", lastKnownPath: "/s")
        let f1 = try insertFake(store, loc.id, "Foo.otf", ps: ["Foo-Regular", "Foo-Bold"])
        let f2 = try insertFake(store, loc.id, "Foo.ttf", ps: ["Foo-Regular"], format: "ttf")
        _ = try insertFake(store, loc.id, "Unique.otf", ps: ["Unique-Regular"])
        // An exact pair (equal hashes) with the same name: no same-font group of its own.
        let e1 = try insertFake(store, loc.id, "Bar1.otf", ps: ["Bar-Regular"], fingerprint: "same")
        let e2 = try insertFake(store, loc.id, "Bar2.otf", ps: ["Bar-Regular"], fingerprint: "same")
        try store.setContentHashes([(e1, "H"), (e2, "H")])
        // System copies: a public face counts only with includeSystem; private system faces never.
        let s1 = try insertFake(store, sys.id, "Foo.ttc", ps: ["Foo-Bold"], format: "ttc")
        _ = try insertFake(store, sys.id, "Priv1.ttc", ps: [".Priv"], format: "ttc")
        _ = try insertFake(store, loc.id, "Priv2.otf", ps: [".Priv"])

        let finder = DuplicateFinder(store: store)
        var groups = try finder.groups(includeSystem: false)
        #expect(groups.map(\.kind) == [.exact, .sameFont])
        #expect(Set(groups[0].fileIDs) == [e1, e2] && groups[0].id == "H")
        #expect(groups[1].id == "Foo-Regular")
        #expect(Set(groups[1].fileIDs) == [f1, f2])
        #expect(groups[1].faceIDs.count == 2)
        let rows = try store.rows(ids: groups[1].faceIDs)
        #expect(rows.values.allSatisfy { $0.postScriptName == "Foo-Regular" })

        groups = try finder.groups(includeSystem: true)
        let bold = try #require(groups.first { $0.id == "Foo-Bold" })
        #expect(bold.kind == .sameFont && Set(bold.fileIDs) == [f1, s1])
        #expect(!groups.contains { $0.id == ".Priv" })
    }

    // MARK: Keep policy

    private func row(_ face: Int64, file: Int64, loc: Int64 = 1, format: String = "otf", version: String? = nil,
                     activation: ActivationState = .off, external: Bool = false, kind: LocationKind = .folder) -> FaceRow {
        FaceRow(id: face, fileID: file, faceIndex: 0, postScriptName: "P", family: "P", style: "R", fullName: "P", weight: 400,
                isVariable: false, format: format, vendor: nil, version: version, glyphCount: 1, activation: activation,
                lastActivated: nil, online: true, fileURL: nil, locationID: loc, externalActive: external, locationKind: kind)
    }

    private func file(_ id: Int64, loc: Int64 = 1, format: String = "otf", added: Double = 0) -> FileRecord {
        var f = FileRecord(id: id, locationID: loc, relativePath: "f\(id)", size: 1, mtime: Date(), format: format, fingerprint: "x")
        f.addedAt = Date(timeIntervalSince1970: added)
        return f
    }

    /// The file ids removed from an exact group of the given (row, file) pairs.
    private func removed(_ items: [(FaceRow, FileRecord)], policy: KeepPolicy = KeepPolicy(), userData: Set<Int64> = []) -> Set<Int64> {
        let group = DuplicateGroup(id: "h", kind: .exact, faceIDs: items.map(\.0.id), fileIDs: items.map(\.1.id))
        return policy.filesToRemove(in: group, rows: Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.0) }),
                                    files: Dictionary(uniqueKeysWithValues: items.map { ($0.1.id, $0.1) }), userDataFiles: userData)
    }

    @Test func keepPolicyOrder() {
        // 1. The active face is kept, even in a worse format.
        #expect(removed([(row(11, file: 1), file(1)), (row(12, file: 2, format: "woff", activation: .on), file(2, format: "woff"))]) == [1])
        #expect(removed([(row(11, file: 1, activation: .temporary), file(1, format: "woff")), (row(12, file: 2), file(2))]) == [2])
        // 2. Format: OTF > TTF > TTC/OTC > WOFF2 > WOFF > others.
        let order = ["otf", "ttf", "ttc", "woff2", "woff", "pfb"]
        for (better, worse) in zip(order, order.dropFirst()) {
            #expect(removed([(row(11, file: 1, format: worse), file(1, format: worse)),
                             (row(12, file: 2, format: better), file(2, format: better))]) == [1], "\(better) > \(worse)")
        }
        #expect(removed([(row(11, file: 1, format: "otc"), file(1, format: "otc")), (row(12, file: 2, format: "woff2"), file(2, format: "woff2"))]) == [2])
        // 3. Location rank (higher first), unranked last.
        let items = [(row(11, file: 1, loc: 5), file(1, loc: 5)), (row(12, file: 2, loc: 7), file(2, loc: 7))]
        #expect(removed(items, policy: KeepPolicy(locationRank: [7, 5])) == [1])
        #expect(removed(items, policy: KeepPolicy(locationRank: [5])) == [2])
        // 4. Newer version: numeric parts compared; unparsable compares lowest.
        #expect(removed([(row(11, file: 1, version: "Version 2.9"), file(1)), (row(12, file: 2, version: "Version 2.013;PS 2.0"), file(2))]) == [1])
        #expect(removed([(row(11, file: 1, version: "Version 1.0"), file(1)), (row(12, file: 2, version: "Version unknown"), file(2))]) == [2])
        #expect(removed([(row(11, file: 1, version: nil), file(1)), (row(12, file: 2, version: "0.1"), file(2))]) == [1])
        #expect(KeepPolicy.versionParts("Version 2.013;hotconv 1.0.109") == [2, 13])
        #expect(KeepPolicy.versionParts("nothing") == nil)
        // 5. Earliest added.
        #expect(removed([(row(11, file: 1), file(1, added: 200)), (row(12, file: 2), file(2, added: 100))]) == [1])
        // Earlier rules win over later ones: format beats version.
        #expect(removed([(row(11, file: 1, format: "ttf", version: "9.0"), file(1, format: "ttf")),
                         (row(12, file: 2, format: "otf", version: "1.0"), file(2, format: "otf"))]) == [1])
        // Never system, user-installed or externally active files; one of them is kept (it can't be removed anyway).
        let protected = removed([
            (row(11, file: 1, format: "woff", kind: .system), file(1, format: "woff")),
            (row(12, file: 2, format: "woff", external: true), file(2, format: "woff")),
            (row(13, file: 3, format: "ttf"), file(3, format: "ttf")),
            (row(14, file: 4, format: "otf"), file(4, format: "otf")),
            (row(15, file: 5, format: "woff", kind: .userInstalled), file(5, format: "woff")),
        ])
        #expect(protected == [3, 4])
        #expect(removed([(row(11, file: 1, kind: .system), file(1)), (row(12, file: 2, kind: .system), file(2))]).isEmpty)
    }

    @Test func userDataCopyIsKept() throws {
        // 1b. A tagged .ttf is kept over an untagged .otf (format is rule 2).
        let items = [(row(11, file: 1, format: "ttf"), file(1, format: "ttf")), (row(12, file: 2, format: "otf"), file(2, format: "otf"))]
        #expect(removed(items) == [1])
        #expect(removed(items, userData: [1]) == [2])
        // Rule 1 (active) still comes first; both with user data falls through to format.
        let active = [(row(11, file: 1, format: "ttf"), file(1, format: "ttf")),
                      (row(12, file: 2, format: "woff", activation: .on), file(2, format: "woff"))]
        #expect(removed(active, userData: [1]) == [1])
        #expect(removed(items, userData: [1, 2]) == [1])

        // The store's input: tags, notes and Quick Collection membership count; activation alone does not.
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "A", displayName: "A", lastKnownPath: "/nowhere")
        let tagged = try insertFake(store, loc.id, "tagged.ttf", ps: ["T"], format: "ttf")
        let plain = try insertFake(store, loc.id, "plain.otf", ps: ["T"], format: "otf")
        let noted = try insertFake(store, loc.id, "noted.otf", ps: ["N1", "N2"])
        let collected = try insertFake(store, loc.id, "qc.otf", ps: ["Q"])
        let active2 = try insertFake(store, loc.id, "active.otf", ps: ["A"])
        func faces(_ file: Int64) throws -> [Int64] {
            try store.database.withLock {
                let s = try store.database.prepare("SELECT id FROM faces WHERE file_id = ? ORDER BY face_index")
                defer { s.reset() }
                try s.bind([.int(file)])
                var out: [Int64] = []
                while try s.step() { out.append(s.int64(0)) }
                return out
            }
        }
        let tag = try store.createTag(name: "Keep", parentID: nil)
        try store.addTag(tag, toFaces: try faces(tagged))
        let notedFaces = try faces(noted)
        try store.setNote("mine", faceID: notedFaces[0])
        try store.setNote("also", faceID: notedFaces[1])
        try store.setQuickCollection(try faces(collected), included: true, at: Date())
        try store.setActivation(faceIDs: try faces(active2), state: .on, at: Date())
        #expect(try store.userDataFaceCounts(fileIDs: [tagged, plain, noted, collected, active2]) == [tagged: 1, noted: 2, collected: 1])
    }

    @Test func protectedCopyIsKept() {
        // External-active counts as active for rule 1 and beats a better format.
        #expect(removed([(row(11, file: 1, format: "woff", external: true), file(1, format: "woff")),
                         (row(12, file: 2, format: "otf"), file(2, format: "otf"))]) == [2])
        // A system copy is kept over a better, Fontory-active copy: it can never be removed.
        #expect(removed([(row(11, file: 1, format: "ttc", kind: .system), file(1, format: "ttc")),
                         (row(12, file: 2, format: "otf", activation: .on), file(2, format: "otf"))]) == [2])
        #expect(removed([(row(11, file: 1, format: "ttc", kind: .userInstalled), file(1, format: "ttc")),
                         (row(12, file: 2, format: "otf"), file(2, format: "otf"))]) == [2])
    }

    @Test func sameFontNeverAutoSelected() {
        let items = [(row(11, file: 1, format: "woff"), file(1, format: "woff")), (row(12, file: 2), file(2))]
        let group = DuplicateGroup(id: "P", kind: .sameFont, faceIDs: [11, 12], fileIDs: [1, 2])
        let picked = KeepPolicy().filesToRemove(in: group, rows: Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.0) }),
                                                files: Dictionary(uniqueKeysWithValues: items.map { ($0.1.id, $0.1) }))
        #expect(picked.isEmpty)
    }

    @Test func fileRecordsCarryAddedAt() throws {
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/f")
        let id = try insertFake(store, loc.id, "a.otf", ps: ["A"])
        let records = try store.fileRecords(ids: [id])
        #expect(records[id]?.relativePath == "a.otf")
        #expect(records[id]?.addedAt != nil)
    }

    // MARK: Exclusions

    @Test func removeFromLibraryExcludesOnRescan() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "a.ttf")
        try t.copy(TempFonts.sfns, as: "s.ttf")
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        let root = t.root
        let scanner = LibraryScanner(store: store, rootURL: { _ in root })
        #expect(await scan(scanner, loc.id)?.phase == .done)
        let arial = try #require(try store.files(in: loc.id).first { $0.relativePath == "a.ttf" })
        let arialFace = try #require(try store.faceIDs(for: LibraryQuery()).first { try store.rows(ids: [$0])[$0]?.fileID == arial.id })
        try store.setNote("note", faceID: arialFace)

        try store.removeFromLibrary(fileIDs: [arial.id])
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["s.ttf"])
        let excluded = try store.excludedFiles()
        #expect(excluded.count == 1)
        #expect(excluded.first?.locationID == loc.id && excluded.first?.relativePath == "a.ttf" && excluded.first?.fingerprint == arial.fingerprint)
        #expect(try store.rows(ids: [arialFace]).isEmpty)

        // A rescan does not bring it back, nor does renaming it (matched by fingerprint).
        var last = await scan(scanner, loc.id)
        #expect(last?.phase == .done && last?.failed == 0)
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["s.ttf"])
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.ttf"), to: root.appendingPathComponent("renamed.ttf"))
        last = await scan(scanner, loc.id)
        #expect(last?.phase == .done)
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["s.ttf"])

        // Include again + rescan: the path and the fingerprint are allowed again.
        try store.includeAgain(locationID: loc.id, relativePath: "a.ttf")
        #expect(try store.excludedFiles().isEmpty)
        last = await scan(scanner, loc.id)
        #expect(last?.phase == .done)
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["renamed.ttf", "s.ttf"])
    }

    @Test func differentFileAtExcludedPathIsIndexed() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "a.ttf")
        try t.copy(TempFonts.sfns, as: "s.ttf")
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        let root = t.root
        let scanner = LibraryScanner(store: store, rootURL: { _ in root })
        _ = await scan(scanner, loc.id)
        let arial = try #require(try store.files(in: loc.id).first { $0.relativePath == "a.ttf" })
        try store.removeFromLibrary(fileIDs: [arial.id])
        // Another font saved at the excluded path: indexed, and the stale exclusion is dropped.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.ttf"))
        try t.copy(TempFonts.newYork, as: "a.ttf")
        let last = await scan(scanner, loc.id)
        #expect(last?.phase == .done)
        #expect(try store.files(in: loc.id).map(\.relativePath) == ["a.ttf", "s.ttf"])
        #expect(try store.files(in: loc.id).first?.fingerprint != arial.fingerprint)
        #expect(try store.excludedFiles().isEmpty)
    }

    @Test func moveOntoExcludedPathKeepsUserData() async throws {
        // Exact copies a and b; b removed from the library and deleted; the kept copy a is then moved onto b's path.
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "a.ttf")
        try t.copy(TempFonts.arialBold, as: "b.ttf")
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        let root = t.root
        let scanner = LibraryScanner(store: store, rootURL: { _ in root })
        _ = await scan(scanner, loc.id)
        let files = try store.files(in: loc.id)
        let a = try #require(files.first { $0.relativePath == "a.ttf" }), b = try #require(files.first { $0.relativePath == "b.ttf" })
        let face = try #require(try store.faceIDs(for: LibraryQuery()).first { try store.rows(ids: [$0])[$0]?.fileID == a.id })
        try store.setNote("keep me", faceID: face)
        let tag = try store.createTag(name: "T", parentID: nil)
        try store.addTag(tag, toFaces: [face])
        try store.removeFromLibrary(fileIDs: [b.id])
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.ttf"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.ttf"), to: root.appendingPathComponent("b.ttf"))

        let last = await scan(scanner, loc.id)
        #expect(last?.phase == .done)
        #expect(last?.removedWithUserData == 0)
        let after = try store.files(in: loc.id)
        #expect(after.map(\.relativePath) == ["b.ttf"])
        #expect(after.first?.id == a.id)
        #expect(try store.faceInfo(id: face)?.note == "keep me")
        #expect(try store.tagIDs(forFaces: [face])[face] == [tag])
        #expect(try store.excludedFiles().isEmpty)
    }

    @Test func excludedIndexedFileMovesNormally() async throws {
        // Exact copies in one location: one removed (excluded), the kept copy is renamed. The rename is a move.
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "a.ttf")
        try t.copy(TempFonts.arialBold, as: "b.ttf")
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        let root = t.root
        let scanner = LibraryScanner(store: store, rootURL: { _ in root })
        _ = await scan(scanner, loc.id)
        let files = try store.files(in: loc.id)
        let a = try #require(files.first { $0.relativePath == "a.ttf" }), b = try #require(files.first { $0.relativePath == "b.ttf" })
        try store.removeFromLibrary(fileIDs: [b.id])
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.ttf"), to: root.appendingPathComponent("kept.ttf"))
        #expect(await scan(scanner, loc.id)?.phase == .done)
        let after = try store.files(in: loc.id)
        #expect(after.map(\.relativePath) == ["kept.ttf"])
        #expect(after.first?.id == a.id)
    }

    // MARK: Hashing

    @Test func hashSkipsUnreachable() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: t.root.path)
        for name in ["a.ttf", "b.ttf", "c.ttf"] { try t.copy(TempFonts.arialBold, as: name) }
        let a = try index(store, loc, t, "a.ttf"), b = try index(store, loc, t, "b.ttf"), c = try index(store, loc, t, "c.ttf")
        let fp = try #require(try store.files(in: loc.id).first?.fingerprint)
        let off = try store.upsertLocation(kind: .folder, volumeUUID: "W", relativePath: "G", displayName: "G", lastKnownPath: "/nonexistent")
        let o = try insertFake(store, off.id, "x.ttf", ps: ["ArialMT-Off"], fingerprint: fp)
        try store.setLocationOnline(off.id, online: false, lastKnownPath: nil)
        try FileManager.default.removeItem(at: t.root.appendingPathComponent("c.ttf"))  // gone, not rescanned yet

        let last = await hashAll(DuplicateFinder(store: store))
        #expect(last?.done == last?.total)
        #expect(try store.contentHash(fileID: a) != nil)
        #expect(try store.contentHash(fileID: a) == store.contentHash(fileID: b))
        #expect(try store.contentHash(fileID: c) == nil)
        #expect(try store.contentHash(fileID: o) == nil)
        // A later run retries only the files still missing a hash.
        #expect(try store.countFilesNeedingHash() == 1)  // c (online location); the offline file is not a candidate
        let groups = try DuplicateFinder(store: store).groups(includeSystem: false).filter { $0.kind == .exact }
        #expect(groups.count == 1 && Set(groups[0].fileIDs) == [a, b])
    }

    /// Calls for the hashing seam: the second call blocks until the run is cancelled.
    final class BlockingHasher: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        func hash(_ url: URL, _ isCancelled: () -> Bool) -> String? {
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 2 {
                let deadline = Date().addingTimeInterval(120)  // generous: utility work can be starved under a full test run
                while !isCancelled() && Date() < deadline { usleep(1000) }
            }
            return "h\(n)"
        }
    }

    @Test func hashCancellable() async throws {
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/f")
        var ids: [Int64] = []
        for i in 0..<6 { ids.append(try insertFake(store, loc.id, "f\(i).otf", ps: ["P\(i)"], fingerprint: "same")) }
        let hasher = BlockingHasher()
        let finder = DuplicateFinder(store: store, hashFile: { url, cancelled in hasher.hash(url, cancelled) })
        let task = Task { await hashAll(finder) }
        let deadline = ContinuousClock.now + .seconds(120)
        while hasher.calls.withLock({ $0 }) < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        _ = await task.value
        // Stopped between files: the blocked file and those after it were not hashed; the first one was kept.
        #expect(hasher.calls.withLock { $0 } == 2)
        #expect(try store.contentHash(fileID: ids[0]) == "h1")
        #expect(try ids.dropFirst().allSatisfy { try store.contentHash(fileID: $0) == nil })
        // A new run finishes the rest.
        let rest = await hashAll(DuplicateFinder(store: store, hashFile: { _, _ in "z" }))
        #expect(rest == BackfillProgress(done: 5, total: 5))
    }

    @Test func streamedHashMatchesFullFile() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold, as: "a.ttf")
        let expected = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #expect(DuplicateFinder.sha256(url: url, isCancelled: { false }) == expected)
        #expect(DuplicateFinder.sha256(url: url, isCancelled: { true }) == nil)
        #expect(DuplicateFinder.sha256(url: t.root.appendingPathComponent("missing.ttf"), isCancelled: { false }) == nil)
    }

    @Test func changedFileDropsItsHash() throws {
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/f")
        let a = try insertFake(store, loc.id, "a.otf", ps: ["A"], fingerprint: "same")
        let b = try insertFake(store, loc.id, "b.otf", ps: ["B"], fingerprint: "same")
        try store.setContentHashes([(a, "H"), (b, "H")])
        try store.replaceFaces(fileID: a, size: 11, mtime: Date(), fingerprint: "same", faces: [Fixture.face("A", family: "A", style: "R", weight: 400)])
        try store.moveFile(fileID: b, toRelativePath: "b2.otf", mtime: Date())
        #expect(try store.contentHash(fileID: a) == nil)
        #expect(try store.contentHash(fileID: b) == nil)
    }

    // MARK: Skip on import

    @Test func skipFingerprintDuplicatesOnImport() async throws {
        let t1 = try TempFonts(), t2 = try TempFonts(); defer { t1.cleanup(); t2.cleanup() }
        try t1.copy(TempFonts.arialBold, as: "a.ttf")
        try t2.copy(TempFonts.arialBold, as: "x.ttf")
        try t2.copy(TempFonts.arialBold, as: "sub/y.ttf")
        try t2.copy(TempFonts.sfns, as: "s.ttf")
        let store = try memoryStore()
        let l1 = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "A", displayName: "A", lastKnownPath: t1.root.path)
        let l2 = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "B", displayName: "B", lastKnownPath: t2.root.path)
        let roots = [l1.id: t1.root, l2.id: t2.root]
        let scanner = LibraryScanner(store: store, rootURL: { roots[$0.id] }, skipFingerprintDuplicates: true)
        var last = await scan(scanner, l1.id)
        #expect(last?.skippedDuplicates == 0)
        last = await scan(scanner, l2.id)
        #expect(last?.phase == .done)
        #expect(last?.skippedDuplicates == 2)
        #expect(try store.files(in: l2.id).map(\.relativePath) == ["s.ttf"])

        // A copy within the same location and a move within a location are not affected.
        try t1.copy(TempFonts.arialBold, as: "a2.ttf")
        try FileManager.default.moveItem(at: t1.root.appendingPathComponent("a.ttf"), to: t1.root.appendingPathComponent("moved.ttf"))
        last = await scan(scanner, l1.id)
        #expect(last?.phase == .done && last?.skippedDuplicates == 0)
        #expect(try store.files(in: l1.id).map(\.relativePath) == ["a2.ttf", "moved.ttf"])

        // Off by default.
        let store2 = try memoryStore()
        let m1 = try store2.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "A", displayName: "A", lastKnownPath: t1.root.path)
        let m2 = try store2.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "B", displayName: "B", lastKnownPath: t2.root.path)
        let roots2 = [m1.id: t1.root, m2.id: t2.root]
        let plain = LibraryScanner(store: store2, rootURL: { roots2[$0.id] })
        _ = await scan(plain, m1.id)
        last = await scan(plain, m2.id)
        #expect(last?.skippedDuplicates == 0)
        #expect(try store2.files(in: m2.id).count == 3)
    }

    @Test func moveBetweenLocationsWithSkipKeepsTheFont() async throws {
        let t1 = try TempFonts(), t2 = try TempFonts(); defer { t1.cleanup(); t2.cleanup() }
        try t1.copy(TempFonts.arialBold, as: "a.ttf")
        let store = try memoryStore()
        let l1 = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "A", displayName: "A", lastKnownPath: t1.root.path)
        let l2 = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "B", displayName: "B", lastKnownPath: t2.root.path)
        let roots = [l1.id: t1.root, l2.id: t2.root]
        let scanner = LibraryScanner(store: store, rootURL: { roots[$0.id] }, skipFingerprintDuplicates: true)
        _ = await scan(scanner, l1.id)
        #expect(try store.files(in: l1.id).map(\.relativePath) == ["a.ttf"])
        // Moved from A to B; A keeps a second font so its rescan is not an empty-root abort.
        try t1.copy(TempFonts.sfns, as: "other.ttf")
        try FileManager.default.moveItem(at: t1.root.appendingPathComponent("a.ttf"), to: t2.root.appendingPathComponent("a.ttf"))
        var last = await scan(scanner, l2.id)
        #expect(last?.phase == .done && last?.skippedDuplicates == 0)
        last = await scan(scanner, l1.id)
        #expect(last?.phase == .done)
        #expect(try store.files(in: l2.id).map(\.relativePath) == ["a.ttf"])
        #expect(try store.files(in: l1.id).map(\.relativePath) == ["other.ttf"])

        // A copy still in place elsewhere is skipped; one in an offline location counts as in place (not checked).
        try t1.copy(TempFonts.arialBold, as: "copy.ttf")
        last = await scan(scanner, l1.id)
        #expect(last?.skippedDuplicates == 1)
        let fp = try #require(try store.files(in: l2.id).first?.fingerprint)
        #expect(try store.fingerprintsIndexed([fp], outside: l1.id) == [fp])
        #expect(try store.fingerprintsIndexed([fp], outside: l1.id, fileExists: { _ in false }).isEmpty)
        try store.setLocationOnline(l2.id, online: false, lastKnownPath: nil)
        #expect(try store.fingerprintsIndexed([fp], outside: l1.id, fileExists: { _ in false }) == [fp])
    }

    @Test func deleteFilesReturnsWhatItDeleted() throws {
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "A", displayName: "A", lastKnownPath: "/nowhere")
        let a = try insertFake(store, loc.id, "a.otf", ps: ["A"])
        let b = try insertFake(store, loc.id, "b.otf", ps: ["B"])
        #expect(try store.deleteFiles([a]) == [a])
        #expect(try store.deleteFiles([a, b]) == [b])  // a was already gone (a concurrent scan, say)
    }

    // MARK: Performance

    @Test func groupsFastAt20k() throws {
        let store = try memoryStore()
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "R", displayName: "R", lastKnownPath: "/r")
        let loc2 = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "R2", displayName: "R2", lastKnownPath: "/r2")
        var hashes: [(Int64, String)] = []
        try store.database.transaction {
            for i in 0..<20_000 {
                // Every 4th file is an exact copy of the one before; every 10th shares a name with another version.
                let exactCopy = i % 4 == 1
                let base = exactCopy ? i - 1 : i
                let ps = i % 10 == 9 ? "PS-\(i - 5)" : "PS-\(base)"
                let id = try store.insertFile(
                    FileRecord(locationID: i.isMultiple(of: 2) ? loc.id : loc2.id, relativePath: "f\(i).otf", size: 1, mtime: Date(),
                               format: "otf", fingerprint: "fp\(base)"),
                    faces: [Fixture.face(ps, family: "Family \(i / 4)", style: "S", weight: 400)], importBatch: 1)
                if i % 4 <= 1 { hashes.append((id, "h\(base)")) }
            }
        }
        try store.setContentHashes(hashes)
        let finder = DuplicateFinder(store: store)
        var groups: [DuplicateGroup] = []
        let elapsed = try ContinuousClock().measure { groups = try finder.groups(includeSystem: true) }
        #expect(groups.filter { $0.kind == .exact }.count == 5_000)
        #expect(groups.contains { $0.kind == .sameFont })
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }
}
