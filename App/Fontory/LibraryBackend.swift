import Foundation
import FontoryCore

enum LibraryError: LocalizedError {
    case alreadySystemLocation(String)
    case notReachable(String)
    case overlapsLocation(new: String, existing: String, inside: Bool)
    case locationOffline(String)

    var errorDescription: String? {
        switch self {
        case .overlapsLocation(let new, let existing, let inside):
            inside ? "“\(new)” is inside “\(existing)”, which is already in the library."
                   : "“\(new)” contains “\(existing)”, which is already in the library. Remove “\(existing)” first."
        case .locationOffline(let name): "“\(name)” is offline. Connect its drive first."
        case .alreadySystemLocation(let name): "“\(name)” is an installed-fonts folder and is already in the library."
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
    /// Matches the index against the fonts registered on the Mac (System / User / Activated views).
    let inventory: SystemFontInventory

    /// `/System/Library/Fonts` is indexed as `.system`; the other two hold fonts installed outside Fontory.
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
        self.inventory = SystemFontInventory(store: store)
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

    /// Adds the system and user font folders that are not in the index yet. Returns the ids of the new locations.
    func ensureSystemLocations() throws -> [Int64] {
        let existing = try store.locations()
        var added: [Int64] = []
        for url in Self.systemFontFolders where Self.directoryExists(url) {
            guard let ref = try? VolumeIdentity.ref(for: url) else { continue }
            if existing.contains(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }) { continue }
            let isSystem = url.path.hasPrefix(SystemFontInventory.systemPrefix)
            let name = isSystem ? "System Fonts" : url.path == "/Library/Fonts" ? "Computer Fonts" : "User Fonts"
            let loc = try store.upsertLocation(kind: isSystem ? .system : .userInstalled, volumeUUID: ref.volumeUUID,
                                               relativePath: ref.relativePath, displayName: name, lastKnownPath: url.path)
            added.append(loc.id)
        }
        return added
    }

    /// Whether `inner` lies strictly inside `outer` on the same volume.
    private static func contains(_ outer: LocationRecord, _ inner: VolumeRef) -> Bool {
        guard outer.volumeUUID == inner.volumeUUID, outer.relativePath != inner.relativePath else { return false }
        return outer.relativePath.isEmpty || inner.relativePath.hasPrefix(outer.relativePath + "/")
    }

    private static func contains(_ outer: VolumeRef, _ inner: LocationRecord) -> Bool {
        guard outer.volumeUUID == inner.volumeUUID, outer.relativePath != inner.relativePath else { return false }
        return outer.relativePath.isEmpty || inner.relativePath.hasPrefix(outer.relativePath + "/")
    }

    /// Adds a folder location. Refuses an installed-fonts folder and any folder inside or containing another location
    /// (its fonts would be indexed twice). Re-adding the same folder, or a file set's folder, reuses that location.
    /// Auto-indexed locations never block it: one at the same place becomes the folder, those inside it are dropped
    /// (the folder's scan indexes their files and the inventory flags the active ones again).
    func addFolder(_ url: URL) throws -> LocationRecord {
        let ref = try VolumeIdentity.ref(for: url)
        var all = try store.locations()
        for auto in all where auto.autoIndexed && Self.contains(ref, auto) { try store.deleteLocation(auto.id) }
        all = all.filter { !$0.autoIndexed }
        if let existing = all.first(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }),
           existing.kind.isReadOnly {
            throw LibraryError.alreadySystemLocation(existing.displayName)
        }
        if let outer = all.first(where: { Self.contains($0, ref) }) {
            throw LibraryError.overlapsLocation(new: url.lastPathComponent, existing: outer.displayName, inside: true)
        }
        if let inner = all.first(where: { Self.contains(ref, $0) }) {
            throw LibraryError.overlapsLocation(new: url.lastPathComponent, existing: inner.displayName, inside: false)
        }
        return try store.upsertLocation(kind: .folder, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                        displayName: url.lastPathComponent, lastKnownPath: url.standardizedFileURL.path)
    }

    enum FileTarget {
        /// A folder or system location already covers the files: rescan it.
        case covered(LocationRecord)
        case fileSet(LocationRecord)
    }

    /// Where individual files from `folder` go: the folder/system location that already contains them, else the
    /// `.fileSet` location for exactly that folder (created if needed). Never changes the kind of a user's location;
    /// an auto-indexed one at that folder becomes the file set.
    func fileTarget(for folder: URL) throws -> FileTarget {
        let ref = try VolumeIdentity.ref(for: folder)
        let all = try store.locations().filter { !$0.autoIndexed }
        let covering = all.first { loc in
            loc.kind != .fileSet && loc.volumeUUID == ref.volumeUUID
                && (loc.relativePath == ref.relativePath || Self.contains(loc, ref))
        }
        if let covering {
            guard covering.online else { throw LibraryError.locationOffline(covering.displayName) }
            return .covered(covering)
        }
        if let existing = all.first(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }) {
            return .fileSet(existing)  // necessarily a file set: folder and system kinds matched above
        }
        return .fileSet(try store.upsertLocation(kind: .fileSet, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                                 displayName: folder.lastPathComponent, lastKnownPath: folder.standardizedFileURL.path))
    }

    /// Points a location at a new folder. Its files keep their ids (and activation) when their relative paths match.
    func relink(_ id: Int64, to url: URL) throws {
        let ref = try VolumeIdentity.ref(for: url)
        try store.relinkLocation(id, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                 displayName: url.lastPathComponent, lastKnownPath: url.standardizedFileURL.path)
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
        LibraryCounts(groups: try store.faceCountGroups(), includeSystem: includeSystem)
    }
}
