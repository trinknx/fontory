import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

private struct FvarBytes {
    var data: [UInt8] = []
    mutating func u16(_ v: Int) { data += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    mutating func tag(_ s: String) { data += Array(s.utf8) }
    mutating func fixed(_ v: Double) {
        let raw = UInt32(bitPattern: Int32((v * 65536).rounded()))
        data += [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }
}

/// An fvar with axes wght (100…900, default 400, name ID 256) and a hidden XHGT (0…100, default 50), and two
/// instances: "Bold" (wght 700, XHGT 50, PS name ID 260) and one whose name ID is missing from the name table.
private func syntheticFvar() -> [UInt8] {
    var b = FvarBytes()
    b.u16(1); b.u16(0); b.u16(16); b.u16(2)   // version, axesArrayOffset, reserved
    b.u16(2); b.u16(20); b.u16(2); b.u16(14)  // axisCount, axisSize, instanceCount, instanceSize (4 + 8 + 2)
    b.tag("wght"); b.fixed(100); b.fixed(400); b.fixed(900); b.u16(0); b.u16(256)
    b.tag("XHGT"); b.fixed(0); b.fixed(50); b.fixed(100); b.u16(1); b.u16(999)
    b.u16(258); b.u16(0); b.fixed(700); b.fixed(50); b.u16(260)
    b.u16(300); b.u16(0); b.fixed(2000); b.fixed(-5); b.u16(0xFFFF)   // out-of-range coordinates are clamped
    return b.data
}

/// A Windows en-US name table with IDs 256 ("Weight"), 258 ("Bold") and 260 ("Demo-Bold").
private func syntheticName() -> [UInt8] {
    let strings: [(Int, String)] = [(256, "Weight"), (258, "Bold"), (260, "Demo-Bold")]
    var b = FvarBytes()
    b.u16(0); b.u16(strings.count); b.u16(6 + strings.count * 12)
    var storage: [UInt8] = []
    for (id, s) in strings {
        let utf16 = s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        b.u16(3); b.u16(1); b.u16(0x0409); b.u16(id); b.u16(utf16.count); b.u16(storage.count)
        storage += utf16
    }
    return b.data + storage
}

private func font(_ path: String) throws -> CTFont {
    try #require(FontFile.font(at: URL(fileURLWithPath: path), faceIndex: 0))
}

@Suite struct VariationInfoTests {
    @Test func parsesSyntheticFvar() {
        let info = VariationInfo.parse(fvar: SfntReader(bytes: syntheticFvar()), name: SfntReader(bytes: syntheticName()))
        #expect(info.axes.map(\.tag) == ["wght", "XHGT"])
        let wght = info.axes[0]
        #expect(wght.name == "Weight" && wght.minValue == 100 && wght.defaultValue == 400 && wght.maxValue == 900)
        #expect(!wght.isHidden && info.axes[1].isHidden)
        #expect(info.axes[1].name == "XHGT")   // name ID missing: falls back to the tag
        #expect(info.instances.count == 2)
        #expect(info.instances[0].name == "Bold" && info.instances[0].postScriptName == "Demo-Bold")
        #expect(info.instances[0].coordinates == [VariationInfo.code("wght"): 700, VariationInfo.code("XHGT"): 50])
        #expect(info.instances[1].coordinates == [VariationInfo.code("wght"): 900, VariationInfo.code("XHGT"): 0])
        #expect(info.instances[1].name == "Instance 2" && info.instances[1].postScriptName == nil)
        #expect(info.defaults == [VariationInfo.code("wght"): 400, VariationInfo.code("XHGT"): 50])
    }

    @Test func malformedFvarIsEmptyWithoutCrashing() {
        let full = syntheticFvar()
        // Every truncation, plus garbage and a bad version.
        for n in 0..<full.count {
            let info = VariationInfo.parse(fvar: SfntReader(bytes: Array(full.prefix(n))), name: nil)
            #expect(info.axes.isEmpty || info.axes.count == 2)
        }
        #expect(VariationInfo.parse(fvar: SfntReader(bytes: Array(full.prefix(40))), name: nil).axes.isEmpty)
        #expect(VariationInfo.parse(fvar: SfntReader(bytes: [UInt8](repeating: 0xFF, count: 200)), name: nil).axes.isEmpty)
        var badVersion = full; badVersion[1] = 7; badVersion[0] = 2
        #expect(VariationInfo.parse(fvar: SfntReader(bytes: badVersion), name: nil).axes.isEmpty)
        var inverted = full
        // wght default (offset 16 + 8) above its max.
        inverted.replaceSubrange(24..<28, with: [0x7F, 0, 0, 0])
        #expect(VariationInfo.parse(fvar: SfntReader(bytes: inverted), name: nil).axes.isEmpty)
        #expect(VariationInfo.parse(fvar: nil, name: nil) == .empty)
    }

    @Test func truncatedInstancesKeepTheAxes() {
        let full = syntheticFvar()
        let info = VariationInfo.parse(fvar: SfntReader(bytes: Array(full.prefix(full.count - 3))), name: nil)
        #expect(info.axes.count == 2)
        #expect(info.instances.count == 1)
    }

    @Test func systemVariableFont() throws {
        let info = VariationInfo.read(try font(TempFonts.sfns))
        #expect(info.isVariable)
        let wght = try #require(info.axes.first { $0.tag == "wght" })
        #expect(wght.minValue < wght.defaultValue || wght.defaultValue < wght.maxValue)
        #expect(!wght.isHidden)
        #expect(!info.instances.isEmpty)
        #expect(info.instances.allSatisfy { !$0.name.isEmpty && $0.coordinates.count == info.axes.count })
        #expect(info.axes.contains { $0.isHidden })   // SF's GRAD axis is hidden
    }

    @Test func staticFontIsNotVariable() throws {
        let info = VariationInfo.read(try font(TempFonts.arialBold))
        #expect(!info.isVariable)
        #expect(info.instances.isEmpty)
    }

    @Test func cssListsOnlyChangedAxes() {
        let info = VariationInfo.parse(fvar: SfntReader(bytes: syntheticFvar()), name: SfntReader(bytes: syntheticName()))
        #expect(info.css(values: info.defaults) == "font-variation-settings: normal;")
        var values = info.defaults
        values[VariationInfo.code("wght")] = 650
        #expect(info.css(values: values) == "font-variation-settings: \"wght\" 650;")
        values[VariationInfo.code("XHGT")] = 12.5
        #expect(info.css(values: values) == "font-variation-settings: \"wght\" 650, \"XHGT\" 12.5;")
        #expect(info.css(values: values, omitting: [VariationInfo.code("wght")])
                == "font-variation-settings: \"XHGT\" 12.5;")
        #expect(VariationInfo.format(0.333333) == "0.33")
        #expect(VariationInfo.format(-10) == "-10")
    }

    @Test func instanceMatching() {
        let info = VariationInfo.parse(fvar: SfntReader(bytes: syntheticFvar()), name: SfntReader(bytes: syntheticName()))
        let bold = info.instances[0]
        #expect(info.instance(matching: bold.coordinates) == bold)
        var nearly = bold.coordinates
        nearly[VariationInfo.code("wght")] = 701
        #expect(info.instance(matching: nearly) == nil)
        #expect(info.instance(matching: info.defaults) == nil)
    }

    @Test func snapping() {
        let stops: [Double] = [100, 400, 700]
        #expect(VariationInfo.snap(390, to: stops, threshold: 20) == 400)
        #expect(VariationInfo.snap(560, to: stops, threshold: 20) == 560)
        #expect(VariationInfo.snap(560, to: stops, threshold: 200) == 700)
        #expect(VariationInfo.snap(5, to: [], threshold: 100) == 5)
        let info = VariationInfo.parse(fvar: SfntReader(bytes: syntheticFvar()), name: SfntReader(bytes: syntheticName()))
        #expect(info.stops(for: info.axes[0]) == [100, 400, 700, 900])   // min, default, instances, max
    }

    @Test func renderingAppliesVariations() throws {
        let renderer = PreviewRenderer()
        let url = URL(fileURLWithPath: TempFonts.sfns)
        var request = PreviewRequest(text: "Hamburgefonstiv", pointSize: 40, foreground: CGColor(gray: 0, alpha: 1),
                                     background: CGColor(gray: 1, alpha: 1), size: CGSize(width: 600, height: 80), scale: 1)
        let wght = VariationInfo.code("wght")
        request.variations = [wght: 100]
        let light = try #require(renderer.line(fileURL: url, faceIndex: 0, request: request))
        var heavy = request
        heavy.variations = [wght: 900]
        #expect(heavy != request)
        let bold = try #require(renderer.line(fileURL: url, faceIndex: 0, request: heavy))
        let lightWidth = CTLineGetBoundsWithOptions(light, .useGlyphPathBounds).width
        let boldWidth = CTLineGetBoundsWithOptions(bold, .useGlyphPathBounds).width
        #expect(boldWidth > lightWidth + 5)
        let a = try #require(renderer.render(fileURL: url, faceIndex: 0, request: request))
        let b = try #require(renderer.render(fileURL: url, faceIndex: 0, request: heavy))
        #expect(a.dataProvider?.data as Data? != b.dataProvider?.data as Data?)
    }
}
