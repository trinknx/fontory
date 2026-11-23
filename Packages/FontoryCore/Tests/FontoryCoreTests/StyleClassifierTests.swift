import Foundation
import Testing
@testable import FontoryCore

struct StyleClassifierTests {
    private static func input(
        cls: Int? = nil, mask: Int? = nil, panose: [UInt8]? = nil, mono: Bool = false, symbolCmap: Bool = false, unicodeCmap: Bool = false,
        latin: Bool = true,
        names: [String] = ["Test", "Test Regular", "Regular"]
    ) -> StyleClassifier.Input {
        .init(familyClass: cls, familySubclass: 0, classMask: mask, panose: panose, isMonospace: mono, hasSymbolCmap: symbolCmap,
              hasUnicodeCmap: unicodeCmap, coversLatin: latin, names: names)
    }

    private static func panose(family: UInt8 = 0, serif: UInt8 = 0, proportion: UInt8 = 0) -> [UInt8] {
        [family, serif, 0, proportion, 0, 0, 0, 0, 0, 0]
    }

    @Test(arguments: [
        // 1 symbol
        (StyleClassifierTests.input(cls: 12), StyleClass.symbol),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 5)), .symbol),
        (StyleClassifierTests.input(symbolCmap: true), .symbol),
        (StyleClassifierTests.input(cls: 8, mono: true, symbolCmap: true), .symbol),
        // A stray (3,0) beside a Unicode subtable is not a symbol font: the other signals decide.
        (StyleClassifierTests.input(cls: 1, symbolCmap: true, unicodeCmap: true), .serif),
        (StyleClassifierTests.input(symbolCmap: true, unicodeCmap: true), .display),
        (StyleClassifierTests.input(cls: 12, symbolCmap: true, unicodeCmap: true), .symbol),
        // 2 mono
        (StyleClassifierTests.input(mono: true), .mono),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, proportion: 9)), .mono),
        (StyleClassifierTests.input(cls: 5, mono: true), .mono),  // monospace slab
        (StyleClassifierTests.input(cls: 10, mono: true), .mono),
        // 3 script
        (StyleClassifierTests.input(cls: 10), .script),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 3)), .script),
        (StyleClassifierTests.input(names: ["Brush Script MT", "Brush Script MT Italic", "Italic"]), .script),
        (StyleClassifierTests.input(names: ["Handwriting", "Handwriting", "Regular"]), .script),
        (StyleClassifierTests.input(names: ["Calligraphia", "Calligraphia", "Regular"]), .script),
        (StyleClassifierTests.input(cls: 8, names: ["Fancy Script", "Fancy Script", "Regular"]), .script),
        (StyleClassifierTests.input(cls: 8, panose: StyleClassifierTests.panose(family: 3)), .script),
        (StyleClassifierTests.input(cls: 8), .sans),  // class 8 alone, no script signal
        // 4 slab
        (StyleClassifierTests.input(cls: 4), .slab),
        (StyleClassifierTests.input(cls: 5), .slab),
        (StyleClassifierTests.input(names: ["Roboto Slab", "Roboto Slab Bold", "Bold"]), .slab),
        (StyleClassifierTests.input(cls: 1, names: ["Roboto Slab", "Roboto Slab", "Regular"]), .slab),
        // 5 sans
        (StyleClassifierTests.input(cls: 8), .sans),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, serif: 11)), .sans),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, serif: 13)), .sans),
        (StyleClassifierTests.input(names: ["Work Sans", "Work Sans Medium", "Medium"]), .sans),
        (StyleClassifierTests.input(names: ["Hanken Grotesk", "Hanken Grotesk", "Regular"]), .sans),
        (StyleClassifierTests.input(names: ["Century Gothic", "Century Gothic", "Regular"]), .sans),
        (StyleClassifierTests.input(cls: 2, names: ["Work Sans", "Work Sans", "Regular"]), .sans),
        // 6 serif
        (StyleClassifierTests.input(cls: 1), .serif),
        (StyleClassifierTests.input(cls: 2), .serif),
        (StyleClassifierTests.input(cls: 3), .serif),
        (StyleClassifierTests.input(cls: 7), .serif),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, serif: 2)), .serif),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, serif: 10)), .serif),
        (StyleClassifierTests.input(names: ["Noto Serif", "Noto Serif Bold", "Bold"]), .serif),
        // CoreText class mask as the second source (sFamilyClass 0, empty PANOSE)
        (StyleClassifierTests.input(mask: 12), .symbol),
        (StyleClassifierTests.input(mask: 10), .script),
        (StyleClassifierTests.input(mask: 4), .slab),
        (StyleClassifierTests.input(mask: 5), .slab),
        (StyleClassifierTests.input(cls: 0, mask: 8), .sans),
        (StyleClassifierTests.input(mask: 1), .serif),
        (StyleClassifierTests.input(mask: 3), .serif),
        (StyleClassifierTests.input(mask: 7), .serif),
        (StyleClassifierTests.input(mask: 9), .display),
        (StyleClassifierTests.input(mask: 8, mono: true), .mono),
        (StyleClassifierTests.input(mask: 8, names: ["Fancy Script", "Fancy Script", "Regular"]), .script),
        // 7 display
        (StyleClassifierTests.input(cls: 9), .display),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 4)), .display),
        (StyleClassifierTests.input(), .display),  // Latin, nothing matched
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, serif: 1)), .display),
        (StyleClassifierTests.input(panose: StyleClassifierTests.panose(family: 2, serif: 14)), .display),
    ])
    func rule(_ input: StyleClassifier.Input, expected: StyleClass) {
        #expect(StyleClassifier.classify(input) == expected)
    }

    @Test func nonLatinUnknown() {
        #expect(StyleClassifier.classify(Self.input(latin: false)) == .unknown)
        // Signals still win without Latin coverage.
        #expect(StyleClassifier.classify(Self.input(cls: 8, latin: false)) == .sans)
        #expect(StyleClassifier.classify(Self.input(cls: 9, latin: false)) == .display)
    }

    @Test func shortPanoseIgnored() {
        #expect(StyleClassifier.classify(Self.input(panose: [5, 0, 0])) == .display)
    }

    // MARK: Fixture fonts

    @Test func fixtureFontsClassify() throws {
        let expected: [(String, StyleClass)] = [
            (TempFonts.arialBold, .sans), (TempFonts.avenirNext, .sans), (TempFonts.hoeflerText, .serif), (TempFonts.newYork, .serif), (TempFonts.sfns, .sans),
            ("/System/Library/Fonts/Helvetica.ttc", .sans), ("/System/Library/Fonts/HelveticaNeue.ttc", .sans),
            ("/System/Library/Fonts/Palatino.ttc", .serif), ("/System/Library/Fonts/Supplemental/Times New Roman.ttf", .serif),
            ("/System/Library/Fonts/Menlo.ttc", .mono), ("/System/Library/Fonts/Monaco.ttf", .mono),
        ]
        for (path, want) in expected {
            guard FileManager.default.fileExists(atPath: path) else {
                Issue.record("fixture not installed, skipped: \(path)", severity: .warning)
                continue
            }
            let faces = try FontParser.parse(url: URL(fileURLWithPath: path))
            #expect(faces.allSatisfy { $0.styleClass == want }, "\(path): \(faces.map(\.styleClass.title))")
        }
        // No Latin coverage, but CoreText's class mask says symbol.
        let emoji = try FontParser.parse(url: URL(fileURLWithPath: TempFonts.emoji))
        #expect(emoji.allSatisfy { $0.styleClass == .symbol })
    }

    @Test func parsedClassIsStored() throws {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: "/x")
        var face = Fixture.face("A-Regular", family: "A", style: "Regular", weight: 400)
        face.styleClass = .slab
        let batch = try store.nextImportBatch()
        let fileID = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "a.otf", size: 1, mtime: Date(), format: "otf", fingerprint: "a"),
                                          faces: [face], importBatch: batch)
        #expect(try classes(store) == [.slab])
        #expect(try store.facesNeedingClassification(limit: 10).isEmpty)
        face.styleClass = .script
        try store.replaceFaces(fileID: fileID, size: 2, mtime: Date(), fingerprint: "b", faces: [face])
        #expect(try classes(store) == [.script])
        #expect(try store.facesNeedingClassification(limit: 10).isEmpty)
    }

    // MARK: Backfill

    private func classes(_ store: FontStore) throws -> [StyleClass] {
        try store.reader.withLock {
            let s = try store.reader.prepare("SELECT style_class FROM faces ORDER BY id")
            defer { s.reset() }
            var out: [StyleClass] = []
            while try s.step() { out.append(StyleClass(rawValue: Int(s.int64(0))) ?? .unknown) }
            return out
        }
    }

    private func versions(_ store: FontStore) throws -> [Int] {
        try store.reader.withLock {
            let s = try store.reader.prepare("SELECT class_version FROM faces ORDER BY id")
            defer { s.reset() }
            var out: [Int] = []
            while try s.step() { out.append(Int(s.int64(0))) }
            return out
        }
    }

    /// A store whose faces point at real font files in a temp folder, with every class_version reset to 0.
    private func libraryOfFonts(_ fonts: [(String, String)], temp: TempFonts) throws -> (FontStore, LocationRecord) {
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: temp.root.path)
        let batch = try store.nextImportBatch()
        for (path, name) in fonts {
            let url = try temp.copy(path, as: name)
            let faces = try FontParser.parse(url: url)
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: name, size: 1, mtime: Date(), format: "ttf", fingerprint: name),
                                     faces: faces, importBatch: batch)
        }
        try store.database.withLock { try store.database.execute("UPDATE faces SET style_class = 0, class_version = 0") }
        return (store, loc)
    }

    @Test func backfillClassifiesOldFaces() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let (store, _) = try libraryOfFonts([(TempFonts.arialBold, "a.ttf"), (TempFonts.hoeflerText, "h.ttc"), (TempFonts.avenirNext, "av.ttc")], temp: temp)
        let total = try store.countFacesNeedingClassification()
        #expect(total > 3)
        var last: BackfillProgress?
        for await p in FaceBackfill(store: store).run() { last = p }
        #expect(last == BackfillProgress(done: total, total: total))
        #expect(try versions(store).allSatisfy { $0 == StyleClassifier.version })
        #expect(try classes(store).allSatisfy { $0 != .unknown })
        #expect(try store.facesNeedingClassification(limit: 10).isEmpty)
    }

    @Test func backfillSkipsOfflineThenResumes() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let (store, loc) = try libraryOfFonts([(TempFonts.arialBold, "a.ttf")], temp: temp)
        try store.setLocationOnline(loc.id, online: false, lastKnownPath: nil)
        for await _ in FaceBackfill(store: store).run() {}
        #expect(try versions(store) == [0])
        try store.setLocationOnline(loc.id, online: true, lastKnownPath: nil)
        for await _ in FaceBackfill(store: store).run() {}
        #expect(try versions(store) == [StyleClassifier.version])
        #expect(try classes(store) == [.sans])
    }

    @Test func backfillMarksUnreadable() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let (store, _) = try libraryOfFonts([(TempFonts.arialBold, "a.ttf"), (TempFonts.hoeflerText, "h.ttc")], temp: temp)
        // Present but not a font any more.
        try Data(repeating: 0x5A, count: 512).write(to: temp.root.appendingPathComponent("a.ttf"))
        for await _ in FaceBackfill(store: store).run() {}
        #expect(try versions(store).allSatisfy { $0 == StyleClassifier.version })
        let got = try classes(store)
        #expect(got.first == .unknown)
        #expect(got.dropFirst().allSatisfy { $0 == .serif } && got.count > 1)
        // Not retried.
        #expect(try store.facesNeedingClassification(limit: 10).isEmpty)
    }

    @Test func backfillRunsInBatchesOfAtMost200() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        _ = try temp.junk("big.ttc")  // present, unparsable: classified unknown
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: temp.root.path)
        let batch = try store.nextImportBatch()
        let faces = (0..<450).map { Fixture.face("P-\($0)", family: "P", style: "\($0)", weight: 400, index: $0) }
        _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "big.ttc", size: 1, mtime: Date(), format: "ttc", fingerprint: "big"),
                                 faces: faces, importBatch: batch)
        try store.database.withLock { try store.database.execute("UPDATE faces SET class_version = 0") }
        var seen: [Int] = []
        for await p in FaceBackfill(store: store).run() { seen.append(p.done) }
        #expect(seen == [0, 200, 400, 450])
    }

    @Test func backfillCancellationKeepsWrittenBatches() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        _ = try temp.junk("big.ttc")  // present, unparsable: classified unknown
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: temp.root.path)
        let batch = try store.nextImportBatch()
        let faces = (0..<450).map { Fixture.face("P-\($0)", family: "P", style: "\($0)", weight: 400, index: $0) }
        _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "big.ttc", size: 1, mtime: Date(), format: "ttc", fingerprint: "big"),
                                 faces: faces, importBatch: batch)
        try store.database.withLock { try store.database.execute("UPDATE faces SET class_version = 0") }
        for await p in FaceBackfill(store: store).run() where p.done >= 200 { break }  // stop consuming
        try await Task.sleep(for: .milliseconds(300))
        let remaining = try store.countFacesNeedingClassification()
        #expect(remaining < 450)
        #expect(try versions(store).filter { $0 == StyleClassifier.version }.count == 450 - remaining)
    }

    @Test func classifyChecksCancellationBeforeEveryFace() throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let url = try temp.copy(TempFonts.arialBold, as: "a.ttf")
        let batch = (0..<5).map { (faceID: Int64($0), url: url, faceIndex: 0) }
        var asked = 0
        let stopped = FaceBackfill.read(batch, isCancelled: { asked += 1; return asked > 2 })
        #expect(stopped == nil && asked == 3)
        let all = FaceBackfill.read(batch, isCancelled: { false })
        #expect(all?.count == 5 && all?.allSatisfy { $0.styleClass == .sans } == true)
    }

    @Test func cancelledRunLeavesNothingInFlight() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        _ = try temp.junk("big.ttc")  // present, unparsable: classified unknown
        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "F", displayName: "F", lastKnownPath: temp.root.path)
        let batch = try store.nextImportBatch()
        let faces = (0..<450).map { Fixture.face("P-\($0)", family: "P", style: "\($0)", weight: 400, index: $0) }
        _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "big.ttc", size: 1, mtime: Date(), format: "ttc", fingerprint: "big"),
                                 faces: faces, importBatch: batch)
        try store.database.withLock { try store.database.execute("UPDATE faces SET class_version = 0") }
        let backfill = FaceBackfill(store: store)
        let task = Task {
            for await p in backfill.run() where p.done >= 200 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        await task.value
        // The iterating task has ended, so the run has too: nothing is written afterwards.
        let remaining = try store.countFacesNeedingClassification()
        try await Task.sleep(for: .milliseconds(200))
        let later = try store.countFacesNeedingClassification()
        #expect(remaining == 250 && later == remaining)
    }

    @Test func backfillLeavesUnreachableFilesForLater() async throws {
        let temp = try TempFonts(); defer { temp.cleanup() }
        let (store, _) = try libraryOfFonts([(TempFonts.arialBold, "a.ttf"), (TempFonts.hoeflerText, "h.ttc")], temp: temp)
        // Gone (a pulled drive looks the same): not stamped, while the other file is still classified.
        let moved = temp.root.appendingPathComponent("a.moved")
        try FileManager.default.moveItem(at: temp.root.appendingPathComponent("a.ttf"), to: moved)
        var last: BackfillProgress?
        for await p in FaceBackfill(store: store).run() { last = p }
        let stamped = try versions(store)
        #expect(stamped.first == 0 && stamped.dropFirst().allSatisfy { $0 == StyleClassifier.version })
        #expect(last?.done == last?.total)
        #expect(try store.countFacesNeedingClassification() == 1)
        // Back: classified by the next run.
        try FileManager.default.moveItem(at: moved, to: temp.root.appendingPathComponent("a.ttf"))
        for await _ in FaceBackfill(store: store).run() {}
        #expect(try versions(store).allSatisfy { $0 == StyleClassifier.version })
        #expect(try classes(store).first == .sans)
    }
}
