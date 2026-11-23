import Foundation
@testable import FontoryCore

/// In-memory store with two locations and six faces across two families:
/// "Alpha" (Regular, Italic, Bold) in loc A; "Beta" (Light, Regular, Black) in loc B.
struct Fixture {
    let store: FontStore
    let locA: LocationRecord
    let locB: LocationRecord
    var faceIDs: [String: Int64] = [:]  // postscript name -> id
    var fileIDs: [String: Int64] = [:]  // relative path -> id

    static func face(_ ps: String, family: String, style: String, weight: Double, italic: Bool = false, index: Int = 0) -> ParsedFace {
        ParsedFace(faceIndex: index, postScriptName: ps, family: family, style: style, fullName: "\(family) \(style)",
                   weight: weight, isItalic: italic, glyphCount: 100)
    }

    static func make() throws -> Fixture {
        let store = try FontStore(database: Database(path: ":memory:"))
        let a = try store.upsertLocation(kind: .folder, volumeUUID: "VOL-A", relativePath: "Fonts", displayName: "A", lastKnownPath: "/Volumes/A/Fonts")
        let b = try store.upsertLocation(kind: .folder, volumeUUID: "VOL-B", relativePath: "Type", displayName: "B", lastKnownPath: "/Volumes/B/Type")
        var f = Fixture(store: store, locA: a, locB: b)
        let batch1 = try store.nextImportBatch()
        let defs: [(Int64, String, [ParsedFace])] = [
            (a.id, "Alpha-Regular.otf", [face("Alpha-Regular", family: "Alpha", style: "Regular", weight: 400)]),
            (a.id, "Alpha-Italic.otf", [face("Alpha-Italic", family: "Alpha", style: "Italic", weight: 400, italic: true)]),
            (a.id, "Alpha-Bold.otf", [face("Alpha-Bold", family: "Alpha", style: "Bold", weight: 700)]),
        ]
        for (loc, path, faces) in defs { try f.add(loc, path, faces, batch1) }
        let batch2 = try store.nextImportBatch()
        let defs2: [(Int64, String, [ParsedFace])] = [
            (b.id, "Beta-Light.otf", [face("Beta-Light", family: "Beta", style: "Light", weight: 300)]),
            (b.id, "Beta-Regular.otf", [face("Beta-Regular", family: "Beta", style: "Regular", weight: 400)]),
            (b.id, "Beta-Black.otf", [face("Beta-Black", family: "Beta", style: "Black", weight: 900)]),
        ]
        for (loc, path, faces) in defs2 { try f.add(loc, path, faces, batch2) }
        return f
    }

    mutating func add(_ loc: Int64, _ path: String, _ faces: [ParsedFace], _ batch: Int64) throws {
        let file = FileRecord(locationID: loc, relativePath: path, size: 10, mtime: Date(timeIntervalSince1970: 1000), format: "otf", fingerprint: "fp-\(path)")
        let id = try store.insertFile(file, faces: faces, importBatch: batch)
        fileIDs[path] = id
        let rows = try store.rows(ids: try store.faceIDs(for: LibraryQuery()))
        for r in rows.values { faceIDs[r.postScriptName] = r.id }
    }
}
