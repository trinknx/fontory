import Foundation

public enum FontFormatSniffer {
    /// Identifies a font container from its first bytes. Returns nil when the file is unreadable or not a known font.
    public static func sniff(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 14), data.count >= 2 else { return nil }
        let b = [UInt8](data)

        if b.count >= 4 {
            let head = Array(b[0..<4])
            if head == [0x00, 0x01, 0x00, 0x00] || head == Array("OTTO".utf8) || head == Array("true".utf8) { return "sfnt" }
            if head == Array("ttcf".utf8) { return "ttc" }
            if head == Array("wOFF".utf8) { return "woff" }
            if head == Array("wOF2".utf8) { return "woff2" }
        }
        if b.count >= 14, Array(b[0..<14]) == Array("%!PS-AdobeFont".utf8) { return "pfa" }
        if b[0] == 0x80, b[1] == 0x01 { return "pfb" }
        return nil
    }
}
