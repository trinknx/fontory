import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

/// Builds big-endian sfnt bytes for synthetic tables.
private struct Bytes {
    var data: [UInt8] = []
    mutating func u16(_ v: Int) { data += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    mutating func tag(_ s: String) { data += Array(s.utf8) }
    mutating func raw(_ b: [UInt8]) { data += b }
    var count: Int { data.count }
}

/// A GSUB with features [liga, locl, ss01 (FeatureParams → name ID 256)], scripts DFLT (default: liga) and
/// latn (default: liga, ss01; TRK: required locl, then liga).
private func syntheticGSUB(badIndex: Bool = false, badParams: Bool = false) -> [UInt8] {
    // Layout: header (10) | ScriptList | FeatureList
    var scriptList = Bytes()
    // ScriptList: count 2, records (DFLT, latn) → script tables after the 2 + 12 header.
    let dflt = 2 + 12
    let dfltSize = 4 + 6            // Script header + default LangSys (lookupOrder, required, count 1, idx)
    let latn = dflt + dfltSize + 2  // DFLT LangSys has 1 index → +2
    scriptList.u16(2)
    scriptList.tag("DFLT"); scriptList.u16(dflt)
    scriptList.tag("latn"); scriptList.u16(latn)
    // DFLT script: default LangSys at offset 4, no languages.
    scriptList.u16(4); scriptList.u16(0)
    scriptList.u16(0); scriptList.u16(0xFFFF); scriptList.u16(1); scriptList.u16(0)
    // latn script: default LangSys, 1 language (TRK).
    let latnHeader = 4 + 6
    let latnDefaultSize = 6 + 4
    scriptList.u16(latnHeader); scriptList.u16(1)
    scriptList.tag("TRK "); scriptList.u16(latnHeader + latnDefaultSize)
    scriptList.u16(0); scriptList.u16(0xFFFF); scriptList.u16(2); scriptList.u16(0); scriptList.u16(2)
    scriptList.u16(0); scriptList.u16(1); scriptList.u16(1); scriptList.u16(badIndex ? 9 : 0)

    var featureList = Bytes()
    featureList.u16(3)
    let tables = 2 + 18
    featureList.tag("liga"); featureList.u16(tables)
    featureList.tag("locl"); featureList.u16(tables + 4)
    featureList.tag("ss01"); featureList.u16(tables + 8)
    featureList.u16(0); featureList.u16(0)                 // liga: no params, no lookups
    featureList.u16(0); featureList.u16(0)                 // locl
    featureList.u16(badParams ? 0x7000 : 4); featureList.u16(0)   // ss01: params at +4 (or far past the end)
    featureList.u16(0); featureList.u16(256)               // FeatureParams: version 0, UINameID 256

    var out = Bytes()
    out.u16(1); out.u16(0)
    out.u16(10)                                            // ScriptList
    out.u16(10 + scriptList.count)                         // FeatureList
    out.u16(0)                                             // LookupList (unused)
    out.raw(scriptList.data)
    out.raw(featureList.data)
    return out.data
}

/// A name table with ID 256 as Mac Roman "Mac Name" and Windows en-US "Round Dots".
private func syntheticName() -> [UInt8] {
    let mac = Array("Mac Name".utf8)
    let win: [UInt8] = "Round Dots".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    var b = Bytes()
    b.u16(0); b.u16(2); b.u16(6 + 24)
    b.u16(1); b.u16(0); b.u16(0); b.u16(256); b.u16(mac.count); b.u16(0)
    b.u16(3); b.u16(1); b.u16(0x0409); b.u16(256); b.u16(win.count); b.u16(mac.count)
    b.raw(mac); b.raw(win)
    return b.data
}

@Suite struct SfntReaderTests {
    @Test func readsBigEndianWithinBounds() {
        let r = SfntReader(bytes: [0x12, 0x34, 0x56, 0x78, 0x6C, 0x69, 0x67, 0x61])
        #expect(r.u16(0) == 0x1234)
        #expect(r.u32(0) == 0x1234_5678)
        #expect(r.tag(4) == "liga")
        #expect(r.u16(7) == nil)
        #expect(r.u32(5) == nil)
        #expect(r.u16(-1) == nil)
        #expect(r.tag(0) == nil)                     // not printable ASCII
        #expect(r.slice(6, 3) == nil)
        #expect(r.slice(6, 2).map(Array.init) == [0x67, 0x61])
        #expect(SfntReader(bytes: []).u16(0) == nil)
    }

