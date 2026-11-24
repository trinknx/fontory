import Foundation
import Testing
@testable import FontoryCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func library() throws -> (LayoutLibrary, URL) {
    let root = try tempDir()
    let l = root.appendingPathComponent("Layouts"), t = root.appendingPathComponent("Templates")
    try FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
    return (LayoutLibrary(layoutsDirectory: l, templatesDirectory: t), root)
}

private func sampleDoc() -> LayoutDocument {
    LayoutDocument(
        name: "Poster", pageSize: LayoutSize(w: 595, h: 842), background: "#FFFFFF", foreground: "#111111",
        showMissing: false,
        blocks: [
            LayoutBlock(id: UUID(), kind: .text, frame: LayoutFrame(x: 10, y: 20, w: 300, h: 100), text: "Hello",
                        font: FontReference(postScriptName: "Foo-Bold", family: "Foo", fingerprint: "abc", variations: ["wght": 700]),
                        size: 48, lineHeight: 1.1, tracking: 20, alignment: .center, color: "#FF0000", sizes: []),
            LayoutBlock(id: UUID(), kind: .waterfall, frame: LayoutFrame(x: 0, y: 0, w: 100, h: 100), text: "x",
                        font: FontReference(postScriptName: "Foo", family: "Foo"), size: 12, sizes: [12, 18, 24]),
        ],
        candidates: [FontReference(postScriptName: "Bar", family: "Bar")])
}

