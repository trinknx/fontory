import Foundation
import FontoryCore

/// Face counts shown in the sidebar and the menu bar.
struct LibraryCounts: Sendable, Equatable {
    var all = 0
    var activated = 0
    var temporary = 0
    var deactivated = 0
    var offline = 0
    var lastImport = 0
    var perLocation: [Int64: Int] = [:]
}

enum LibraryError: LocalizedError {
    case alreadySystemLocation(String)
    case notReachable(String)

    var errorDescription: String? {
        switch self {
        case .alreadySystemLocation(let name): "“\(name)” is a system font folder and is already in the library."
        case .notReachable(let name): "“\(name)” is not reachable."
        }
    }
}

/// The core services plus the few app-level database operations the core does not provide.
/// Every method may block on SQLite or the disk: call them from detached tasks, never on the main actor.
final class LibraryBackend: Sendable {
    let store: FontStore
    let scanner: LibraryScanner
    let activation: ActivationService

    static let systemFontFolders: [URL] = [
        URL(fileURLWithPath: "/System/Library/Fonts", isDirectory: true),
        URL(fileURLWithPath: "/Library/Fonts", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts", isDirectory: true),
    ]

    /// `~/Library/Application Support/Fontory/`, created on demand.
    static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Fontory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(databaseURL: URL) throws {
        let store = try FontStore(database: Database(path: databaseURL.path))
        self.store = store
        self.scanner = LibraryScanner(store: store, rootURL: { LibraryBackend.resolve($0) })
        // Scope stays `.session` (CoreTextRegistrar's default): the DB, not the system, remembers what is on.
        self.activation = ActivationService(store: store, registrar: CoreTextRegistrar())
    }

    static func resolve(_ location: LocationRecord) -> URL? {
        VolumeIdentity.resolve(VolumeRef(volumeUUID: location.volumeUUID, relativePath: location.relativePath))
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Online state

    /// Resolves every location's volume reference and records online/offline plus the current path.
    /// Returns the ids that went from offline to online.
    func refreshOnlineState() throws -> [Int64] {
        var cameOnline: [Int64] = []
        for loc in try store.locations() {
            let url = Self.resolve(loc).flatMap { Self.directoryExists($0) ? $0 : nil }
            let online = url != nil
            if online != loc.online || (url != nil && url!.path != loc.lastKnownPath) {
                try store.setLocationOnline(loc.id, online: online, lastKnownPath: url?.path)
            }
            if online && !loc.online { cameOnline.append(loc.id) }
        }
        return cameOnline
    }

    /// Marks the locations on a newly mounted volume online with their resolved path. Returns their ids.
    func markMounted(volumeUUID: String) throws -> [Int64] {
        var ids: [Int64] = []
        for loc in try store.locations() where loc.volumeUUID == volumeUUID {
            guard let url = Self.resolve(loc), Self.directoryExists(url) else { continue }
            try store.setLocationOnline(loc.id, online: true, lastKnownPath: url.path)
            if !loc.online { ids.append(loc.id) }
        }
        return ids
    }

    func markOffline(_ ids: [Int64]) throws {
        for id in ids { try store.setLocationOnline(id, online: false, lastKnownPath: nil) }
    }

    // MARK: Locations

    /// Adds the system font folders that are not in the index yet. Returns the ids of the new locations.
    func ensureSystemLocations() throws -> [Int64] {
        let existing = try store.locations()
        var added: [Int64] = []
        for url in Self.systemFontFolders where Self.directoryExists(url) {
            guard let ref = try? VolumeIdentity.ref(for: url) else { continue }
            if existing.contains(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }) { continue }
            let name = url.path.hasPrefix("/System") ? "System Fonts" : url.path == "/Library/Fonts" ? "Computer Fonts" : "User Fonts"
            let loc = try store.upsertLocation(kind: .system, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                               displayName: name, lastKnownPath: url.path)
            added.append(loc.id)
        }
        return added
    }

    func addFolder(_ url: URL) throws -> LocationRecord {
        let ref = try VolumeIdentity.ref(for: url)
        if let existing = try store.locations().first(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }),
           existing.kind == .system {
            throw LibraryError.alreadySystemLocation(existing.displayName)
        }
        return try store.upsertLocation(kind: .folder, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                        displayName: url.lastPathComponent, lastKnownPath: url.standardizedFileURL.path)
    }

