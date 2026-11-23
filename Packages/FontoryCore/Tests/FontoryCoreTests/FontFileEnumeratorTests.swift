import Foundation
import Testing
@testable import FontoryCore

@Suite struct FontFileEnumeratorTests {
    private func collect(_ root: URL) async throws -> [ScannedFile] {
        var out: [ScannedFile] = []
        for try await f in FontFileEnumerator.enumerate(root: root) { out.append(f) }
        return out
    }

    @Test func findsNestedSkipsHidden() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "a/b/Arial Bold.ttf")
        try t.copy(TempFonts.arialBold, as: ".hidden/x.ttf")
        try t.write(Data("hi".utf8), as: "notes.txt")
        let files = try await collect(t.root)
        #expect(files.count == 1)
        let f = try #require(files.first)
        #expect(f.relativePath == "a/b/Arial Bold.ttf")
        #expect(f.format == "ttf")
        #expect(f.size > 0)
    }

    @Test func includesSniffedExtensionlessOnly() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "noext")
        try t.copy(TempFonts.avenirNext, as: "sub/ttcnoext")
        try t.write(Data(repeating: 7, count: 50), as: "junknoext")
        let files = try await collect(t.root)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0.format) })
        #expect(byPath == ["noext": "sfnt", "sub/ttcnoext": "ttc"])
    }

    @Test func extensionMatchIsCaseInsensitiveAndFollowsNoSymlinks() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let real = try t.copy(TempFonts.arialBold, as: "real/Upper.TTF")
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("link.ttf"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("linkdir"), withDestinationURL: t.root.appendingPathComponent("real"))
        let files = try await collect(t.root)
        #expect(files.map(\.relativePath) == ["real/Upper.TTF"])
        #expect(files.first?.format == "ttf")
    }

    @Test func nonexistentRootThrows() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: (any Error).self) { _ = try await collect(missing) }
    }

    @Test func rootThatIsAFileThrows() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let file = try t.copy(TempFonts.arialBold)
        await #expect(throws: (any Error).self) { _ = try await collect(file) }
    }

    @Test func emptyRootFinishesWithoutError() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        #expect(try await collect(t.root).isEmpty)
    }

    @Test func unreadableSubfolderIsReportedNotFatal() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        try t.copy(TempFonts.arialBold, as: "ok/Arial Bold.ttf")
        try t.copy(TempFonts.arialBold, as: "locked/Arial Bold.ttf")
        let locked = t.root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let report = EnumerationReport()
        var out: [ScannedFile] = []
        for try await f in FontFileEnumerator.enumerate(root: t.root, report: report) { out.append(f) }
        #expect(out.map(\.relativePath) == ["ok/Arial Bold.ttf"])
        #expect(report.paths == ["locked"])
        #expect(report.count == 1)
    }
}
