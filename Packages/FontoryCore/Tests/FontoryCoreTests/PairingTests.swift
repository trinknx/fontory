import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct PairingTests {
    private func ref(_ ps: String, _ family: String, fp: String? = nil, v: [String: Double]? = nil) -> FontReference {
        FontReference(postScriptName: ps, family: family, fingerprint: fp, variations: v)
    }

    private func style(_ ps: String, name: String, weight: Double, width: Double = 5, italic: Bool = false) -> PairingStyle {
        PairingStyle(reference: ref(ps, "F"), name: name, weight: weight, width: width, isItalic: italic)
    }

    @Test func resolvesByFingerprintThenUniqueName() throws {
        var f = try Fixture.make()
        let b = try f.store.nextImportBatch()
        // The same PostScript name in two files: only the fingerprint can tell them apart.
        try f.add(f.locA.id, "Dup1.otf", [Fixture.face("Dup", family: "Dup", style: "Regular", weight: 400)], b)
        try f.add(f.locA.id, "Dup2.otf", [Fixture.face("Dup", family: "Dup", style: "Regular", weight: 400)], b)
        let byFP = ref("Dup", "Dup", fp: "fp-Dup2.otf")
        let ambiguous = ref("Dup", "Dup")
        let unique = ref("Beta-Black", "Beta", fp: "stale-fingerprint")
        let gone = ref("Nope", "Nope", fp: "x")
        let out = try f.store.resolve([byFP, ambiguous, unique, gone])
        #expect(out[byFP]?.url?.lastPathComponent == "Dup2.otf")
        #expect(out[byFP]?.isMissing == false)
        #expect(out[ambiguous]?.faceID == nil && out[ambiguous]?.isMissing == true)
        #expect(out[unique]?.faceID == f.faceIDs["Beta-Black"] && out[unique]?.isMissing == false)
        #expect(out[gone]?.faceID == nil && out[gone]?.url == nil && out[gone]?.isMissing == true)
        #expect(out.count == 4)
    }

    /// Adds a file with an explicit fingerprint (copies of one font share it).
    private func addCopy(_ f: Fixture, _ loc: Int64, _ path: String, ps: String, fingerprint: String) throws -> Int64 {
        let file = FileRecord(locationID: loc, relativePath: path, size: 10, mtime: Date(timeIntervalSince1970: 1000),
                              format: "otf", fingerprint: fingerprint)
        _ = try f.store.insertFile(file, faces: [Fixture.face(ps, family: "Copy", style: "Regular", weight: 400)],
                                   importBatch: try f.store.nextImportBatch())
        let rows = try f.store.rows(ids: try f.store.faceIDs(for: LibraryQuery()))
        return try #require(rows.values.filter { $0.postScriptName == ps }.map(\.id).max())
    }

    @Test func copiesOfOneFilePreferTheOnlineOne() throws {
        let f = try Fixture.make()
        // The offline copy is added first (lower face id), the online one second.
        _ = try addCopy(f, f.locB.id, "Copy.otf", ps: "Copy-Regular", fingerprint: "fp-copy")
        let online = try addCopy(f, f.locA.id, "Copy.otf", ps: "Copy-Regular", fingerprint: "fp-copy")
        try f.store.setLocationOnline(f.locB.id, online: false, lastKnownPath: nil)
        let byFP = ref("Copy-Regular", "Copy", fp: "fp-copy")
        let byName = ref("Copy-Regular", "Copy")
        let out = try f.store.resolve([byFP, byName])
        #expect(out[byFP]?.faceID == online && out[byFP]?.isMissing == false)
        #expect(out[byFP]?.url?.path == "/Volumes/A/Fonts/Copy.otf")
        #expect(out[byName]?.faceID == online && out[byName]?.isMissing == false)
    }

    @Test func sameNameSameFingerprintResolves() throws {
        let f = try Fixture.make()
        let first = try addCopy(f, f.locA.id, "One/Same.otf", ps: "Same-Regular", fingerprint: "fp-same")
        _ = try addCopy(f, f.locA.id, "Two/Same.otf", ps: "Same-Regular", fingerprint: "fp-same")
        let r = ref("Same-Regular", "Copy")
        let out = try f.store.resolve([r])
        #expect(out[r]?.faceID == first && out[r]?.isMissing == false)
        #expect(out[r]?.url?.lastPathComponent == "Same.otf")
    }

    @Test func sameNameDifferentFingerprintsStaysUnresolved() throws {
        let f = try Fixture.make()
        _ = try addCopy(f, f.locA.id, "One/Diff.otf", ps: "Diff-Regular", fingerprint: "fp-diff-1")
        _ = try addCopy(f, f.locA.id, "Two/Diff.otf", ps: "Diff-Regular", fingerprint: "fp-diff-2")
        _ = try addCopy(f, f.locB.id, "Diff.otf", ps: "Diff-Regular", fingerprint: "fp-diff-1")
        let r = ref("Diff-Regular", "Copy")
        let out = try f.store.resolve([r])
        #expect(out[r]?.faceID == nil && out[r]?.isMissing == true)
    }

    @Test func offlineIsMissingButKeepsReference() throws {
        let f = try Fixture.make()
        try f.store.setLocationOnline(f.locB.id, online: false, lastKnownPath: nil)
        let r = ref("Beta-Regular", "Beta", fp: "fp-Beta-Regular.otf", v: ["wght": 500])
        let out = try f.store.resolve([r])
        #expect(out[r]?.reference == r)
        #expect(out[r]?.isMissing == true)
        #expect(out[r]?.url == nil)
        #expect(out[r]?.faceID == f.faceIDs["Beta-Regular"])
    }

    @Test func referenceForFace() throws {
        let f = try Fixture.make()
        try f.store.setCustomFamily("Renamed", faceIDs: [f.faceIDs["Alpha-Bold"]!])
        let r = try f.store.reference(forFace: f.faceIDs["Alpha-Bold"]!)
        #expect(r == ref("Alpha-Bold", "Renamed", fp: "fp-Alpha-Bold.otf"))
    }

    @Test func candidatesAreFamilies() throws {
        let f = try Fixture.make()
        let beta = ["Beta-Light", "Beta-Regular", "Beta-Black"].map { f.faceIDs[$0]! }
        let c = try f.store.candidateReferences(faceIDs: beta)
        #expect(c.count == 1)
        #expect(c[0].family == "Beta" && c[0].postScriptName == "Beta-Regular")
        let mixed = try f.store.candidateReferences(faceIDs: [f.faceIDs["Beta-Black"]!, f.faceIDs["Alpha-Bold"]!, f.faceIDs["Beta-Light"]!])
        #expect(mixed.map(\.family) == ["Beta", "Alpha"])
    }

    @Test func stylesOfFamily() throws {
        let f = try Fixture.make()
        let s = try f.store.styles(ofFamilyOf: ref("Alpha-Bold", "Alpha"))
        #expect(s.map(\.reference.postScriptName) == ["Alpha-Regular", "Alpha-Italic", "Alpha-Bold"])
        #expect(s.map(\.isItalic) == [false, true, false])
        #expect(s.allSatisfy { $0.reference.fingerprint != nil })
    }

    @Test func mergeAppendsWithoutDuplicates() {
        let a = ref("A-Regular", "Alpha"), b = ref("B-Regular", "Beta")
        let out = PairingCycler.merge([a], adding: [ref("A-Bold", "ALPHA"), b, ref("B-Black", "beta")])
        #expect(out == [a, b])
        #expect(PairingCycler.merge([], adding: [a]) == [a])
    }

    @Test func nextFamilyWraps() {
        let a = ref("A", "Alpha"), b = ref("B", "Beta"), c = ref("C", "Gamma")
        let cs = [a, b, c]
        #expect(PairingCycler.nextFamily(from: a, candidates: cs, step: 1) == b)
        #expect(PairingCycler.nextFamily(from: c, candidates: cs, step: 1) == a)
        #expect(PairingCycler.nextFamily(from: a, candidates: cs, step: -1) == c)
        #expect(PairingCycler.nextFamily(from: ref("X", "gamma"), candidates: cs, step: 1) == a)
        #expect(PairingCycler.nextFamily(from: ref("X", "Other"), candidates: cs, step: 1) == a)
        #expect(PairingCycler.nextFamily(from: ref("X", "Other"), candidates: cs, step: -1) == c)
        #expect(PairingCycler.nextFamily(from: a, candidates: [], step: 1) == nil)
        #expect(PairingCycler.nextFamily(from: a, candidates: [a], step: 1) == a)
    }

    @Test func nextStyleWrapsWithItalicsOnlyFamily() {
        let only = [style("I1", name: "Italic", weight: 400, italic: true)]
        #expect(PairingCycler.nextStyle(current: only[0].reference, styles: only, step: 1) == only[0].reference)
        #expect(PairingCycler.nextStyle(current: only[0].reference, styles: only, step: -1) == only[0].reference)
        let two = only + [style("I2", name: "Bold Italic", weight: 700, italic: true)]
        #expect(PairingCycler.nextStyle(current: two[1].reference, styles: two, step: 1) == two[0].reference)
        #expect(PairingCycler.nextStyle(current: two[0].reference, styles: two, step: -1) == two[1].reference)
        let cur = ref("Z", "F")
        #expect(PairingCycler.nextStyle(current: cur, styles: [], step: 1) == cur)
        #expect(PairingCycler.nextStyle(current: cur, styles: two, step: 1) == two[0].reference)
    }

    @Test func variableNamedInstancesAreStyles() throws {
        guard FileManager.default.fileExists(atPath: TempFonts.sfns) else { return }
        let temp = try TempFonts()
        defer { temp.cleanup() }
        let url = try temp.copy(TempFonts.sfns)
        let font = try #require(FontFile.font(at: url, faceIndex: 0, size: 12))
        let info = VariationInfo.read(font)
        try #require(!info.instances.isEmpty)

        let store = try FontStore(database: Database(path: ":memory:"))
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "V", relativePath: "x", displayName: "x", lastKnownPath: temp.root.path)
        let ps = CTFontCopyPostScriptName(font) as String
        var face = Fixture.face(ps, family: "SFVar", style: "Regular", weight: 400)
        face.isVariable = true
        _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "SFNS.ttf", size: 10, mtime: Date(), format: "ttf", fingerprint: "fp-sf"),
                                 faces: [face], importBatch: try store.nextImportBatch())
        let styles = try store.styles(ofFamilyOf: ref(ps, "SFVar"))
        #expect(styles.count == 1 + info.instances.count)
        let inst = styles.dropFirst()
        #expect(inst.allSatisfy { $0.reference.postScriptName == ps && $0.reference.fingerprint == "fp-sf" && $0.reference.variations?["wght"] != nil })
        // Cycling through everything wraps back to the start.
        var cur = styles[0].reference
        for _ in styles { cur = PairingCycler.nextStyle(current: cur, styles: styles, step: 1) }
        #expect(cur == styles[0].reference)
    }

    @Test func closestStylePrefersItalicThenWeight() {
        let styles = [
            style("R", name: "Regular", weight: 400),
            style("B", name: "Bold", weight: 700),
            style("I", name: "Italic", weight: 400, italic: true),
            style("BI", name: "Bold Italic", weight: 700, italic: true),
            style("BIW", name: "Wide Bold Italic", weight: 700, width: 7, italic: true),
        ]
        let boldItalic = style("X", name: "", weight: 650, italic: true)
        #expect(PairingCycler.closestStyle(to: boldItalic, in: styles).postScriptName == "BI")
        let reg = style("X", name: "", weight: 500)
        #expect(PairingCycler.closestStyle(to: reg, in: styles).postScriptName == "R")
        let wideItalic = style("X", name: "", weight: 700, width: 8, italic: true)
        #expect(PairingCycler.closestStyle(to: wideItalic, in: styles).postScriptName == "BIW")
        // No italic in the family: weight decides.
        let upright = Array(styles.prefix(2))
        #expect(PairingCycler.closestStyle(to: boldItalic, in: upright).postScriptName == "B")
    }
}
