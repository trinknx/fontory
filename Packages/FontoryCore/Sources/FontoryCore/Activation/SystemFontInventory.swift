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
    /// Registered files inside scanned locations (folder, system, user-installed) that have not indexed them yet,
    /// by location: the location's next scan picks them up.
    public var pendingPaths: [Int64: Set<String>] = [:]
    public var pendingLocationIDs: Set<Int64> { Set(pendingPaths.keys) }

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
/// - Nothing is ever written into a user's location (folder or file set): a registered file in a file set's folder
///   that the set does not list is not indexed, and a folder the user owns is never turned into an auto-indexed one.
/// - Private faces are ignored: dot-prefixed PostScript names, dot-prefixed files under /System, and FontServices'
///   Reserved fonts. Hidden files elsewhere are kept: Adobe Fonts syncs its fonts as `.r/.12345.otf`.
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
    /// Registered files that could not be read this session, keyed by path, size and modification date: not read
    /// again on every pass, but read again once the file changes (still being written or synced when registered).
    private var unreadable = Set<String>()

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

    /// Fonts macOS keeps for itself: hidden files under /System, and FontServices' Reserved fonts. Hidden files
    /// elsewhere are public fonts (Adobe Fonts stores its synced fonts that way).
    static func isPrivatePath(_ path: String) -> Bool {
        if isSystemPath(path) && (path as NSString).lastPathComponent.hasPrefix(".") { return true }
        return path.contains("/FontServices.framework/") && path.contains("/Reserved/")
    }

    private static func unreadableKey(_ path: String) -> String {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(String.init) ?? "?"
        let mtime = values?.contentModificationDate.map { String($0.timeIntervalSince1970) } ?? "?"
        return "\(path)|\(size)|\(mtime)"
    }

    /// CoreText names the face in the fragment (`postscript-name=…`); a dot-prefixed name is a private face.
    static func isPrivateFace(_ url: URL) -> Bool {
        guard let fragment = url.fragment(percentEncoded: false) else { return false }
        return fragment.hasPrefix("postscript-name=.")
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
        for url in available where url.isFileURL && !Self.isPrivateFace(url) {
            let std = url.standardizedFileURL.path
            guard !std.isEmpty, canonicalByKey[std] == nil else { continue }
            let canonical = resolvePath(std)
            if Self.isPrivatePath(std) || Self.isPrivatePath(canonical) { continue }
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
        var forget: [(fileID: Int64, locationID: Int64)] = []
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
            if loc.autoIndexed && canonical == nil { forget.append((file.fileID, loc.id)) }
        }
        result.flagsChanged = flagOn.count + flagOff.count
        result.removedFiles = forget.count

        // 4. Registered files the index does not have. File sets never cover: they hold only what the user imported.
        let fixed = locations.filter { !$0.autoIndexed }
        let scanned = fixed.filter { $0.kind != .fileSet }
        var autoByFolder: [String: Int64] = [:]
        for loc in locations where loc.autoIndexed && loc.online {
            for root in roots[loc.id] ?? [] { autoByFolder[root] = loc.id }
        }
        var newFiles: [NewFile] = []
        for path in registered where !matched.contains(path) {
            var covering: (loc: LocationRecord, root: String)?
            for loc in scanned {
                for root in roots[loc.id] ?? [] where Self.isUnder(path, root) {
                    if covering == nil || root.count > covering!.root.count { covering = (loc, root) }
                }
            }
            if let covering {
                // An offline location's old path cannot hold a registered file; nothing to do.
                if covering.loc.online { result.pendingPaths[covering.loc.id, default: []].insert(path) }
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
            let key = Self.unreadableKey(file.path)
            if unreadable.contains(key) { continue }
            guard var contents = readFile(URL(fileURLWithPath: file.path)) else {
                result.failedFiles += 1
                unreadable.insert(key)
                Self.log.debug("active font could not be read: \(file.path, privacy: .public)")
                continue
            }
            contents.faces.removeAll { $0.postScriptName.hasPrefix(".") }
            if contents.faces.isEmpty { unreadable.insert(key); continue }
            reads.append((file, contents))
        }

        guard !flagOn.isEmpty || !flagOff.isEmpty || !forget.isEmpty || !reads.isEmpty else { return result }

        // 7. Apply everything in one transaction.
        try store.database.transaction {
            // Ownership is checked again under the write lock: a location the user took over since step 2 (Add Folder
            // on an auto-indexed folder) is neither written into nor cleaned up.
            let stillAuto = Set(try store.locations().filter(\.autoIndexed).map(\.id))
            var created: [String: Int64] = [:]
            var inserted: [Int64] = []
            for (file, contents) in reads {
                if case .newAutoLocation(let folder) = file.target, refs[folder] == nil { continue }
                let locationID: Int64
                switch file.target {
                case .location(let id):
                    guard stillAuto.contains(id) else { continue }
                    locationID = id
                case .newAutoLocation(let folder):
                    if let id = created[folder] {
                        locationID = id
                    } else {
                        // One auto location per folder. Downloaded system fonts (MobileAsset …/AssetData) each sit in
                        // a folder of their own, so there can be many of these; they are never listed as locations,
                        // only their fonts show (System / User views).
                        let ref = refs[folder]!
                        let loc = try store.upsertLocation(
                            kind: Self.isSystemPath(folder) ? .system : .userInstalled, volumeUUID: ref.volumeUUID,
                            relativePath: ref.relativePath, displayName: (folder as NSString).lastPathComponent,
                            lastKnownPath: folder, autoIndexed: true)
                        // The user may have added this folder since step 2: the upsert leaves a user's location
                        // alone, and nothing is written into it.
                        guard loc.autoIndexed else {
                            refs[folder] = nil
                            Self.log.info("\(folder, privacy: .public) became a user location; its active fonts are left to its scan")
                            continue
                        }
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
            let gone = forget.filter { stillAuto.contains($0.locationID) }.map(\.fileID)
            try store.deleteFiles(gone)
            result.removedFiles = gone.count
            if try store.deleteEmptyAutoLocations() > 0 { result.locationsChanged = true }
            result.indexedFiles = inserted.count
        }
        return result
    }
}
