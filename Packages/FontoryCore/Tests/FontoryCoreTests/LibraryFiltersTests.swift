import Foundation
import Testing
@testable import FontoryCore

@Suite struct LibraryFiltersTests {
    /// Fixture faces get metadata by hand: the six faces differ in everything the filters look at.
    private struct World {
        let f: Fixture
        var s: FontStore { f.store }
        func id(_ n: String) -> Int64 { f.faceIDs[n]! }
        func ids(_ filters: LibraryFilters) throws -> Set<Int64> {
            var q = LibraryQuery(); q.filters = filters
            return Set(try s.faceIDs(for: q))
        }
        func all(_ names: String...) -> Set<Int64> { Set(names.map(id)) }
    }

    private func range(_ s: UInt32, _ e: UInt32) -> ClosedRange<UInt32> { s...e }

    private func world() throws -> World {
        let w = World(f: try Fixture.make())
        func set(_ name: String, scalars: [ClosedRange<UInt32>]?, features: [String] = [], figure: FigureStyle = .unknown, outline: String = "truetype",
                 variable: Bool = false, color: Bool = false, x: Double = 0, cap: Double = 0, scripts: Int64 = 0) throws {
            let id = w.id(name)
            try w.s.database.withLock {
                let u = try w.s.database.prepare("""
                UPDATE faces SET features = ?, figure_style = ?, outline_type = ?, is_variable = ?, is_color = ?, x_height = ?, cap_height = ?, scripts_bitmask = ? WHERE id = ?
                """)
                defer { u.reset() }
                try u.bind([.text(FaceMetadata.featuresText(features)), .int(Int64(figure.rawValue)), .text(outline), .int(variable ? 1 : 0), .int(color ? 1 : 0),
                            .double(x), .double(cap), .int(scripts), .int(id)])
                _ = try u.step()
                if let scalars {
                    let c = try w.s.database.prepare("INSERT OR REPLACE INTO face_coverage(face_id, ranges) VALUES(?, ?)")
                    defer { c.reset() }
                    var set: [UInt32] = []
                    for r in scalars { set += Array(r.lowerBound...r.upperBound) }
                    try c.bind([.int(id), .blob(CoverageRanges(scalars: set).blob)])
                    _ = try c.step()
                }
            }
        }
        let latin: [ClosedRange<UInt32>] = [0x41...0x5A, 0x61...0x7A]
        let viet = VietnameseLetters.scalars.map { $0...$0 }
        try set("Alpha-Regular", scalars: latin + [0x301...0x301], features: ["liga", "smcp"], figure: .lining, outline: "cff", x: 500, cap: 700, scripts: 0b11)
        try set("Alpha-Italic", scalars: latin, features: ["liga"], figure: .oldstyle, outline: "cff2", variable: true, x: 450, cap: 700, scripts: 0b1)
        try set("Alpha-Bold", scalars: latin + [0x1F600...0x1F600, 0x20000...0x20000], features: ["onum", "ss01"], figure: .lining, outline: "truetype", x: 540, cap: 700, scripts: 0b1)
        try set("Beta-Light", scalars: latin + viet + [0x301...0x301], features: ["liga", "ss01"], figure: .oldstyle, outline: "truetype", color: true, x: 480, cap: 700, scripts: 0b11)
        try set("Beta-Regular", scalars: nil, outline: "bitmap", x: 0, cap: 0)   // no coverage row, no metrics
        try set("Beta-Black", scalars: [0x41...0x41], features: ["ss01"], figure: .unknown, outline: "cff", variable: true, x: 500, cap: 700, scripts: 0b100)
        return w
    }

