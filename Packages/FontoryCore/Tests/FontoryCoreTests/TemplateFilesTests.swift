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

    /// Templates whose blocks overlap on purpose (none today). Add the name here, with a reason, to exempt one.
    private static let intentionalOverlaps: Set<String> = []

    private static func load(_ name: String) throws -> LayoutDocument {
        try JSONDecoder().decode(LayoutDocument.self,
                                 from: Data(contentsOf: directory.appendingPathComponent(name + ".json")))
    }

    private static func rect(_ f: LayoutFrame) -> CGRect { CGRect(x: f.x, y: f.y, width: f.w, height: f.h) }

    private static func render(_ doc: LayoutDocument) -> LayoutRenderReport {
        var fonts: [FontReference: ResolvedFont] = [:]
        for b in doc.blocks { fonts[b.font] = system(b.font) }
        return LayoutRenderer.renderImage(doc, fonts: fonts, scale: 0.25).report
    }

    @Test func noTwoBlocksOverlap() throws {
        for name in Self.expected where !Self.intentionalOverlaps.contains(name) {
            let blocks = try Self.load(name).blocks
            for i in blocks.indices {
                for j in blocks.indices where j > i {
                    let a = Self.rect(blocks[i].frame), b = Self.rect(blocks[j].frame)
                    #expect(!a.intersects(b), "\(name): blocks \(i) and \(j) overlap (\(a) / \(b))")
                }
            }
        }
    }

    /// Each text block's lines fit in its frame (nothing clipped at the bottom).
    @Test func textFitsItsFrame() throws {
        for name in Self.expected {
            let doc = try Self.load(name)
            let report = Self.render(doc)
            for b in doc.blocks where b.kind == .text {
                let lines = report.lineCounts[b.id.uuidString] ?? 0
                let needed = Double(lines) * max(1, b.size * b.lineHeight)
                #expect(lines > 0 && needed <= b.frame.h + 0.5, "\(name): \(lines) lines need \(needed) pt, frame \(b.frame.h)")
            }
        }
    }

    /// The poster headlines break only where the text does: no word left alone on a line.
    @Test func posterHeadlinesKeepTheirTwoLines() throws {
        for name in ["Poster", "Poster — Tiếng Việt"] {
            let doc = try Self.load(name)
            let headline = try #require(doc.blocks.first)
            #expect(Self.render(doc).lineCounts[headline.id.uuidString] == 2, "\(name): headline lines")
        }
    }

    /// The character sheet's grid frame ends with its last row (no blank band before the pangram).
    @Test func characterSheetFrameFitsItsGrid() throws {
        let doc = try Self.load("Character Sheet")
        let grid = try #require(doc.blocks.first { $0.kind == .charset })
        let count = grid.text.filter { !$0.isWhitespace }.count
        let columns = LayoutRenderer.charsetColumns(width: grid.frame.w, size: grid.size)
        let rows = (count + columns - 1) / columns
        let cell = grid.size * 1.6
        let content = Double(rows) * cell
        #expect(content <= grid.frame.h && grid.frame.h - content < cell, "rows \(rows), content \(content), frame \(grid.frame.h)")
        #expect(Self.render(doc).lineCounts[grid.id.uuidString] == rows)
    }
}
