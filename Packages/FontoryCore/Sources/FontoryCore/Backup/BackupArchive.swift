import Foundation

/// Reads and writes the `.fontorybackup` ZIP (one `manifest.json`), using `/usr/bin/ditto`.
public enum BackupArchive {
    private static let manifestName = "manifest.json"

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Atomic: the ZIP is built beside the destination under a temporary name and then moved into place,
    /// so a failure never clobbers an existing file.
    public static func write(_ m: BackupManifest, to url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("FontoryBackup-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try makeEncoder().encode(m).write(to: work.appendingPathComponent(manifestName))

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        try ditto(["-c", "-k", work.path, tmp.path])
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    public static func read(_ url: URL) throws -> BackupManifest {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw BackupError.unreadable("File not found.") }
        let work = fm.temporaryDirectory.appendingPathComponent("FontoryBackup-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        do { try ditto(["-x", "-k", url.path, work.path]) } catch {
            throw BackupError.unreadable("The file is not a valid backup archive.")
        }
        guard let data = fm.contents(atPath: work.appendingPathComponent(manifestName).path) else {
            throw BackupError.notABackup
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["format"] as? String == BackupManifest.formatName else { throw BackupError.notABackup }
        guard let version = obj["version"] as? Int else { throw BackupError.unreadable("Missing version.") }
        guard version == BackupManifest.currentVersion else { throw BackupError.unsupportedVersion(version) }
        do { return try makeDecoder().decode(BackupManifest.self, from: data) } catch {
            throw BackupError.unreadable("The backup is damaged.")
        }
    }

    private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let msg = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw BackupError.unreadable(String(data: msg, encoding: .utf8) ?? "ditto failed (\(p.terminationStatus))")
        }
    }
}