    @Test func emptyFiltersChangeNothing() {
        var q = LibraryQuery(scope: .system, sort: .weight)
        let before = q.sql(columns: "faces.id"), beforeCount = q.countSQL()
        q.filters = LibraryFilters()
        let after = q.sql(columns: "faces.id"), afterCount = q.countSQL()
        #expect(before.sql == after.sql && before.bindings == after.bindings)
        #expect(beforeCount.sql == afterCount.sql && beforeCount.bindings == afterCount.bindings)
        #expect(LibraryFilters().isEmpty && LibraryFilters().activeCount == 0)
        var spaces = LibraryFilters(); spaces.requiredCharacters = " \n\t"; spaces.features = [" "]
        #expect(spaces.isEmpty)
    }

    @Test func activeCountCountsEachControl() {
        var f = LibraryFilters()
        f.requiredCharacters = "ab"; f.scriptIndex = 2; f.vietnamese = true; f.figures = .lining; f.features = ["liga", "smcp"]
        f.outline = .cff; f.variable = .only; f.color = .exclude; f.xHeight = .high
        #expect(f.activeCount == 9 && !f.isEmpty)
    }

    @Test func requiredCharacters() throws {
        let w = try world()
        var f = LibraryFilters()
        f.requiredCharacters = "A b\n"   // whitespace ignored
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Alpha-Italic", "Alpha-Bold", "Beta-Light"))
        f.requiredCharacters = "Ab😀"
        #expect(try w.ids(f) == w.all("Alpha-Bold"))
    }

    @Test func requiredCharactersUseScalars() throws {
        let w = try world()
        var f = LibraryFilters()
        f.requiredCharacters = "😀"
        #expect(try w.ids(f) == w.all("Alpha-Bold"))
        f.requiredCharacters = "𠀀"
        #expect(try w.ids(f) == w.all("Alpha-Bold"))
        // "e" + U+0301 is two scalars: both needed.
        f.requiredCharacters = "e\u{301}"
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Beta-Light"))
        f.requiredCharacters = "\u{301}"
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Beta-Light"))
    }

    @Test func scriptFilter() throws {
        let w = try world()
        var f = LibraryFilters()
        f.scriptIndex = 1
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Beta-Light"))
        f.scriptIndex = 2
        #expect(try w.ids(f) == w.all("Beta-Black"))
        f.scriptIndex = 999
        #expect(try w.ids(f).isEmpty)
    }

    @Test func vietnameseRequiresAllLetters() throws {
        let w = try world()
        var f = LibraryFilters()
        f.vietnamese = true
        #expect(try w.ids(f) == w.all("Beta-Light"))
        #expect(VietnameseLetters.scalars.count > 100 && VietnameseLetters.scalars.contains(0x1EA0) && VietnameseLetters.scalars.contains(0x1EF9))
        #expect(!VietnameseLetters.scalars.contains(0xC0))   // À is not in the Vietnamese part
        // Missing one letter fails.
        let missing = VietnameseLetters.scalars.last!
        try w.s.database.withLock {
            let cov = CoverageRanges(scalars: [0x41] + VietnameseLetters.scalars.dropLast())
            let c = try w.s.database.prepare("UPDATE face_coverage SET ranges = ? WHERE face_id = ?")
            defer { c.reset() }
            try c.bind([.blob(cov.blob), .int(w.id("Beta-Light"))]); _ = try c.step()
        }
        #expect(!CoverageRanges(scalars: VietnameseLetters.scalars.dropLast()).contains(missing))
        #expect(try w.ids(f).isEmpty)
    }

    @Test func figuresFilter() throws {
        let w = try world()
        var f = LibraryFilters()
        f.figures = .lining
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Alpha-Bold"))
        f.figures = .oldstyle
        #expect(try w.ids(f) == w.all("Alpha-Italic", "Beta-Light"))
    }

    @Test func featuresAreAllRequired() throws {
        let w = try world()
        var f = LibraryFilters()
        f.features = ["liga"]
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Alpha-Italic", "Beta-Light"))
        f.features = ["liga", "ss01"]
        #expect(try w.ids(f) == w.all("Beta-Light"))
        f.features = ["ss0"]   // a prefix is not a tag
        #expect(try w.ids(f).isEmpty)
        f.features = [" LIGA "]   // tags are case-sensitive, spaces trimmed
        #expect(try w.ids(f).isEmpty)
    }

