import CoreText
import Foundation
import os
import Testing
@testable import FontoryCore

@Suite struct FaceMetadataTests {
    // MARK: Schema v4

    private func columns(_ db: Database, _ table: String) throws -> [String: String] {
        let s = try db.prepare("PRAGMA table_info(\(table))")
        defer { s.reset() }
        var out: [String: String] = [:]
        while try s.step() { out[s.text(1)] = s.text(4) }  // name → default value
        return out
    }

    @Test func migratesV3ToV4() throws {
        let db = try Database(path: ":memory:")
        try db.execute(Schema.v1)
        try db.execute("PRAGMA user_version = 1")
        // Bring it to v3 the way the app did, then fill it with 20k faces.
        try db.execute(Schema.v2)
        try db.execute(Schema.v3)
        try db.execute("PRAGMA user_version = 3")
        try db.execute("INSERT INTO locations(id,kind,volume_uuid,relative_path,display_name,last_known_path) VALUES(1,0,'v','p','n','/p')")
        try db.transaction {
            let f = try db.prepare("INSERT INTO files(id,location_id,relative_path,size,mtime,format,fingerprint,added_at,import_batch) VALUES(?,1,?,1,0,'otf','fp',0,0)")
            let g = try db.prepare("""
            INSERT INTO faces(file_id,face_index,postscript_name,family,style,full_name,weight,width,slant,is_italic,is_variable,glyph_count,units_per_em,ascender,descender,cap_height,x_height,outline_type,is_color,is_bitmap,has_gsub,has_gpos,style_class,class_version)
            VALUES(?,0,?,'F','Regular','F Regular',400,5,0,0,0,10,1000,800,-200,700,500,'cff',0,0,0,0,5,3)
            """)
            for i in 1...20_000 {
                try f.bind([.int(Int64(i)), .text("f\(i).otf")]); _ = try f.step(); f.reset()
                try g.bind([.int(Int64(i)), .text("F-\(i)")]); _ = try g.step(); g.reset()
            }
        }
        let start = ContinuousClock.now
        try Schema.migrate(db)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(200), "v3 → v4 took \(elapsed)")

        let v = try db.prepare("PRAGMA user_version")
        #expect(try v.step())
        #expect(v.int64(0) == 4)
        v.reset()
        #expect(Schema.currentVersion == 4)

        let faceCols = try columns(db, "faces")
        #expect(faceCols["features"] == "''")
        #expect(faceCols["figure_style"] == "0")
        #expect(faceCols["meta_version"] == "0")
        #expect(Set(try columns(db, "face_coverage").keys) == ["face_id", "ranges"])
        #expect(Set(try columns(db, "excluded_files").keys) == ["location_id", "relative_path", "fingerprint"])

        let s = try db.prepare("SELECT COUNT(*), SUM(features = ''), SUM(figure_style = 0), SUM(meta_version = 0), SUM(class_version = 3) FROM faces")
        #expect(try s.step())
        #expect((0..<5).map { s.int64(Int32($0)) } == [20_000, 20_000, 20_000, 20_000, 20_000])
        s.reset()

