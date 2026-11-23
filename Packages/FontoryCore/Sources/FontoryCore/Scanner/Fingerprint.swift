import CryptoKit
import Foundation

public enum Fingerprint {
    static let window = 64 * 1024

    /// "\(size)-" + hex SHA-256 of the first 64 KiB followed by the last 64 KiB.
    /// Content-based, so it survives renames and moves. Small files are covered by both windows.
    public static func compute(url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: window) { hasher.update(data: head) }

        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > UInt64(window) ? end - UInt64(window) : 0)
        if let tail = try handle.read(upToCount: window) { hasher.update(data: tail) }

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(hex)"
    }
}