    @Test func readsTablesOfARealFont() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.newYork), faceIndex: 0))
        let gsub = try #require(SfntReader.table("GSUB", of: font))
        #expect(gsub.u16(0) == 1)
        #expect(SfntReader.table("zzzz", of: font) == nil)
    }
}

@Suite struct LayoutFeatureInventoryTests {
    @Test func syntheticTableByScriptAndLanguage() {
        let inv = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: syntheticGSUB()), gpos: nil,
                                               name: SfntReader(bytes: syntheticName()))
        #expect(inv.allTags == ["liga", "locl", "ss01"])
        #expect(inv.scripts == ["DFLT", "latn"])
        #expect(inv.languages(script: "latn") == ["TRK"])
        #expect(inv.tags(script: "DFLT", language: nil) == ["liga"])
        #expect(inv.tags(script: "latn", language: nil) == ["liga", "ss01"])
        #expect(inv.tags(script: "latn", language: "TRK") == ["locl", "liga"])
        // An undeclared language falls back to the script default; an undeclared script to DFLT.
        #expect(inv.tags(script: "latn", language: "DEU") == ["liga", "ss01"])
        #expect(inv.tags(script: "cyrl", language: nil) == ["liga"])
        // The stylistic set's name comes from the name table, Windows English preferred.
        #expect(inv.featureNames == ["ss01": "Round Dots"])
    }

    @Test func outOfRangeFeatureIndexEmptiesTheTable() {
        let inv = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: syntheticGSUB(badIndex: true)), gpos: nil, name: nil)
        #expect(inv.isEmpty)
        #expect(inv.allTags.isEmpty && inv.scripts.isEmpty)
    }

    @Test func malformedFeatureParamsOnlyDropTheName() {
        let inv = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: syntheticGSUB(badParams: true)), gpos: nil,
                                               name: SfntReader(bytes: syntheticName()))
        #expect(inv.allTags == ["liga", "locl", "ss01"])
        #expect(inv.featureNames.isEmpty)
    }

    @Test func truncatedAndGarbageTablesYieldEmptyInventories() throws {
        let full = syntheticGSUB()
        let paramsStart = full.count - 4   // the ss01 FeatureParams are the last 4 bytes
        for length in 0..<full.count {
            let inv = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: Array(full.prefix(length))), gpos: nil,
                                                   name: SfntReader(bytes: syntheticName()))
            if length < paramsStart {
                #expect(inv.isEmpty, "length \(length)")
            } else {
                // Only the stylistic set's params are cut: the features stay, without the name.
                #expect(inv.allTags == ["liga", "locl", "ss01"] && inv.featureNames.isEmpty, "length \(length)")
            }
        }
        // A real font's GSUB, cut short at many points: never crashes.
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.newYork), faceIndex: 0))
        let gsub = try #require(SfntReader.table("GSUB", of: font)).bytes
        for length in stride(from: 0, to: min(gsub.count, 4000), by: 7) {
            _ = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: Array(gsub.prefix(length))), gpos: nil, name: nil)
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var junk = (0..<Int.random(in: 0...512, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if junk.count >= 2, Bool.random(using: &rng) { junk[0] = 0; junk[1] = 1 }   // plausible version
            _ = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: junk), gpos: SfntReader(bytes: junk.reversed()),
                                             name: SfntReader(bytes: junk))
        }
        #expect(LayoutFeatureInventory.parse(gsub: SfntReader(bytes: [0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]),
                                             gpos: nil, name: nil).isEmpty)
    }

    /// 10,000 script records sharing one Script table whose 10,000 language records share one LangSys of 1,000
    /// indices: without caching by offset that is 10^11 index reads.
    @Test(.timeLimit(.minutes(1))) func sharedOffsetsAreParsedOnce() throws {
        let scripts = 10_000, languages = 10_000, indices = 1_000
        var b = Bytes()
        b.u16(1); b.u16(0); b.u16(22); b.u16(10); b.u16(0)         // ScriptList at 22, FeatureList at 10
        b.u16(1); b.tag("liga"); b.u16(8); b.u16(0); b.u16(0)      // FeatureList: liga
        b.u16(scripts)
        let scriptOffset = 2 + scripts * 6
        for _ in 0..<scripts { b.tag("latn"); b.u16(scriptOffset) }
        let langSysOffset = 4 + languages * 6                       // relative to the Script table
        b.u16(langSysOffset); b.u16(languages)
        for _ in 0..<languages { b.tag("TRK "); b.u16(langSysOffset) }
        b.u16(0); b.u16(0xFFFF); b.u16(indices)
        for _ in 0..<indices { b.u16(0) }
        let bytes = b.data
        let start = Date()
        let inv = LayoutFeatureInventory.parse(gsub: SfntReader(bytes: bytes), gpos: nil, name: nil)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(inv.tags(script: "latn", language: "TRK") == ["liga"])
        // The same table with a tiny work budget is refused as a whole.
        #expect(LayoutFeatureInventory.parseTable(SfntReader(bytes: bytes), budget: 5_000) == nil)
    }

    @Test func realFontFeaturesAndStylisticSetName() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.newYork), faceIndex: 0))
        let inv = LayoutFeatureInventory.read(font)
        let tags = Set(inv.allTags)
        for tag in ["smcp", "c2sc", "onum", "tnum", "kern", "ss01"] { #expect(tags.contains(tag), "\(tag)") }
        #expect(inv.featureNames["ss01"]?.isEmpty == false)
        #expect(inv.scripts.contains("latn"))
    }

    @Test func scriptFilterReturnsASubset() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.newYork), faceIndex: 0))
        let inv = LayoutFeatureInventory.read(font)
        let all = Set(inv.allTags)
        var sawSmaller = false
        for script in inv.scripts {
            for language in [nil] + inv.languages(script: script) {
                let tags = inv.tags(script: script, language: language)
                #expect(Set(tags).isSubset(of: all))
                #expect(Set(tags).count == tags.count)
                if tags.count < all.count { sawSmaller = true }
            }
        }
        #expect(sawSmaller)
    }
}