@Suite struct LayoutDocumentTests {
    @Test func roundTrip() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = lib.layoutsDirectory.appendingPathComponent("A.json")
        let doc = sampleDoc()
        try lib.save(doc, to: url)
        #expect(try lib.load(url) == doc)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\n"))
        #expect(text.contains("\"pageSize\""))
    }

    @Test func lenientDecoding() throws {
        let json = """
        {"version":1,"name":"X","pageSize":{"w":100,"h":200},"background":"#GG0000","foreground":"#000000",
         "mystery":[1,2],
         "blocks":[{"id":"\(UUID().uuidString)","kind":"text","frame":{"x":0,"y":0,"w":10,"h":10},"text":"t",
                    "font":{"postScriptName":"P","family":"F","extra":1},"size":20,"alignment":"left","color":"#ZZZ"}],
         "candidates":[]}
        """
        let doc = try JSONDecoder().decode(LayoutDocument.self, from: Data(json.utf8))
        #expect(doc.showMissing == true)
        #expect(doc.background == LayoutDocument.defaultBackground)
        let b = try #require(doc.blocks.first)
        #expect(b.lineHeight == 1.2)
        #expect(b.tracking == 0)
        #expect(b.color == nil)
        #expect(b.sizes.isEmpty)
    }

    @Test func hexColours() {
        #expect(LayoutColor.rgb("#FF8000")! == (1, 128.0 / 255, 0))
        #expect(LayoutColor.rgb("#GG0000") == nil)
        #expect(LayoutColor.cgColor("#000000") != nil)
    }

    @Test func notJSONListedAsUnreadable() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try lib.save(sampleDoc(), to: lib.layoutsDirectory.appendingPathComponent("Good.json"))
        try Data("not json".utf8).write(to: lib.layoutsDirectory.appendingPathComponent("Bad.json"))
        let items = lib.listLayouts()
        #expect(items.map(\.name) == ["Bad", "Good"])
        #expect(items[0].error != nil)
        #expect(items[1].error == nil)
    }

    @Test func newLayoutNamesAreUnique() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = lib.templatesDirectory.appendingPathComponent("Poster.json")
        try lib.save(sampleDoc(), to: t)
        let a = try lib.newLayout(from: t), b = try lib.newLayout(from: t), c = try lib.newLayout(from: t)
        #expect([a, b, c].map { $0.lastPathComponent } == ["Poster.json", "Poster 2.json", "Poster 3.json"])
        #expect(a.deletingLastPathComponent().standardizedFileURL == lib.layoutsDirectory.standardizedFileURL)
        let d = try lib.duplicate(a)
        #expect(d.lastPathComponent == "Poster 4.json")
        let r = try lib.rename(d, to: "Renamed")
        #expect(r.lastPathComponent == "Renamed.json")
        #expect(!FileManager.default.fileExists(atPath: d.path))
        #expect(throws: (any Error).self) { try lib.rename(r, to: "Poster") }
    }

    @Test func installNeverOverwrites() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try lib.save(sampleDoc(), to: bundle.appendingPathComponent("Poster.json"))
        try lib.installBuiltInTemplates(from: bundle)
        let installed = lib.templatesDirectory.appendingPathComponent("Poster.json")
        try Data("{\"edited\":true}".utf8).write(to: installed)
        let before = try Data(contentsOf: installed)
        try lib.installBuiltInTemplates(from: bundle)
        #expect(try Data(contentsOf: installed) == before)
    }

    @Test func builtInsListedFirst() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for n in ["Wordmark", "Poster", "Waterfall"] { try lib.save(sampleDoc(), to: bundle.appendingPathComponent("\(n).json")) }
        try Data("[\"Poster.json\",\"Wordmark.json\",\"Waterfall.json\"]".utf8).write(to: bundle.appendingPathComponent("order.json"))
        try lib.installBuiltInTemplates(from: bundle)
        try lib.save(sampleDoc(), to: lib.templatesDirectory.appendingPathComponent("Aardvark.json"))
        let items = lib.listTemplates()
        #expect(items.map(\.name) == ["Poster", "Wordmark", "Waterfall", "Aardvark"])
        #expect(items.map(\.isBuiltIn) == [true, true, true, false])
    }

    @Test func wrongTypedValuesFallBack() throws {
        let json = """
        {"name":5,"pageSize":{"w":1,"h":2},"showMissing":"yes","candidates":"nope","blocks":[
         {"kind":"text","frame":{"x":0,"y":0,"w":1,"h":1},"lineHeight":"1.2","size":"big","tracking":[],"text":7,"sizes":"x"}]}
        """
        let doc = try JSONDecoder().decode(LayoutDocument.self, from: Data(json.utf8))
        #expect(doc.showMissing && doc.candidates.isEmpty)
        let b = try #require(doc.blocks.first)
        #expect(b.lineHeight == 1.2 && b.size == 24 && b.tracking == 0 && b.text.isEmpty && b.sizes.isEmpty)
        let wholeArray = try JSONDecoder().decode(LayoutDocument.self, from: Data(#"{"pageSize":{"w":1,"h":2},"blocks":"x"}"#.utf8))
        #expect(wholeArray.blocks.isEmpty)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LayoutDocument.self, from: Data(#"{"pageSize":{"w":1,"h":2},"blocks":[{"kind":"text"}]}"#.utf8))
        }
    }

    @Test func strictHex() {
        #expect(LayoutColor.rgb("#+FFFFF") == nil)
        #expect(LayoutColor.rgb("#-FFFFF") == nil)
    }

    @Test func deletedBuiltInStaysDeletedAndNewOnesInstall() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for n in ["A", "B", "C"] { try lib.save(sampleDoc(), to: bundle.appendingPathComponent("\(n).json")) }
        try Data("[\"A.json\",\"B.json\"]".utf8).write(to: bundle.appendingPathComponent("order.json"))
        try lib.installBuiltInTemplates(from: bundle)
        #expect(lib.listTemplates().map(\.name) == ["A", "B"])
        try FileManager.default.removeItem(at: lib.templatesDirectory.appendingPathComponent("A.json"))
        try lib.installBuiltInTemplates(from: bundle)
        #expect(lib.listTemplates().map(\.name) == ["B"])
        try Data("[\"A.json\",\"B.json\",\"C.json\"]".utf8).write(to: bundle.appendingPathComponent("order.json"))
        try lib.installBuiltInTemplates(from: bundle)
        #expect(lib.listTemplates().map(\.name) == ["B", "C"])
    }
}