    @Test func outlineFilter() throws {
        let w = try world()
        var f = LibraryFilters()
        f.outline = .trueType
        #expect(try w.ids(f) == w.all("Alpha-Bold", "Beta-Light"))
        f.outline = .cff
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Alpha-Italic", "Beta-Black"))
        f.outline = .bitmap
        #expect(try w.ids(f) == w.all("Beta-Regular"))
    }

    @Test func kindTriStates() throws {
        let w = try world()
        var f = LibraryFilters()
        f.variable = .only
        #expect(try w.ids(f) == w.all("Alpha-Italic", "Beta-Black"))
        f.variable = .exclude   // "static"
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Alpha-Bold", "Beta-Light", "Beta-Regular"))
        f.variable = .any; f.color = .only
        #expect(try w.ids(f) == w.all("Beta-Light"))
        f.color = .exclude
        #expect(try w.ids(f).count == 5)
    }

    @Test func xHeightBands() throws {
        let w = try world()
        var f = LibraryFilters()
        f.xHeight = .low     // < 0.66: Alpha-Italic 0.643
        #expect(try w.ids(f) == w.all("Alpha-Italic"))
        f.xHeight = .medium  // 0.66-0.74: Alpha-Regular 0.714, Beta-Light 0.686, Beta-Black 0.714
        #expect(try w.ids(f) == w.all("Alpha-Regular", "Beta-Light", "Beta-Black"))
        f.xHeight = .high    // > 0.74: Alpha-Bold 0.771; Beta-Regular has no metrics and is excluded from every band
        #expect(try w.ids(f) == w.all("Alpha-Bold"))
    }

    @Test func combinedFiltersAnd() throws {
        let w = try world()
        var f = LibraryFilters()
        f.requiredCharacters = "A"; f.features = ["ss01"]
        #expect(try w.ids(f) == w.all("Alpha-Bold", "Beta-Light", "Beta-Black"))
        f.outline = .trueType
        #expect(try w.ids(f) == w.all("Alpha-Bold", "Beta-Light"))
        f.figures = .oldstyle
        #expect(try w.ids(f) == w.all("Beta-Light"))
        f.color = .exclude
        #expect(try w.ids(f).isEmpty)
        // Filters also AND with the scope and search.
        var q = LibraryQuery(scope: .all)
        q.filters.features = ["liga"]
        q.search = SearchText("Alpha")
        #expect(Set(try w.s.faceIDs(for: q)) == w.all("Alpha-Regular", "Alpha-Italic"))
    }

    @Test func facesWithoutCoverageFailCoverageFilters() throws {
        let w = try world()
        var f = LibraryFilters()
        f.requiredCharacters = "A"
        #expect(try !w.ids(f).contains(w.id("Beta-Regular")))
        f = LibraryFilters(); f.vietnamese = true
        #expect(try !w.ids(f).contains(w.id("Beta-Regular")))
        // Without a coverage filter it is still listed.
        #expect(try w.ids(LibraryFilters()).contains(w.id("Beta-Regular")))
    }

    @Test func countMatchesFaceIDsWithFilters() throws {
        let w = try world()
        var variants: [LibraryFilters] = [LibraryFilters()]
        var f = LibraryFilters(); f.requiredCharacters = "A"; variants.append(f)
        f = LibraryFilters(); f.features = ["liga"]; f.variable = .exclude; variants.append(f)
        f = LibraryFilters(); f.xHeight = .medium; f.outline = .cff; variants.append(f)
        f = LibraryFilters(); f.vietnamese = true; variants.append(f)
        for filters in variants {
            var q = LibraryQuery(); q.filters = filters
            #expect(try w.s.count(for: q) == w.s.faceIDs(for: q).count)
        }
    }