@Suite struct FontFeatureSetTests {
    @Test func openTypeFeaturesAreNamedGroupedAndSorted() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.newYork), faceIndex: 0))
        let set = FontFeatureSet.read(font)
        #expect(set.usesOpenType && set.aatFeatures.isEmpty)
        let features = set.features(for: .all)
        let smcp = try #require(features.first { $0.id == "smcp" })
        #expect(smcp.name == "Small Capitals" && smcp.group == .letterCase && !smcp.isOnByDefault)
        #expect(features.first { $0.id == "kern" }?.isOnByDefault == true)
        let ss01 = try #require(features.first { $0.id == "ss01" })
        #expect(ss01.name != "Stylistic Set 1")      // the font's own name
        #expect(ss01.group == .alternates)
        let groups = FontFeatureSet.grouped(features).map(\.group)
        #expect(groups == FeatureGroup.allCases.filter(groups.contains))
    }

    @Test func aatFontsFallBackToCoreTextFeatures() throws {
        let font = try #require(FontFile.font(at: URL(fileURLWithPath: TempFonts.hoeflerText), faceIndex: 0))
        let set = FontFeatureSet.read(font)
        #expect(!set.usesOpenType)
        let features = set.features(for: .all)
        let smallCaps = try #require(features.first { $0.tag == "smcp" })
        #expect(smallCaps.setting(on: true) == .aat(type: 3, selector: 3))
        let ligatures = try #require(features.first { $0.tag == "liga" })
        #expect(ligatures.isOnByDefault)
        #expect(FeatureToggles.settings(features, states: [ligatures.id: false]) == [.aat(type: 1, selector: 3)])
        #expect(!features.contains { $0.id.hasPrefix("aat:0:") })
    }

    @Test func catalogNamesAndGroups() {
        #expect(FeatureCatalog.entry(for: "ss07").name == "Stylistic Set 7")
        #expect(FeatureCatalog.entry(for: "cv42").group == .alternates)
        #expect(FeatureCatalog.entry(for: "frac").group == .numbers)
        #expect(FeatureCatalog.entry(for: "dlig").group == .ligatures)
        #expect(FeatureCatalog.entry(for: "cpsp").group == .positional)
        #expect(FeatureCatalog.entry(for: "init").group == .other)
        #expect(FeatureCatalog.entry(for: "zzzz").group == .other)
        #expect(FeatureCatalog.demoText(for: "frac") == "1/2 3/4 5/8 7/16")
        #expect(FeatureCatalog.demoText(for: "zzzz") == nil)
        #expect(FeatureCatalog.scriptName("latn") == "Latin")
        #expect(FeatureCatalog.scriptName("qqqq") == "qqqq")
        #expect(FeatureCatalog.languageName("TRK ") == "Turkish")
    }
}

