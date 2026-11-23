import Foundation
import Testing
@testable import FontoryCore

@Suite struct FingerprintTests {
    private func size(_ url: URL) throws -> Int64 {
        Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber)
    }

    @Test func stableAcrossRename() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let a = try t.copy(TempFonts.arialBold, as: "one/A.ttf")
        let b = try t.copy(TempFonts.arialBold, as: "two/Renamed.ttf")
        let s = try size(a)
        let fa = try Fingerprint.compute(url: a, size: s)
        #expect(fa == (try Fingerprint.compute(url: b, size: s)))
        #expect(fa.hasPrefix("\(s)-"))
        #expect(fa.count == "\(s)-".count + 64)
    }

    @Test func changesWhenHeadOrTailChanges() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let a = try t.copy(TempFonts.arialBold, as: "a.ttf")
        let s = try size(a)
        let base = try Fingerprint.compute(url: a, size: s)

        var data = try Data(contentsOf: a)
        data[100] ^= 0xFF
        let head = try t.write(data, as: "head.ttf")
        #expect(try Fingerprint.compute(url: head, size: s) != base)

        data = try Data(contentsOf: a)
        data[data.count - 10] ^= 0xFF
        let tail = try t.write(data, as: "tail.ttf")
        #expect(try Fingerprint.compute(url: tail, size: s) != base)
    }

    @Test func smallFileAndMissingFile() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let small = try t.write(Data([1, 2, 3]), as: "s.ttf")
        #expect(try Fingerprint.compute(url: small, size: 3).hasPrefix("3-"))
        #expect(throws: (any Error).self) { try Fingerprint.compute(url: t.root.appendingPathComponent("nope"), size: 0) }
    }
}
