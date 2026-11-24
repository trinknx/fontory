import Foundation

/// Runs `/usr/bin/ditto`; shared by the backup archive and the font exporter.
enum Ditto {
    struct Failure: Error { let message: String }

    static func run(_ args: [String]) throws {
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
            throw Failure(message: String(data: msg, encoding: .utf8) ?? "ditto failed (\(p.terminationStatus))")
        }
    }
}
