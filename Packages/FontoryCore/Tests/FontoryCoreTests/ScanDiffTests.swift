import Foundation
import Testing
@testable import FontoryCore

@Suite struct ScanDiffTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func indexed(_ path: String, size: Int64 = 10, mtime: Date? = nil, fp: String? = nil, id: Int64 = 0) -> FileRecord {
        FileRecord(id: id, locationID: 1, relativePath: path, size: size, mtime: mtime ?? t0, format: "ttf", fingerprint: fp ?? "fp-\(path)")
    }

    private func found(_ path: String, size: Int64 = 10, mtime: Date? = nil) -> ScannedFile {
        ScannedFile(relativePath: path, url: URL(fileURLWithPath: "/x/\(path)"), size: size, mtime: mtime ?? t0, format: "ttf")
    }

    @Test func classifiesAddedChangedRemovedUnchanged() {
        let diff = ScanDiff.compute(
            indexed: [indexed("same.ttf"), indexed("size.ttf"), indexed("time.ttf"), indexed("gone.ttf")],
            found: [found("same.ttf"), found("size.ttf", size: 11), found("time.ttf", mtime: Date(timeIntervalSince1970: 2000)), found("new.ttf")],
            fingerprint: { "fp-\($0.relativePath)" })
        #expect(diff.unchangedCount == 1)
        #expect(Set(diff.changed.map { $0.1.relativePath }) == ["size.ttf", "time.ttf"])
        #expect(diff.added.map(\.relativePath) == ["new.ttf"])
        #expect(diff.removed.map(\.relativePath) == ["gone.ttf"])
        #expect(diff.moved.isEmpty)
    }

    @Test func detectsMoveByFingerprint() {
        let diff = ScanDiff.compute(indexed: [indexed("old/A.ttf", fp: "fp1", id: 7)], found: [found("new/A.ttf")], fingerprint: { _ in "fp1" })
        #expect(diff.moved.count == 1)
        #expect(diff.moved.first?.0.id == 7)
        #expect(diff.moved.first?.1.relativePath == "new/A.ttf")
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
    }

    @Test func movedFileWithDifferentMtimeIsStillAMove() {
        let diff = ScanDiff.compute(indexed: [indexed("a.ttf", fp: "fp1")], found: [found("b.ttf", mtime: Date(timeIntervalSince1970: 9999))], fingerprint: { _ in "fp1" })
        #expect(diff.moved.count == 1)
        #expect(diff.added.isEmpty)
    }

    @Test func eachIndexedFileIsConsumedByOneMove() {
        let diff = ScanDiff.compute(indexed: [indexed("a.ttf", fp: "fp1")], found: [found("b.ttf"), found("c.ttf")], fingerprint: { _ in "fp1" })
        #expect(diff.moved.count == 1)
        #expect(diff.added.count == 1)
        #expect(diff.removed.isEmpty)
    }

    @Test func fingerprintOnlyComputedForUnmatched() {
        var computed: [String] = []
        _ = ScanDiff.compute(
            indexed: [indexed("same.ttf"), indexed("changed.ttf"), indexed("gone.ttf")],
            found: [found("same.ttf"), found("changed.ttf", size: 99), found("n1.ttf"), found("n2.ttf")],
            fingerprint: { computed.append($0.relativePath); return "zzz" })
        #expect(computed.sorted() == ["n1.ttf", "n2.ttf"])
    }

    @Test func fingerprintSkippedWhenNothingIndexedIsUnmatched() {
        var count = 0
        let diff = ScanDiff.compute(indexed: [indexed("a.ttf")], found: [found("a.ttf"), found("b.ttf")], fingerprint: { _ in count += 1; return "x" })
        #expect(count == 0)
        #expect(diff.added.count == 1)
    }
}
