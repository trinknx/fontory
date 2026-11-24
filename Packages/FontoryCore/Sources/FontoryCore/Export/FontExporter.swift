import Foundation

/// One font file to export. `url` is nil when its location is offline.
public struct ExportFile: Sendable, Equatable {
    public let fileID: Int64
    public let url: URL?
    public let fileName: String
    public let family: String
    public init(fileID: Int64, url: URL?, fileName: String, family: String) {
        self.fileID = fileID; self.url = url; self.fileName = fileName; self.family = family
    }
}

public struct ExportOptions: Sendable {
    public var byFamily: Bool
    public var zip: Bool
    public var archiveName: String
    public init(byFamily: Bool = false, zip: Bool = false, archiveName: String = "Fonts") {
        self.byFamily = byFamily; self.zip = zip; self.archiveName = archiveName
    }
}

public struct ExportResult: Sendable, Equatable {
    public let copied: Int
    public let skipped: Int
    public let output: URL
}

extension FontStore {
    /// Distinct files of the given faces, in the order first seen (a TTC counts once). The URL follows the app's
    /// location rule: `last_known_path` + `relative_path`, only while the location is online.
    public func exportFiles(faceIDs: [Int64]) throws -> [ExportFile] {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT files.id, locations.online, locations.last_known_path, files.relative_path, \(LibraryQuery.effectiveFamily)
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE faces.id = ?
            """)
            defer { s.reset() }
            var seen = Set<Int64>()
            var out: [ExportFile] = []
            for id in faceIDs {
                s.reset()
                try s.bind([.int(id)])
                guard try s.step() else { continue }
                let fileID = s.int64(0)
                guard seen.insert(fileID).inserted else { continue }
                let base = URL(fileURLWithPath: s.text(2))
                let rel = s.text(3)
                let url: URL? = s.int64(1) != 0 ? (rel.isEmpty ? base : base.appendingPathComponent(rel)) : nil
                let name = (rel.isEmpty ? base.lastPathComponent : (rel as NSString).lastPathComponent)
                out.append(ExportFile(fileID: fileID, url: url, fileName: name, family: s.text(4)))
            }
            return out
        }
    }
}

public enum FontExporter {
    public static func export(_ files: [ExportFile], to folder: URL, options: ExportOptions,
                              progress: @Sendable (Int, Int) -> Void,
                              isCancelled: @Sendable () -> Bool) throws -> ExportResult {
        let fm = FileManager.default
        let staging: URL? = options.zip ? fm.temporaryDirectory
            .appendingPathComponent("FontoryExport-\(UUID().uuidString)")
            .appendingPathComponent(sanitize(options.archiveName)) : nil
        let root = staging ?? folder
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if let staging { try? fm.removeItem(at: staging.deletingLastPathComponent()) } }

        var copied = 0, skipped = 0
        for (i, file) in files.enumerated() {
            if isCancelled() {
                if options.zip { throw CancellationError() }
                return ExportResult(copied: copied, skipped: skipped, output: folder)
            }
            progress(i, files.count)
            guard let src = file.url, fm.fileExists(atPath: src.path) else { skipped += 1; continue }
            var dir = root
            if options.byFamily {
                dir = root.appendingPathComponent(sanitize(file.family), isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            do {
                try fm.copyItem(at: src, to: uniqueURL(in: dir, name: file.fileName))
                copied += 1
            } catch { skipped += 1 }
        }
        progress(files.count, files.count)

        guard let staging else { return ExportResult(copied: copied, skipped: skipped, output: folder) }
        let zip = uniqueURL(in: folder, name: sanitize(options.archiveName) + ".zip")
        do { try Ditto.run(["-c", "-k", "--keepParent", staging.path, zip.path]) } catch {
            try? fm.removeItem(at: zip)
            throw NSError(domain: "FontExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: (error as? Ditto.Failure)?.message ?? "ditto failed"])
        }
        return ExportResult(copied: copied, skipped: skipped, output: zip)
    }

    static func sanitize(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (n.isEmpty || n == "." || n == "..") ? "Unknown" : n
    }

    /// `Name.otf`, then `Name 2.otf`, `Name 3.otf`; never an existing path.
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let ns = name as NSString
        let ext = ns.pathExtension, stem = ns.deletingPathExtension
        var n = 2
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}
