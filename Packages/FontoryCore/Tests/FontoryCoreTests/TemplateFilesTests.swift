import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import FontoryCore

@Suite struct TemplateFilesTests {
    private static let expected = [
        "Poster", "Square Post", "Wordmark", "Waterfall", "Character Sheet", "Book Page", "Magazine Column",
        "Poster — Tiếng Việt", "Square Post — Tiếng Việt", "Book Page — Tiếng Việt",
    ]

    private static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../App/Fontory/Templates").standardizedFileURL
    }

    /// A system font loaded by PostScript name, as a ResolvedFont the renderer accepts.
    private static func system(_ ref: FontReference) -> ResolvedFont? {
        let font = CTFontCreateWithName(ref.postScriptName as CFString, 12, nil)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              CTFontCopyPostScriptName(font) as String == ref.postScriptName else { return nil }
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        let index = descriptors.firstIndex {
            (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == ref.postScriptName
        } ?? 0
        return ResolvedFont(reference: ref, faceID: nil, url: url, faceIndex: index, isMissing: false)
    }

    @Test func orderListsTheTenTemplates() throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("order.json"))
        let order = try JSONDecoder().decode([String].self, from: data)
        #expect(order == Self.expected.map { $0 + ".json" })
    }

    @Test func everyTemplateDecodesAndRenders() throws {
        for name in Self.expected {
            let url = Self.directory.appendingPathComponent(name + ".json")
            let doc = try JSONDecoder().decode(LayoutDocument.self, from: Data(contentsOf: url))
            #expect(doc.name == name, "\(name): name")
            #expect(!doc.blocks.isEmpty, "\(name): blocks")
            for b in doc.blocks {
                #expect(b.frame.x >= 0 && b.frame.y >= 0 && b.frame.w > 0 && b.frame.h > 0, "\(name): frame")
                #expect(b.frame.x + b.frame.w <= doc.pageSize.w && b.frame.y + b.frame.h <= doc.pageSize.h,
                        "\(name): frame inside page")
            }
            var fonts: [FontReference: ResolvedFont] = [:]
            for b in doc.blocks {
                guard let r = Self.system(b.font) else { Issue.record("\(name): system font \(b.font.postScriptName) missing"); continue }
                fonts[b.font] = r
            }
            let result = LayoutRenderer.renderImage(doc, fonts: fonts, scale: 0.25)
            #expect(result.image != nil, "\(name): image")
            #expect(result.report.missingFontBlockIDs.isEmpty, "\(name): missing fonts")
        }
    }
}
