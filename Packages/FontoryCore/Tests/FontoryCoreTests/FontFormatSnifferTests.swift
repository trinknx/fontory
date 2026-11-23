import Foundation
import Testing
@testable import FontoryCore

@Suite struct FontFormatSnifferTests {
    @Test func sniffsByMagic() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        let noext = try t.copy(TempFonts.arialBold, as: "noext")
        let ttc = try t.copy(TempFonts.avenirNext)
        #expect(FontFormatSniffer.sniff(url: noext) == "sfnt")
        #expect(FontFormatSniffer.sniff(url: ttc) == "ttc")
        #expect(FontFormatSniffer.sniff(url: try t.junk()) == nil)
    }

    @Test func sniffsOtherMagics() throws {
        let t = try TempFonts(); defer { t.cleanup() }
        func sniff(_ bytes: [UInt8]) throws -> String? {
            FontFormatSniffer.sniff(url: try t.write(Data(bytes), as: UUID().uuidString))
        }
        #expect(try sniff(Array("wOFF".utf8) + [0, 0, 0, 0]) == "woff")
        #expect(try sniff(Array("wOF2".utf8) + [0, 0, 0, 0]) == "woff2")
        #expect(try sniff(Array("OTTO".utf8) + [0, 0]) == "sfnt")
        #expect(try sniff(Array("true".utf8) + [0, 0]) == "sfnt")
        #expect(try sniff(Array("%!PS-AdobeFont-1.0".utf8)) == "pfa")
        #expect(try sniff([0x80, 0x01, 0, 0, 0, 0]) == "pfb")
        #expect(try sniff([]) == nil)
    }
}