    @Test func coversFunctionEdges() {
        func covers(_ ranges: [ClosedRange<UInt32>], _ needed: [UInt32]) -> Bool {
            let r = CoverageRanges(scalars: ranges.flatMap { Array($0.lowerBound...$0.upperBound) }).blob
            let n = LibraryFilters.encode(needed)
            return n.withUnsafeBytes { nb in
                let runs = NeededRuns(needed: nb)
                return r.withUnsafeBytes { runs.covered(by: $0) }
            }
        }
        #expect(covers([0x41...0x5A], [0x41, 0x5A]))
        #expect(!covers([0x41...0x5A], [0x40]))
        #expect(!covers([0x41...0x5A], [0x5B]))
        #expect(!covers([0x41...0x42, 0x44...0x45], [0x43]))
        #expect(covers([0x10FFFF...0x10FFFF], [0x10FFFF]))
        #expect(!covers([], [0x41]))
        #expect(covers([], []))
        #expect(covers([0x41...0x5A, 0x61...0x7A], [0x7A, 0x41, 0x42, 0x61, 0x41]))   // any order, duplicates
        #expect(!covers([0x41...0x42], [0x41, 0x42, 0x43]))   // a run must fit one range
        #expect(covers([0x41...0x42, 0x61...0x62], [0x41, 0x42, 0x61, 0x62]))
    }

    // MARK: Performance

