import CoreText
import Foundation

/// Bounds-checked big-endian reads over one sfnt table. Every read returns nil past the end, so parsers built on
/// it never trap on truncated or malformed fonts.
public struct SfntReader: Sendable {
    public let bytes: [UInt8]

    public init(_ data: Data) { bytes = [UInt8](data) }
    public init(bytes: [UInt8]) { self.bytes = bytes }

    public var count: Int { bytes.count }

    public func u8(_ offset: Int) -> UInt8? {
        offset >= 0 && offset < bytes.count ? bytes[offset] : nil
    }

    public func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count - 2 else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    public func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    /// A four-character tag (printable ASCII; anything else makes it nil).
    public func tag(_ offset: Int) -> String? {
        guard offset >= 0, offset <= bytes.count - 4 else { return nil }
        let raw = bytes[offset..<offset + 4]
        guard raw.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    /// `length` bytes from `offset`, or nil when they do not all fit.
    public func slice(_ offset: Int, _ length: Int) -> ArraySlice<UInt8>? {
        guard offset >= 0, length >= 0, offset <= bytes.count - length else { return nil }
        return bytes[offset..<offset + length]
    }

    // MARK: Tables of a font

    /// The raw bytes of a table of `font`, or nil when it has none.
    public static func table(_ tag: String, of font: CTFont) -> SfntReader? {
        let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let data = CTFontCopyTable(font, CTFontTableTag(code), []) as Data?, !data.isEmpty else { return nil }
        return SfntReader(data)
    }
}
