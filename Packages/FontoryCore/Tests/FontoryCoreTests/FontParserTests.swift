import Foundation
import Testing
@testable import FontoryCore

@Suite struct FontParserTests {
    @Test func parsesSingleTTF() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let faces = try FontParser.parse(url: try t.copy(TempFonts.arialBold))
        #expect(faces.count == 1)
        let f = try #require(faces.first)
        #expect(f.family == "Arial")
        #expect(f.weight >= 600)
        #expect(f.scriptsBitmask & (1 << 0) != 0)
        #expect(f.scriptsBitmask & (1 << 1) != 0)
    }

    @Test func parsesAllFacesInTTC() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let faces = try FontParser.parse(url: try t.copy(TempFonts.avenirNext))
        #expect(faces.count > 1)
        #expect(faces.map(\.faceIndex) == Array(0..<faces.count))
        #expect(faces.allSatisfy { $0.family == "Avenir Next" })
    }

    @Test func detectsVariable() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let faces = try FontParser.parse(url: try t.copy(TempFonts.sfns))
        let f = try #require(faces.first)
        #expect(f.isVariable)
        #expect(f.axesJSON?.contains("\"wght\"") == true)
    }

    @Test func extractsMetricsAndTables() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let f = try #require(try FontParser.parse(url: try t.copy(TempFonts.arialBold)).first)
        #expect(f.outlineType == .truetype)
        #expect(f.metrics.unitsPerEm == 2048)
        #expect(f.metrics.xHeight > 0)
        #expect(f.metrics.capHeight > f.metrics.xHeight)
        #expect(f.hasGPOS)
        #expect(!f.isColor)
        #expect(!f.isBitmap)
        #expect(f.fsType != nil)
        #expect(f.glyphCount > 0)
        #expect(!f.postScriptName.isEmpty)
    }

    @Test func detectsColorFont() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let faces = try FontParser.parse(url: try t.copy(TempFonts.emoji))
        #expect(faces.contains { $0.isColor })
    }

    @Test func junkThrowsUnreadable() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let junk = try t.junk()
        let empty = try t.write(Data(), as: "empty.otf")
        for url in [junk, empty] {
            #expect(throws: FontParserError.unreadable) { try FontParser.parse(url: url) }
        }
    }

    @Test func concurrentParsingIsSafe() async throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let url = try t.copy(TempFonts.arialBold)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { try FontParser.parse(url: url).count } }
            var out: [Int] = []
            for try await c in group { out.append(c) }
            return out
        }
        #expect(counts == Array(repeating: 1, count: 8))
    }
}