    @Test func filtersFastAt20k() throws {
        let f = try Fixture.make()
        let db = f.store.database
        // Realistic coverage: a few hundred ranges per face, most faces cover Latin; features and metrics vary.
        let letters: [UInt32] = Array(0x20...0x7E) + Array(0xC0...0x17F) + Array(0x391...0x3C9) + VietnameseLetters.scalars
        var base: [UInt32] = letters   // covers every case below, so no row exits early
        for i in 0..<250 { base += [UInt32(0x2000 + i * 40), UInt32(0x2000 + i * 40 + 1)] }
        let coverage = CoverageRanges(scalars: base).blob
        let tags = ["liga", "smcp", "onum", "ss01", "kern", "calt"]
        try db.transaction {
            let file = try db.prepare("INSERT INTO files(id,location_id,relative_path,size,mtime,format,fingerprint,added_at,import_batch) VALUES(?,?,?,1,0,'otf','fp',0,0)")
            let face = try db.prepare("""
            INSERT INTO faces(file_id,face_index,postscript_name,family,style,full_name,weight,width,slant,is_italic,is_variable,glyph_count,units_per_em,ascender,descender,cap_height,x_height,outline_type,is_color,is_bitmap,has_gsub,has_gpos,style_class,class_version,features,figure_style,scripts_bitmask)
            VALUES(?,0,?,?,'Regular','F Regular',400,5,0,0,?,10,1000,800,-200,700,?,?,0,0,0,0,5,3,?,?,3)
            """)
            let cov = try db.prepare("INSERT INTO face_coverage(face_id, ranges) SELECT id, ? FROM faces WHERE postscript_name = ?")
            for i in 0..<20_000 {
                let fileID = Int64(1000 + i)
                try file.bind([.int(fileID), .int(f.locA.id), .text("bulk\(i).otf")]); _ = try file.step(); file.reset()
                let tagText = FaceMetadata.featuresText(tags.enumerated().filter { (i >> $0.offset) & 1 == 1 }.map(\.element))
                try face.bind([.int(fileID), .text("Bulk-\(i)"), .text("Fam\(i % 700)"), .int(Int64(i % 5 == 0 ? 1 : 0)),
                               .double(Double(420 + i % 140)), .text(["cff", "truetype", "cff2"][i % 3]), .text(tagText), .int(Int64(i % 3))])
                _ = try face.step(); face.reset()
                try cov.bind([.blob(coverage), .text("Bulk-\(i)")]); _ = try cov.step(); cov.reset()
            }
        }
        let fifty = String(UnicodeScalar(0x41)!) + String((0x42..<0x42 + 25).map { Character(UnicodeScalar($0)!) }) + String((0xC0..<0xC0 + 24).map { Character(UnicodeScalar($0)!) })
        #expect(fifty.unicodeScalars.count == 50)

        // Worst case: 50 scalars with gaps (no two consecutive, so 50 runs) across Latin, Latin-1 and Greek, all covered.
        var scattered: [UInt32] = []
        for (first, count) in [(0x41, 13), (0x61, 13), (0xC0, 12), (0x391, 12)] as [(UInt32, UInt32)] {
            for i in 0..<count { scattered.append(first + i * 2) }
        }
        var scatteredText = ""
        for v in scattered { scatteredText.unicodeScalars.append(UnicodeScalar(v)!) }
        let scatteredData = LibraryFilters.encode(scattered)
        #expect(scatteredText.unicodeScalars.count == 50)
        #expect(scatteredData.withUnsafeBytes { NeededRuns(needed: $0).starts.count } == 50)

        var combos: [(String, LibraryFilters)] = []
        var w = LibraryFilters(); w.requiredCharacters = scatteredText; combos.append(("50 scattered scalars, all covered", w))
        w = LibraryFilters(); w.vietnamese = true; combos.append(("vietnamese, every face covers it", w))
        w = LibraryFilters(); w.vietnamese = true; w.requiredCharacters = scatteredText; combos.append(("vietnamese + 50 scattered", w))
        var a = LibraryFilters(); a.requiredCharacters = fifty; combos.append(("50 chars", a))
        a = LibraryFilters(); a.requiredCharacters = fifty + "\u{2000}"; combos.append(("50 chars + U+2000", a))
        a = LibraryFilters(); a.vietnamese = true; combos.append(("vietnamese", a))
        a = LibraryFilters(); a.scriptIndex = 0; a.figures = .lining; a.features = ["liga", "smcp", "ss01"]; combos.append(("script+figures+3 features", a))
        a = LibraryFilters(); a.outline = .cff; a.variable = .exclude; a.color = .exclude; a.xHeight = .medium; combos.append(("outline+kind+xheight", a))
        a = LibraryFilters(); a.requiredCharacters = fifty; a.vietnamese = true; a.figures = .oldstyle; a.features = ["liga", "onum"]
        a.outline = .trueType; a.variable = .only; a.color = .exclude; a.xHeight = .high; a.scriptIndex = 0; combos.append(("everything", a))
        for (name, filters) in combos {
            var q = LibraryQuery(); q.filters = filters
            _ = try f.store.faceIDs(for: q)   // prepare and warm
            _ = try f.store.count(for: q)
            // Best of three: the full suite runs other tests in parallel on the same cores.
            var listed = Duration.seconds(10), counted = Duration.seconds(10)
            var ids: [Int64] = [], n = 0
            for _ in 0..<3 {
                let start = ContinuousClock.now
                ids = try f.store.faceIDs(for: q)
                listed = min(listed, ContinuousClock.now - start)
                let countStart = ContinuousClock.now
                n = try f.store.count(for: q)
                counted = min(counted, ContinuousClock.now - countStart)
            }
            print("filter \(name): \(ids.count) faces, ids \(listed), count \(counted)")
            #expect(n == ids.count)
            #expect(listed < .milliseconds(100) && counted < .milliseconds(100), "\(name): ids \(listed), count \(counted)")
        }
        // The ordered list also includes the sort, still within budget.
        var q = LibraryQuery(); q.filters.requiredCharacters = fifty
        var best = Duration.seconds(10)
        var count = 0
        for _ in 0..<3 {
            let start = ContinuousClock.now
            count = try f.store.faceIDs(for: q).count
            best = min(best, ContinuousClock.now - start)
        }
        #expect(count > 10_000)
        #expect(best < .milliseconds(100), "sorted list took \(best)")
    }
}
