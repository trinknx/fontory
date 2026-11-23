import CoreText
import Foundation
import os

/// What one inventory pass changed.
public struct InventoryResult: Sendable, Equatable {
    /// Files whose "registered by someone else" flag was set or cleared.
    public var flagsChanged = 0
    /// Files indexed because they are active outside every location (or in a file set that did not list them).
    public var indexedFiles = 0
    /// Auto-indexed files forgotten because they are no longer active.
    public var removedFiles = 0
    /// Registered files that could not be read.
    public var failedFiles = 0
    /// Auto-indexed locations were created or deleted.
    public var locationsChanged = false
    /// Scanned locations (folder, system, user-installed) that contain registered files they have not indexed yet:
    /// their next scan picks them up. `pendingPaths` lists those files.
    public var pendingLocationIDs: Set<Int64> = []
    public var pendingPaths: Set<String> = []

    public init() {}

    public var changed: Bool { flagsChanged > 0 || indexedFiles > 0 || removedFiles > 0 || locationsChanged }
}

/// Keeps the index in step with what is really active on the Mac (`CTFontManagerCopyAvailableFontURLs`).
///
/// - An indexed file that is registered while none of its faces is on in Fontory is flagged `external_active`
///   (someone else activated it). Fontory's own registrations are never external.
/// - A registered file outside every location is indexed into an auto-indexed, read-only location for its folder:
///   kind `.system` under /System, `.userInstalled` elsewhere. Such files are forgotten once they are inactive.
/// - A registered file inside a scanned location that has not indexed it yet is left to that location's scan.
///
/// All database changes of one pass are applied in one transaction. Paths are matched in both their standardized
/// and their symlink-resolved spelling, like `CoreTextRegistrar` matches registration errors.
public actor SystemFontInventory {
    public struct FileContents: Sendable {
        public var size: Int64
        public var mtime: Date
        public var format: String
        public var fingerprint: String
        public var faces: [ParsedFace]

        public init(size: Int64, mtime: Date, format: String, fingerprint: String, faces: [ParsedFace]) {
            self.size = size
            self.mtime = mtime
            self.format = format
            self.fingerprint = fingerprint
            self.faces = faces
        }
    }

    private static let log = Logger(subsystem: "local.fontory.core", category: "inventory")
    public static let systemPrefix = "/System/"

    private let store: FontStore
    private let readFile: @Sendable (URL) -> FileContents?
    private let volumeRef: @Sendable (URL) -> VolumeRef?
    private let resolvePath: @Sendable (String) -> String

    public init(
        store: FontStore,
        readFile: @escaping @Sendable (URL) -> FileContents? = SystemFontInventory.readFromDisk,
        volumeRef: @escaping @Sendable (URL) -> VolumeRef? = { try? VolumeIdentity.ref(for: $0) },
        resolvePath: @escaping @Sendable (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    ) {
        self.store = store
        self.readFile = readFile
        self.volumeRef = volumeRef
        self.resolvePath = resolvePath
    }

    /// The fonts registered on the Mac right now, one URL per face (CoreText adds a `#postscript-name=` fragment).
    public static func availableFontURLs() -> [URL] {
        (CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? []
    }

    /// Reads the registered fonts from CoreText and reconciles the index with them.
    public func refresh() throws -> InventoryResult {
        try reconcile(available: Self.availableFontURLs())
    }

    public static func readFromDisk(_ url: URL) -> FileContents? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let size = Int64(values.fileSize ?? 0)
        let ext = url.pathExtension.lowercased()
        let format = FontFileEnumerator.extensions.contains(ext) ? ext : FontFormatSniffer.sniff(url: url) ?? (ext.isEmpty ? "font" : ext)
        guard let faces = try? FontParser.parse(url: url), !faces.isEmpty,
              let fingerprint = try? Fingerprint.compute(url: url, size: size) else { return nil }
        return FileContents(size: size, mtime: values.contentModificationDate ?? .distantPast, format: format,
                            fingerprint: fingerprint, faces: faces)
    }

    private static func join(_ root: String, _ relative: String) -> String {
        if relative.isEmpty { return root }
        return root == "/" ? "/" + relative : root + "/" + relative
    }

    private static func isUnder(_ path: String, _ root: String) -> Bool {
        root == "/" ? path.hasPrefix("/") && path != "/" : path.hasPrefix(root + "/")
    }

    private static func isSystemPath(_ path: String) -> Bool {
        path == "/System" || path.hasPrefix(systemPrefix)
    }

    private enum Target: Hashable {
        case location(Int64)
        case newAutoLocation(folder: String)
    }

    private struct NewFile {
        var target: Target
        var path: String
        var relativePath: String
    }

    public func reconcile(available: [URL]) throws -> InventoryResult {
        var result = InventoryResult()

        // 1. Registered files, keyed by every spelling of their path, deduplicated (one URL per face).
        var canonicalByKey: [String: String] = [:]
        var registered: [String] = []
        var seen = Set<String>()
        for url in available where url.isFileURL {
            let std = url.standardizedFileURL.path
            guard !std.isEmpty, canonicalByKey[std] == nil else { continue }
            let canonical = resolvePath(std)
            canonicalByKey[std] = canonical
            canonicalByKey[canonical] = canonical
            if seen.insert(canonical).inserted { registered.append(canonical) }
        }

        // 2. Location roots in both spellings.
        let locations = try store.locations()
        var roots: [Int64: [String]] = [:]
        for loc in locations {
            let std = URL(fileURLWithPath: loc.lastKnownPath).standardizedFileURL.path
            let resolved = resolvePath(std)
            roots[loc.id] = resolved == std ? [std] : [std, resolved]
        }
        let byID = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 3. Indexed files: registered or not, and whose registration it is.
        var matched = Set<String>()
        var flagOn: [Int64] = []
        var flagOff: [Int64] = []
        var forget: [Int64] = []
        for file in try store.inventoryFiles() {
            guard let loc = byID[file.locationID] else { continue }
            var canonical: String?
            if loc.online {
                for root in roots[loc.id] ?? [] {
                    if let c = canonicalByKey[Self.join(root, file.relativePath)] { canonical = c; break }
                }
            }
            if let canonical { matched.insert(canonical) }
            let external = canonical != nil && !file.fontoryActive
            if external != file.externalActive { if external { flagOn.append(file.fileID) } else { flagOff.append(file.fileID) } }
            if loc.autoIndexed && canonical == nil { forget.append(file.fileID) }
        }
        result.flagsChanged = flagOn.count + flagOff.count
        result.removedFiles = forget.count

        // 4. Registered files the index does not have.
        let fixed = locations.filter { !$0.autoIndexed }
        var autoByFolder: [String: Int64] = [:]
        for loc in locations where loc.autoIndexed && loc.online {
            for root in roots[loc.id] ?? [] { autoByFolder[root] = loc.id }
        }
        var newFiles: [NewFile] = []
        for path in registered where !matched.contains(path) {
            var covering: (loc: LocationRecord, root: String)?
            for loc in fixed {
                for root in roots[loc.id] ?? [] where Self.isUnder(path, root) {
                    if covering == nil || root.count > covering!.root.count { covering = (loc, root) }
                }
            }
            if let covering {
                // An offline location's old path cannot hold a registered file; nothing to do.
                guard covering.loc.online else { continue }
                if covering.loc.kind == .fileSet {
                    let rel = covering.root == "/" ? String(path.dropFirst()) : String(path.dropFirst(covering.root.count + 1))
                    newFiles.append(NewFile(target: .location(covering.loc.id), path: path, relativePath: rel))
                } else {
                    result.pendingLocationIDs.insert(covering.loc.id)
                    result.pendingPaths.insert(path)
                }
                continue
            }
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let target: Target = autoByFolder[folder].map { .location($0) } ?? .newAutoLocation(folder: folder)
            newFiles.append(NewFile(target: target, path: path, relativePath: name))
        }

        // 5. Volume references for new auto-indexed locations. A folder that is already a location of the user's
        // (seen under another path) is left alone rather than turned into an auto-indexed one.
        var refs: [String: VolumeRef] = [:]
        for case .newAutoLocation(let folder) in Set(newFiles.map(\.target)) {
            guard let ref = volumeRef(URL(fileURLWithPath: folder, isDirectory: true)) else {
                Self.log.error("no volume reference for \(folder, privacy: .public); its active fonts are not indexed")
                continue
            }
            if fixed.contains(where: { $0.volumeUUID == ref.volumeUUID && $0.relativePath == ref.relativePath }) { continue }
            refs[folder] = ref
        }

        // 6. Read the new files, outside any transaction.
        var reads: [(file: NewFile, contents: FileContents)] = []
        for file in newFiles {
            if case .newAutoLocation(let folder) = file.target, refs[folder] == nil { continue }
            guard let contents = readFile(URL(fileURLWithPath: file.path)) else {
                result.failedFiles += 1
                Self.log.debug("active font could not be read: \(file.path, privacy: .public)")
                continue
            }
            reads.append((file, contents))
        }

        guard !flagOn.isEmpty || !flagOff.isEmpty || !forget.isEmpty || !reads.isEmpty else { return result }

        // 7. Apply everything in one transaction.
        try store.database.transaction {
            var created: [String: Int64] = [:]
            var inserted: [Int64] = []
            for (file, contents) in reads {
                let locationID: Int64
                switch file.target {
                case .location(let id):
                    locationID = id
                case .newAutoLocation(let folder):
                    if let id = created[folder] {
                        locationID = id
                    } else {
                        let ref = refs[folder]!
                        let loc = try store.upsertLocation(
                            kind: Self.isSystemPath(folder) ? .system : .userInstalled, volumeUUID: ref.volumeUUID,
                            relativePath: ref.relativePath, displayName: (folder as NSString).lastPathComponent,
                            lastKnownPath: folder, autoIndexed: true)
                        created[folder] = loc.id
                        locationID = loc.id
                        result.locationsChanged = true
                    }
                }
                // Batch 0: indexing what is active elsewhere is not an import.
                let record = FileRecord(locationID: locationID, relativePath: file.relativePath, size: contents.size,
                                        mtime: contents.mtime, format: contents.format, fingerprint: contents.fingerprint)
                inserted.append(try store.insertFile(record, faces: contents.faces, importBatch: 0))
            }
            try store.setExternalActive(fileIDs: flagOn + inserted, true)
            try store.setExternalActive(fileIDs: flagOff, false)
            try store.deleteFiles(forget)
            if try store.deleteEmptyAutoLocations() > 0 { result.locationsChanged = true }
            result.indexedFiles = inserted.count
        }
        return result
    }
}