    /// The folder or system location whose tree already contains `folder`, if any.
    func coveringLocation(of folder: URL) throws -> LocationRecord? {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return try store.locations().first { loc in
            guard loc.kind != .fileSet, loc.online else { return false }
            let root = URL(fileURLWithPath: loc.lastKnownPath).resolvingSymlinksInPath().standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// The `.fileSet` location for `folder`, created if needed.
    func fileSetLocation(for folder: URL) throws -> LocationRecord {
        let ref = try VolumeIdentity.ref(for: folder)
        if let existing = try store.locations().first(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }),
           existing.kind == .fileSet {
            return existing
        }
        return try store.upsertLocation(kind: .fileSet, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                        displayName: folder.lastPathComponent, lastKnownPath: folder.standardizedFileURL.path)
    }

    /// Points a location at a new folder. Its files keep their ids (and activation) when their relative paths match.
    func relink(_ id: Int64, to url: URL) throws {
        let ref = try VolumeIdentity.ref(for: url)
        let s = try store.database.prepare("""
        UPDATE locations SET volume_uuid = ?, relative_path = ?, display_name = ?, last_known_path = ?, online = 1 WHERE id = ?
        """)
        defer { s.reset() }
        try s.bind([.text(ref.volumeUUID), .text(ref.relativePath), .text(url.lastPathComponent),
                    .text(url.standardizedFileURL.path), .int(id)])
        _ = try s.step()
    }

    // MARK: File sets

    private static func scannedFile(_ url: URL, relativePath: String) -> ScannedFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let ext = url.pathExtension.lowercased()
        let format: String
        if FontFileEnumerator.extensions.contains(ext) {
            format = ext
        } else if let sniffed = FontFormatSniffer.sniff(url: url) {
            format = sniffed
        } else {
            return nil
        }
        return ScannedFile(relativePath: relativePath, url: url, size: Int64(values.fileSize ?? 0),
                           mtime: values.contentModificationDate ?? .distantPast, format: format)
    }

    /// Indexes the given files (direct children of the location's folder) into a `.fileSet` location.
    func importFiles(_ urls: [URL], into location: LocationRecord) throws -> ScanProgress {
        var progress = ScanProgress(locationID: location.id, phase: .done, total: urls.count)
        let indexed = Dictionary(try store.files(in: location.id).map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        var batch: Int64?
        for url in urls {
            progress.processed += 1
            guard let file = Self.scannedFile(url, relativePath: url.lastPathComponent),
                  let faces = try? FontParser.parse(url: url), !faces.isEmpty,
                  let fp = try? Fingerprint.compute(url: url, size: file.size) else {
                progress.failed += 1
                continue
            }
            if let record = indexed[file.relativePath] {
                guard record.size != file.size || record.mtime != file.mtime || record.fingerprint != fp else { continue }
                try store.replaceFaces(fileID: record.id, size: file.size, mtime: file.mtime, fingerprint: fp, faces: faces)
            } else {
                if batch == nil { batch = try store.nextImportBatch() }
                let record = FileRecord(locationID: location.id, relativePath: file.relativePath, size: file.size,
                                        mtime: file.mtime, format: file.format, fingerprint: fp)
                _ = try store.insertFile(record, faces: faces, importBatch: batch!)
            }
        }
        try store.markScanned(location.id, at: Date())
        return progress
    }

    /// Re-parses changed files of a `.fileSet` location. Missing files are kept (a file set has no folder listing
    /// that could prove a deletion) and reported as unreadable.
    func refreshFileSet(_ location: LocationRecord) throws -> ScanProgress {
        guard let root = Self.resolve(location), Self.directoryExists(root) else {
            return ScanProgress(locationID: location.id, phase: .aborted(reason: "location is not reachable"))
        }
        let records = try store.files(in: location.id)
        var progress = ScanProgress(locationID: location.id, phase: .done, total: records.count)
        var missing: [String] = []
        for record in records {
            progress.processed += 1
            let url = root.appendingPathComponent(record.relativePath)
            guard let file = Self.scannedFile(url, relativePath: record.relativePath) else {
                missing.append(record.relativePath)
                continue
            }
            guard file.size != record.size || file.mtime != record.mtime else { continue }
            guard let faces = try? FontParser.parse(url: url), !faces.isEmpty,
                  let fp = try? Fingerprint.compute(url: url, size: file.size) else {
                progress.failed += 1
                continue
            }
            try store.replaceFaces(fileID: record.id, size: file.size, mtime: file.mtime, fingerprint: fp, faces: faces)
        }
        progress.unreadableCount = missing.count
        progress.unreadablePaths = Array(missing.prefix(50))
        progress.skippedRemovals = missing.count
        try store.markScanned(location.id, at: Date())
        return progress
    }

    // MARK: Counts

    func counts(includeSystem: Bool) throws -> LibraryCounts {
        let s = try store.database.prepare("""
        SELECT faces.activation, locations.online, files.location_id, locations.kind,
          files.import_batch = (SELECT MAX(import_batch) FROM files), COUNT(*)
        FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
        GROUP BY 1, 2, 3, 4, 5
        """)
        defer { s.reset() }
        var c = LibraryCounts()
        while try s.step() {
            let n = Int(s.int64(5))
            let location = s.int64(2)
            c.perLocation[location, default: 0] += n
            if !includeSystem && s.int64(3) == Int64(LocationKind.system.rawValue) { continue }
            c.all += n
            switch ActivationState(rawValue: Int(s.int64(0))) ?? .off {
            case .on: c.activated += n
            case .temporary: c.temporary += n
            case .off: c.deactivated += n
            }
            if s.int64(1) == 0 { c.offline += n }
            if s.int64(4) != 0 { c.lastImport += n }
        }
        return c
    }
}