        // Coverage rows go with their face; exclusions with their location.
        try db.execute("INSERT INTO face_coverage(face_id, ranges) VALUES(1, x'')")
        try db.execute("INSERT INTO excluded_files(location_id, relative_path, fingerprint) VALUES(1, 'a.otf', 'fp')")
        try db.execute("DELETE FROM faces WHERE id = 1")
        try db.execute("DELETE FROM locations WHERE id = 1")
        let c = try db.prepare("SELECT (SELECT COUNT(*) FROM face_coverage), (SELECT COUNT(*) FROM excluded_files)")
        #expect(try c.step())
        #expect(c.int64(0) == 0 && c.int64(1) == 0)
        c.reset()
    }

    // MARK: Coverage ranges

    @Test func coverageRangesRoundTrip() throws {
        let scalars: [UInt32] = [0x41, 0x42, 0x43, 0x45, 0x20, 0x1F600, 0x1F601, 0x20000, 0x43, 0x44]
        let cov = CoverageRanges(scalars: scalars)
        #expect(cov.ranges == [0x20...0x20, 0x41...0x45, 0x1F600...0x1F601, 0x20000...0x20000])
        let blob = cov.blob
        #expect(blob.count == 4 * 8)
        // Little-endian UInt32 pairs.
        #expect(Array(blob.prefix(8)) == [0x20, 0, 0, 0, 0x20, 0, 0, 0])
        #expect(Array(blob.suffix(8)) == [0x00, 0x00, 0x02, 0, 0x00, 0x00, 0x02, 0])
        #expect(CoverageRanges(blob: blob) == cov)
        #expect(CoverageRanges(scalars: []).blob.isEmpty)
        #expect(CoverageRanges(blob: Data())?.ranges.isEmpty == true)
        // Malformed blobs: odd length, end before start, unsorted, overlapping.
        #expect(CoverageRanges(blob: Data([1, 2, 3])) == nil)
        #expect(CoverageRanges(blob: CoverageRanges.encode([5...5, 1...2])) == nil)
        #expect(CoverageRanges(blob: CoverageRanges.encode([1...5, 5...6])) == nil)
        var bad = Data(); for v: UInt32 in [9, 3] { withUnsafeBytes(of: v.littleEndian) { bad.append(contentsOf: $0) } }
        #expect(CoverageRanges(blob: bad) == nil)
    }

    @Test func coverageContains() {
        let cov = CoverageRanges(scalars: Array(0x41...0x5A) + [0x61] + Array(0x1F600...0x1F64F) + [0x20000])
        for (scalar, want) in [(0x40, false), (0x41, true), (0x5A, true), (0x5B, false), (0x60, false), (0x61, true), (0x62, false),
                               (0x1F5FF, false), (0x1F600, true), (0x1F64F, true), (0x1F650, false),
                               (0x1FFFF, false), (0x20000, true), (0x20001, false), (0, false), (0x10FFFF, false)] as [(UInt32, Bool)] {
            #expect(cov.contains(scalar) == want, "U+\(String(scalar, radix: 16))")
        }
        #expect(!CoverageRanges(scalars: []).contains(0x41))
    }

    @Test func coverageOfAFontMatchesCoreText() throws {
        let font = CTFontCreateWithFontDescriptor(
            try #require((CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: TempFonts.emoji) as CFURL) as? [CTFontDescriptor])?.first), 12, nil)
        let meta = FaceMetadata.read(font)
        let set = CTFontCopyCharacterSet(font) as CharacterSet
        #expect(meta.coverage.contains(0x1F600))
        for scalar: UInt32 in [0x23, 0x30, 0xA9, 0x1F600, 0x1F44D, 0x1F9D1, 0x41, 0x4E00] {
            #expect(meta.coverage.contains(scalar) == set.contains(Unicode.Scalar(scalar)!), "U+\(String(scalar, radix: 16))")
        }
        let count = meta.coverage.ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound + 1) }
        var expected = 0
        for plane: UInt8 in 0...16 where set.hasMember(inPlane: plane) {
            for v in UInt32(plane) << 16 ... (UInt32(plane) << 16 | 0xFFFF) {
                if let u = Unicode.Scalar(v), set.contains(u) { expected += 1 }
            }
        }
        #expect(count == expected)
    }

    // MARK: Features and figures

    private func faces(_ path: String) -> [CTFont]? {
        guard FileManager.default.fileExists(atPath: path) else {
            Issue.record("fixture not installed, skipped: \(path)", severity: .warning)
            return nil
        }
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor]) ?? []
        return descriptors.map { CTFontCreateWithFontDescriptor($0, 12, nil) }
    }

    @Test func featuresOfFixtureFonts() throws {
        if let hoefler = faces(TempFonts.hoeflerText) {
            let regular = try #require(hoefler.first { CTFontCopyPostScriptName($0) as String == "HoeflerText-Regular" } ?? hoefler.first)
            let tags = FaceMetadata.read(regular).features
            #expect(tags.contains("liga") && tags.contains("onum"), "\(tags)")
            #expect(tags == Array(Set(tags)).sorted())
        }
        if let newYork = faces(TempFonts.newYork), let face = newYork.first {
            let tags = FaceMetadata.read(face).features
            #expect(tags.contains("ss01"), "\(tags)")
            #expect(tags == Array(Set(tags)).sorted())
            #expect(tags.allSatisfy { $0.utf8.count == 4 && !$0.contains(" ") })
        }
        #expect(FaceMetadata.featuresText([]) == "")
        #expect(FaceMetadata.featuresText(["liga", "smcp"]) == " liga smcp ")
    }

    @Test func figureStyleOfFixtureFonts() throws {
        if let hoefler = faces(TempFonts.hoeflerText) {
            let regular = try #require(hoefler.first { CTFontCopyPostScriptName($0) as String == "HoeflerText-Regular" } ?? hoefler.first)
            #expect(FaceMetadata.read(regular).figureStyle == .oldstyle)
        }
        if let helvetica = faces("/System/Library/Fonts/Helvetica.ttc") {
            #expect(helvetica.allSatisfy { FaceMetadata.read($0).figureStyle == .lining })
        }
        if let arial = faces(TempFonts.arialBold) {
            #expect(arial.allSatisfy { FaceMetadata.read($0).figureStyle == .lining })
        }
        // No digits at all: unknown.
        if let dingbats = faces("/System/Library/Fonts/ZapfDingbats.ttf") {
            #expect(dingbats.allSatisfy { FaceMetadata.read($0).figureStyle == .unknown })
        }
    }

    // MARK: Store and backfill

    private func meta(_ store: FontStore) throws -> [(classVersion: Int, metaVersion: Int, features: String, figure: Int, ranges: Data?)] {
        try store.reader.withLock {
            let s = try store.reader.prepare("""
            SELECT faces.class_version, faces.meta_version, faces.features, faces.figure_style, face_coverage.ranges
            FROM faces LEFT JOIN face_coverage ON face_coverage.face_id = faces.id ORDER BY faces.id
            """)
            defer { s.reset() }
            var out: [(Int, Int, String, Int, Data?)] = []
            while try s.step() {
                out.append((Int(s.int64(0)), Int(s.int64(1)), s.text(2), Int(s.int64(3)), s.isNull(4) ? nil : s.blob(4)))
            }
            return out
        }
    }

    @Test func insertWritesMetadata() throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let url = try temp.copy(TempFonts.arialBold, as: "a.ttf")
        let parsed = try FontParser.parse(url: url)
        let face = try #require(parsed.first)
        let metadata = try #require(face.metadata)
        #expect(metadata.coverage.contains(0x41) && metadata.figureStyle == .lining && metadata.features.contains("kern"))

        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: temp.root.path)
        let fileID = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "a.ttf", size: 1, mtime: Date(), format: "ttf", fingerprint: "a"),
                                          faces: parsed, importBatch: try store.nextImportBatch())
        var rows = try meta(store)
        #expect(rows.count == 1)
        #expect(rows[0].metaVersion == FaceMetadata.version && rows[0].classVersion == StyleClassifier.version)
        #expect(rows[0].features == FaceMetadata.featuresText(metadata.features))
        #expect(rows[0].figure == FigureStyle.lining.rawValue)
        #expect(rows[0].ranges.flatMap(CoverageRanges.init(blob:)) == metadata.coverage)
        #expect(try store.countFacesNeedingBackfill() == 0)
        #expect(try store.facesNeedingBackfill(limit: 10, afterID: 0).isEmpty)

        // A rescan replaces it in place; a face without metadata (unread) waits for the backfill.
        var unread = face
        unread.metadata = nil
        try store.replaceFaces(fileID: fileID, size: 2, mtime: Date(), fingerprint: "b", faces: [unread])
        rows = try meta(store)
        #expect(rows.count == 1 && rows[0].metaVersion == 0 && rows[0].features == "" && rows[0].ranges == nil)
        #expect(try store.countFacesNeedingBackfill() == 1)
        try store.replaceFaces(fileID: fileID, size: 3, mtime: Date(), fingerprint: "c", faces: parsed)
        rows = try meta(store)
        #expect(rows.count == 1 && rows[0].metaVersion == FaceMetadata.version && rows[0].ranges != nil)
        #expect(try store.countFacesNeedingBackfill() == 0)
    }

    /// Counts file opens, for the backfill's open seam.
    final class OpenCounter: Sendable {
        let opens = OSAllocatedUnfairLock<[URL: Int]>(initialState: [:])
        func open(_ url: URL) -> [CTFontDescriptor] {
            opens.withLock { $0[url, default: 0] += 1 }
            return FaceBackfill.openDescriptors(url)
        }
    }

    @Test func backfillFillsMetadataOnce() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: temp.root.path)
        let batch = try store.nextImportBatch()
        let files = [(TempFonts.arialBold, "a.ttf"), (TempFonts.hoeflerText, "h.ttc"), (TempFonts.avenirNext, "av.ttc")]
        for (path, name) in files {
            let url = try temp.copy(path, as: name)
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: name, size: 1, mtime: Date(), format: "ttf", fingerprint: name),
                                     faces: try FontParser.parse(url: url), importBatch: batch)
        }
        // Junk that is present (unparsable) and an offline location: unknown + empty metadata, and untouched.
        _ = try temp.junk("junk.ttf")
        _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "junk.ttf", size: 1, mtime: Date(), format: "ttf", fingerprint: "j"),
                                 faces: [Fixture.face("J", family: "J", style: "R", weight: 400)], importBatch: batch)
        let off = try store.upsertLocation(kind: .folder, volumeUUID: "W", relativePath: "G", displayName: "G", lastKnownPath: "/nonexistent")
        _ = try store.insertFile(FileRecord(locationID: off.id, relativePath: "x.ttf", size: 1, mtime: Date(), format: "ttf", fingerprint: "x"),
                                 faces: [Fixture.face("X", family: "X", style: "R", weight: 400)], importBatch: batch)
        try store.setLocationOnline(off.id, online: false, lastKnownPath: nil)
        // Old class versions on some faces, no metadata on all of them.
        try store.database.withLock {
            try store.database.execute("UPDATE faces SET class_version = 0 WHERE id % 2 = 0")
            try store.database.execute("UPDATE faces SET meta_version = 0, features = '', figure_style = 0")
            try store.database.execute("DELETE FROM face_coverage")
        }
        let total = try store.countFacesNeedingBackfill()
        let online = try meta(store).count - 1
        #expect(total == online)

        let counter = OpenCounter()
        var last: BackfillProgress?
        for await p in FaceBackfill(store: store, open: { counter.open($0) }).run() { last = p }
        #expect(last == BackfillProgress(done: total, total: total))

        let rows = try meta(store)
        let onlineRows = rows.dropLast()
        #expect(onlineRows.allSatisfy { $0.classVersion == StyleClassifier.version && $0.metaVersion == FaceMetadata.version && $0.ranges != nil })
        // Real faces got real metadata; the junk face got empty metadata at the current versions.
        let real = onlineRows.dropLast()
        #expect(real.allSatisfy { $0.ranges?.isEmpty == false })
        let arial = try #require(real.first)
        #expect(!arial.features.isEmpty && arial.figure == FigureStyle.lining.rawValue)
        let junk = try #require(onlineRows.last)
        #expect(junk.features == "" && junk.figure == 0 && junk.ranges == Data())
        // The offline face waits.
        let offline = try #require(rows.last)
        #expect(offline.metaVersion == 0 && offline.ranges == nil)
        #expect(try store.countFacesNeedingBackfill() == 0)

        // One open per file for all its faces (class and metadata from the same read): never more than one per face.
        let opens = counter.opens.withLock { $0 }
        #expect(opens.count == 4, "\(opens)")
        #expect(opens.values.allSatisfy { $0 == 1 }, "\(opens)")
        #expect(opens.values.reduce(0, +) <= total)

        // Nothing left: a second run reads nothing.
        let again = OpenCounter()
        for await _ in FaceBackfill(store: store, open: { again.open($0) }).run() {}
        #expect(again.opens.withLock { $0.isEmpty })
    }

    @Test func setBackfillResultsWritesEverything() throws {
        let f = try Fixture.make()
        let id = try #require(f.faceIDs.values.min())
        let metadata = FaceMetadata(coverage: CoverageRanges(scalars: [0x41, 0x42]), features: ["liga", "onum"], figureStyle: .oldstyle)
        try f.store.setBackfillResults([(id, StyleClass.serif, metadata)])
        let row = try #require(try meta(f.store).first)
        #expect(row.classVersion == StyleClassifier.version && row.metaVersion == FaceMetadata.version)
        #expect(row.features == " liga onum " && row.figure == 2 && row.ranges == metadata.coverage.blob)
    }

    // MARK: Cost

    /// Per-face cost on typical fonts, file by file (a mean over all faces would be SFNS's 369 named instances).
    /// Unoptimized test builds; release builds are 10–30× faster.
    @Test func extractionCost() throws {
        let typical = [TempFonts.arialBold, TempFonts.avenirNext, TempFonts.hoeflerText, TempFonts.newYork,
                       "/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Times New Roman.ttf"]
        func perFace(_ path: String) -> Duration? {
            guard let fonts = faces(path), !fonts.isEmpty else { return nil }
            for font in fonts { _ = FaceMetadata.read(font) }  // warm
            let start = ContinuousClock.now
            for _ in 0..<3 { for font in fonts { _ = FaceMetadata.read(font) } }
            return (ContinuousClock.now - start) / (3 * fonts.count)
        }
        for path in typical {
            guard let cost = perFace(path) else { continue }
            print("FaceMetadata.read: \(cost) per face, \(URL(fileURLWithPath: path).lastPathComponent)")
            #expect(cost < .milliseconds(5), "\(path): \(cost)")
        }
        if let sfns = perFace(TempFonts.sfns) { print("FaceMetadata.read: \(sfns) per face, SFNS.ttf (large variable font, not asserted)") }
    }
}
