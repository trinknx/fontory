import Foundation

/// Per-test temp directory with helpers to copy system fonts into it. Removed on `cleanup()`.
struct TempFonts {
    static let arialBold = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
    static let avenirNext = "/System/Library/Fonts/Avenir Next.ttc"
    static let sfns = "/System/Library/Fonts/SFNS.ttf"
    static let emoji = "/System/Library/Fonts/Apple Color Emoji.ttc"

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func copy(_ systemPath: String, as relative: String? = nil) throws -> URL {
        let src = URL(fileURLWithPath: systemPath)
        let dest = root.appendingPathComponent(relative ?? src.lastPathComponent)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    @discardableResult
    func write(_ data: Data, as relative: String) throws -> URL {
        let dest = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
        return dest
    }

    func junk(_ relative: String = "junk.ttf") throws -> URL {
        try write(Data((0..<100).map { _ in UInt8.random(in: 0...255) }), as: relative)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