@Suite struct FeatureTogglesTests {
    private func ot(_ tag: String) -> LayoutFeature {
        let e = FeatureCatalog.entry(for: tag)
        return LayoutFeature(id: tag, tag: tag, name: e.name, detail: tag, group: e.group,
                             isOnByDefault: FeatureCatalog.onByDefault.contains(tag), source: .openType)
    }

    @Test func cssListsOnFeaturesAndDefaultsTurnedOff() {
        let features = ["liga", "dlig", "ss01", "kern"].map(ot)
        #expect(FeatureToggles.css(features, states: [:]) == "font-feature-settings: normal;")
        let states = ["liga": false, "ss01": true, "kern": false, "dlig": false]
        #expect(FeatureToggles.css(features, states: states)
                == #"font-feature-settings: "liga" 0, "ss01" 1, "kern" 0;"#)
        #expect(FeatureToggles.settings(features, states: states)
                == [.openType(tag: "liga", value: 0), .openType(tag: "ss01", value: 1), .openType(tag: "kern", value: 0)])
    }

    @Test func toggledDropsDefaultsAndExclusiveSiblings() {
        let a = LayoutFeature(id: "aat:21:1", tag: nil, name: "A", detail: "", group: .numbers, isOnByDefault: false,
                              source: .aat(type: 21, selector: 1, exclusive: true))
        let b = LayoutFeature(id: "aat:21:2", tag: nil, name: "B", detail: "", group: .numbers, isOnByDefault: false,
                              source: .aat(type: 21, selector: 2, exclusive: true))
        var states = FeatureToggles.toggled(a, on: true, in: [a, b], states: [:])
        #expect(states == ["aat:21:1": true])
        states = FeatureToggles.toggled(b, on: true, in: [a, b], states: states)
        #expect(states == ["aat:21:2": true])
        #expect(FeatureToggles.settings([a, b], states: states) == [.aat(type: 21, selector: 2)])
        // AAT features without an OpenType equivalent stay out of the CSS.
        #expect(FeatureToggles.css([a, b], states: states) == "font-feature-settings: normal;")
        let liga = ot("liga")
        #expect(FeatureToggles.toggled(liga, on: true, in: [liga], states: ["liga": false]).isEmpty)
    }

    @Test func settingsChangeRendering() throws {
        let renderer = PreviewRenderer()
        let url = URL(fileURLWithPath: TempFonts.newYork)
        func width(_ settings: [FontFeatureSetting]) throws -> CGFloat {
            let font = try #require(renderer.font(fileURL: url, faceIndex: 0, pointSize: 40, settings: settings))
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Small Capitals", attributes: [.init(kCTFontAttributeName as String): font]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let plain = try width([])
        #expect(try width([.openType(tag: "smcp", value: 1)]) != plain)
        #expect(try width([.openType(tag: "smcp", value: 0)]) == plain)
        var request = PreviewRequest(text: "x", pointSize: 12, foreground: CGColor(gray: 0, alpha: 1),
                                     background: CGColor(gray: 1, alpha: 1), size: CGSize(width: 10, height: 10), scale: 1)
        let before = request
        request.featureSettings = [.openType(tag: "ss01", value: 1)]
        #expect(request != before)
    }

    private func lineWidth(_ request: PreviewRequest, _ path: String = TempFonts.newYork) throws -> CGFloat {
        let line = try #require(PreviewRenderer().line(fileURL: URL(fileURLWithPath: path), faceIndex: 0, request: request))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func request(_ text: String) -> PreviewRequest {
        PreviewRequest(text: text, pointSize: 100, foreground: CGColor(gray: 0, alpha: 1),
                       background: CGColor(gray: 1, alpha: 1), size: CGSize(width: 10, height: 10), scale: 1)
    }

    @Test func kerningOffChangesTheLine() throws {
        var r = request("AVAV")
        let kerned = try lineWidth(r)
        r.featureSettings = [.openType(tag: "kern", value: 0)]
        #expect(try lineWidth(r) == kerned)                 // CoreText ignores "kern" 0 …
        r.disablesKerning = FeatureToggles.disablesKerning(r.featureSettings)
        #expect(r.disablesKerning)
        #expect(try lineWidth(r) > kerned + 1)              // … the kerning attribute does not
        #expect(try lineWidth(r, TempFonts.arialBold) > lineWidth(request("AVAV"), TempFonts.arialBold) + 1)
        r.tracking = 5                                        // tracking wins over kerning off
        let tracked = try lineWidth(r)
        r.disablesKerning = false
        #expect(try lineWidth(r) == tracked)
        #expect(request("x") != { var q = request("x"); q.disablesKerning = true; return q }())
    }

    /// Documents CoreText: switching mark, mkmk or ccmp off changes neither glyphs nor positions.
    @Test func coreTextIgnoresMarkFeaturesOff() throws {
        let renderer = PreviewRenderer()
        let url = URL(fileURLWithPath: TempFonts.newYork)
        func shape(_ settings: [FontFeatureSetting]) throws -> [String] {
            let font = try #require(renderer.font(fileURL: url, faceIndex: 0, pointSize: 100, settings: settings))
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "q\u{0301}\u{0323}\u{0302}", attributes: [.init(kCTFontAttributeName as String): font]))
            return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
                var p = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(run))
                CTRunGetPositions(run, CFRange(), &p)
                return p.map { "\($0.x.rounded()),\($0.y.rounded())" }
            }
        }
        let plain = try shape([])
        for tag in FeatureCatalog.alwaysAppliedByCoreText {
            #expect(try shape([.openType(tag: tag, value: 0)]) == plain, "\(tag)")
        }
        let mark = LayoutFeature(id: "mark", tag: "mark", name: "", detail: "", group: .positional, isOnByDefault: true,
                                 source: .openType)
        #expect(!mark.previewsWhenOff)
    }

    @Test func languageSelectsLocalizedForms() throws {
        func glyphs(_ language: String?) throws -> [CGGlyph] {
            var r = request("бгдпт")
            r.language = language
            let line = try #require(PreviewRenderer().line(fileURL: URL(fileURLWithPath: TempFonts.sfns), faceIndex: 0,
                                                           request: r))
            return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run in
                var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(), &g)
                return g
            }
        }
        #expect(try glyphs(FeatureCatalog.languageCode("BGR")) != glyphs(nil))
        #expect(FeatureCatalog.languageCode("TRK ") == "tr")
    }

    @Test func hiddenChangesCountsFilteredOutSwitches() {
        let all = ["liga", "smcp", "locl"].map(ot)
        let states = ["smcp": true, "locl": false]
        #expect(FeatureToggles.hiddenChanges(all: all, listed: [all[0], all[1]], states: states) == 1)
        #expect(FeatureToggles.hiddenChanges(all: all, listed: all, states: states) == 0)
        #expect(FontFeatureSet.aatTag(type: 11, selector: 1) == "afrc")
        #expect(FontFeatureSet.aatTag(type: 11, selector: 2) == "frac")
    }

    @Test func extraSettingsOverrideThePreviewFeatures() {
        let settings = PreviewRenderer.featureSettings(.standard.subtracting(.ligatures), allCaps: false,
                                                       extra: [.openType(tag: "liga", value: 1)])
        let liga = settings.filter { $0[kCTFontOpenTypeFeatureTag as String] as? String == "liga" }
        #expect(liga.count == 1)
        #expect(liga.first?[kCTFontOpenTypeFeatureValue as String] as? Int == 1)
    }
}
