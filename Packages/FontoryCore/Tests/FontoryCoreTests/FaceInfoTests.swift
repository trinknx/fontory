import Foundation
import Testing
@testable import FontoryCore

@Suite struct FaceInfoTests {
    @Test func faceInfoReadsEveryColumn() throws {
        var f = try Fixture.make()
        let axes = #"[{"default":400,"max":900,"min":100,"name":"Weight","tag":"wght"},{"max":1,"min":0,"tag":"ital"}]"#
        let face = ParsedFace(
            faceIndex: 2, postScriptName: "Gamma-VF", family: "Gamma", style: "Variable", fullName: "Gamma Variable",
            weight: 400, width: 5, slant: -12, isItalic: true, isVariable: true, axesJSON: axes,
            vendor: "GAMA", designer: "Ann Designer", version: "Version 2.001", glyphCount: 812, scriptsBitmask: 1,
            metrics: FaceMetrics(unitsPerEm: 2048, ascender: 1900, descender: -500, capHeight: 1400, xHeight: 1000),
            fsType: 0x0104, outlineType: .cff2, isColor: true, isBitmap: false, hasGSUB: true, hasGPOS: false)
        try f.add(f.locA.id, "Sub/Gamma.ttc", [face], 7)
        let id = try #require(f.faceIDs["Gamma-VF"])
        try f.store.setActivation(faceIDs: [id], state: .on, at: Date(timeIntervalSince1970: 5000))
        try f.store.database.execute("UPDATE faces SET note = 'Licensed for web' WHERE id = \(id)")

        let info = try #require(try f.store.faceInfo(id: id))
        #expect(info.id == id && info.faceIndex == 2)
        #expect(info.postScriptName == "Gamma-VF" && info.fullName == "Gamma Variable")
        #expect(info.family == "Gamma" && info.fontFamily == "Gamma" && info.style == "Variable")
        #expect(info.version == "Version 2.001" && info.vendor == "GAMA" && info.designer == "Ann Designer")
        #expect(info.format == "otf")
        #expect(info.fileURL.path == "/Volumes/A/Fonts/Sub/Gamma.ttc" && info.online)
        #expect(info.fileSize == 10 && info.addedAt != nil)
        #expect(info.glyphCount == 812 && info.metrics.unitsPerEm == 2048 && info.metrics.descender == -500)
        #expect(info.slant == -12 && info.isItalic)
        #expect(info.fsType == 0x0104 && info.embedding?.usage == .previewAndPrint && info.embedding?.noSubsetting == true)
        #expect(info.outlineType == .cff2 && info.isColor && !info.isBitmap && info.isVariable)
        #expect(info.axes == [VariationAxis(tag: "wght", name: "Weight", min: 100, max: 900, defaultValue: 400),
                              VariationAxis(tag: "ital", name: nil, min: 0, max: 1, defaultValue: 0)])
        #expect(info.hasGSUB && !info.hasGPOS)
        #expect(info.note == "Licensed for web")
        #expect(info.activation == .on && info.lastActivated == Date(timeIntervalSince1970: 5000))
        #expect(info.locationKind == .folder)
    }

    @Test func faceInfoOptionalColumnsAndMissingFace() throws {
        let f = try Fixture.make()
        let info = try #require(try f.store.faceInfo(id: f.faceIDs["Alpha-Bold"]!))
        #expect(info.version == nil && info.vendor == nil && info.designer == nil && info.note == nil)
        #expect(info.fsType == nil && info.embedding == nil && info.axes.isEmpty && info.lastActivated == nil)
        #expect(try f.store.faceInfo(id: 999_999) == nil)
    }

    @Test func faceInfoOfOfflineLocationKeepsThePath() throws {
        let f = try Fixture.make()
        try f.store.setLocationOnline(f.locB.id, online: false, lastKnownPath: nil)
        let info = try #require(try f.store.faceInfo(id: f.faceIDs["Beta-Black"]!))
        #expect(!info.online && info.fileURL.path == "/Volumes/B/Type/Beta-Black.otf")
    }

    @Test func familyInFamilyOrderWithRepresentative() throws {
        var f = try Fixture.make()
        let ids = f.faceIDs
        let alpha = try #require(try f.store.family(named: "Alpha", includeSystem: true))
        #expect(alpha.id == "alpha" && alpha.name == "Alpha")
        #expect(alpha.faceIDs == [ids["Alpha-Regular"]!, ids["Alpha-Italic"]!, ids["Alpha-Bold"]!])
        #expect(alpha.representativeID == ids["Alpha-Regular"]!)
        let beta = try #require(try f.store.family(named: "BETA", includeSystem: true))
        #expect(beta.name == "Beta" && beta.faceIDs == [ids["Beta-Light"]!, ids["Beta-Regular"]!, ids["Beta-Black"]!])
        #expect(try f.store.family(named: "Nope", includeSystem: true) == nil)

        // The representative preference is honoured, like in the list.
        try f.store.setRepresentative(familyKey: "beta", faceID: ids["Beta-Black"]!)
        #expect(try f.store.family(named: "Beta", includeSystem: true)?.representativeID == ids["Beta-Black"]!)
        #expect(try f.store.families(for: LibraryQuery()).first { $0.id == "beta" }?.representativeID == ids["Beta-Black"]!)

        let sys = try f.store.upsertLocation(kind: .system, volumeUUID: "SYS", relativePath: "", displayName: "System", lastKnownPath: "/System/Library/Fonts")
        try f.add(sys.id, "AlphaSys.ttf", [Fixture.face("Alpha-Thin", family: "Alpha", style: "Thin", weight: 100),
                                         Fixture.face(".Alpha-Private", family: "Alpha", style: "Hidden", weight: 50, index: 1)], 9)
        let withSystem = try #require(try f.store.family(named: "alpha", includeSystem: true))
        #expect(withSystem.faceIDs == [f.faceIDs["Alpha-Thin"]!, ids["Alpha-Regular"]!, ids["Alpha-Italic"]!, ids["Alpha-Bold"]!])
        #expect(withSystem.representativeID == ids["Alpha-Regular"]!)
        #expect(try f.store.family(named: "Alpha", includeSystem: false)?.faceIDs.count == 3)
    }

    @Test func familyFollowsCustomFamily() throws {
        let f = try Fixture.make()
        let bold = f.faceIDs["Alpha-Bold"]!
        try f.store.database.execute("UPDATE faces SET custom_family = 'Alpha Display' WHERE id = \(bold)")
        #expect(try f.store.family(named: "Alpha Display", includeSystem: true)?.faceIDs == [bold])
        #expect(!(try f.store.family(named: "Alpha", includeSystem: true)?.faceIDs ?? []).contains(bold))
        #expect(try f.store.faceInfo(id: bold)?.family == "Alpha Display")
        #expect(try f.store.faceInfo(id: bold)?.fontFamily == "Alpha")
    }

    // MARK: fsType

    @Test func embeddingUsageBits() {
        #expect(EmbeddingPermissions(fsType: 0).usage == .installable)
        #expect(EmbeddingPermissions(fsType: 0x0002).usage == .restricted)
        #expect(EmbeddingPermissions(fsType: 0x0004).usage == .previewAndPrint)
        #expect(EmbeddingPermissions(fsType: 0x0008).usage == .editable)
        // Several usage bits (older fonts): the least restrictive applies.
        #expect(EmbeddingPermissions(fsType: 0x000E).usage == .editable)
        #expect(EmbeddingPermissions(fsType: 0x0006).usage == .previewAndPrint)
        // Bit 0 is reserved.
        #expect(EmbeddingPermissions(fsType: 0x0001).usage == .installable)
    }

    @Test func embeddingFlagsAndText() {
        let plain = EmbeddingPermissions(fsType: 0x0008)
        #expect(!plain.noSubsetting && !plain.bitmapOnly)
        #expect(plain.summary == "Editable" && plain.hex == "0x0008")

        let both = EmbeddingPermissions(fsType: 0x0302)
        #expect(both.usage == .restricted && both.noSubsetting && both.bitmapOnly)
        #expect(both.summary == "Restricted License · No subsetting · Bitmap embedding only")
        #expect(both.hex == "0x0302")

        let noSubset = EmbeddingPermissions(fsType: 0x0100)
        #expect(noSubset.usage == .installable && noSubset.noSubsetting && !noSubset.bitmapOnly)
        #expect(EmbeddingPermissions(fsType: 0).summary == "Installable")
    }

    @Test func axesDecodeTolerantly() {
        #expect(VariationAxis.decode(json: nil).isEmpty)
        #expect(VariationAxis.decode(json: "not json").isEmpty)
        let axes = VariationAxis.decode(json: #"[{"tag":"wdth","min":75,"max":125}]"#)
        #expect(axes == [VariationAxis(tag: "wdth", name: nil, min: 75, max: 125, defaultValue: 75)])
    }
}
