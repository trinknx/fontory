import Foundation

public enum GoogleRunEvent: Sendable {
    case familyDone(String)
    /// Family name and error text.
    case familyFailed(String, String)
    /// The download folder is missing, unwritable or vanished mid-run; the run stopped without marking anything.
    case rootUnavailable
    /// The disk is full; the run stopped without marking anything.
    case outOfSpace
    /// Every family that needed a download was attempted.
    case finished
}

/// Downloads Google Fonts families into `<root>/<folder>/`.
///
/// Folder safety: this type only ever creates, replaces or deletes items inside `<root>/.fontory-tmp/` and
/// inside `<root>/<folder>/` of the family being installed. It never creates `root` itself or any parent of it
/// (no intermediate directories), so a vanished volume is reported instead of recreated as an empty folder.
public actor GoogleFontsDownloader {
    /// Tries per request (the first attempt plus retries).
    static let maxAttempts = 3
    static let tempFolderName = ".fontory-tmp"
    static let fontHost = "fonts.gstatic.com"

    private let store: FontStore
    private let root: URL
    private let transport: GoogleTransport
    private let maxConcurrentFiles: Int
    private let backoff: [Duration]
    private let minimumFamilies: Int
    private let writeData: @Sendable (Data, URL) throws -> Void
    private var running = false

    /// Writes a new file (never over an existing one).
    public static let defaultWrite: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// `backoff[i]` is the wait before retry `i + 1`; missing entries mean no wait (tests pass `[]` or zeros).
    public init(store: FontStore, root: URL, transport: GoogleTransport, maxConcurrentFiles: Int = 4,
                backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
                minimumFamilies: Int = GoogleCatalog.minimumFamilies,
                writeData: @escaping @Sendable (Data, URL) throws -> Void = GoogleFontsDownloader.defaultWrite) {
        self.store = store
        self.root = root.standardizedFileURL
        self.transport = transport
        self.maxConcurrentFiles = max(1, maxConcurrentFiles)
        self.backoff = backoff
        self.minimumFamilies = minimumFamilies
        self.writeData = writeData
    }

    private var tempRoot: URL { root.appendingPathComponent(Self.tempFolderName, isDirectory: true) }

    // MARK: Catalogue

    /// Fetches and parses the catalogue, then syncs it into the store. Any failure throws before the store is touched.
    public func refreshCatalog() async throws -> GoogleSyncSummary {
        let data = try await Self.fetch(GoogleCatalog.catalogURL, transport: transport, backoff: backoff)
        let families = try GoogleCatalog.parseCatalog(data, minimumFamilies: minimumFamilies)
        return try store.syncGoogleCatalog(families)
    }

    // MARK: Run

    /// Downloads every family that needs it, one family at a time. Cancelling the calling task pauses: in-flight
    /// requests are cancelled, the current family's temporary folder is deleted and nothing is marked failed.
    public func run(onEvent: @Sendable (GoogleRunEvent) -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let fm = FileManager.default
        guard rootAvailable(), fm.isWritableFile(atPath: root.path) else {
            onEvent(.rootUnavailable)
            return
        }
        try? fm.removeItem(at: tempRoot)
        defer { if rootAvailable() { try? fm.removeItem(at: tempRoot) } }

        guard let families = try? store.googleFamiliesNeedingDownload() else { return }
        for state in families {
            if Task.isCancelled { return }
            guard rootAvailable() else {
                onEvent(.rootUnavailable)
                return
            }
            switch await download(state) {
            case .done:
                do {
                    try store.markGoogleFamilyDone(state.family, modified: state.lastModified)
                    onEvent(.familyDone(state.family))
                } catch {
                    onEvent(.familyFailed(state.family, Self.describe(error)))
                }
            case .failed(let message):
                try? store.markGoogleFamilyFailed(state.family, error: message)
                onEvent(.familyFailed(state.family, message))
            case .cancelled:
                return
            case .rootUnavailable:
                onEvent(.rootUnavailable)
                return
            case .outOfSpace:
                onEvent(.outOfSpace)
                return
            }
        }
        onEvent(.finished)
    }

    private enum Outcome { case done, failed(String), cancelled, rootUnavailable, outOfSpace }

    private enum InstallError: Error {
        case notAFolder(String)
        case notAFile(String)
    }

    private func download(_ state: GoogleFamilyState) async -> Outcome {
        guard Self.isSafeName(state.folder) else { return .failed("Unsafe folder name: \(state.folder)") }

        let manifest: GoogleManifest
        do {
            let data = try await Self.fetch(GoogleCatalog.manifestURL(for: state.family), transport: transport, backoff: backoff)
            manifest = try GoogleCatalog.parseManifest(data)
        } catch {
            return Task.isCancelled ? .cancelled : .failed("Manifest: \(Self.describe(error))")
        }
        for ref in manifest.fontRefs where !Self.isAllowedFontURL(ref.url) {
            let host = ref.url.host() ?? "none"
            return .failed("Refused font URL (\(ref.url.scheme ?? "no scheme"), host \(host))")
        }

        // Names are flattened basenames already; guard anyway, and keep the first of case-insensitive duplicates.
        var seen = Set<String>()
        let texts = manifest.textFiles.filter { Self.isSafeName($0.name) && seen.insert($0.name.lowercased()).inserted }
        let fonts = manifest.fontRefs.filter { Self.isSafeName($0.name) && seen.insert($0.name.lowercased()).inserted }
        guard !fonts.isEmpty else { return .failed("No fonts in manifest") }
        if Task.isCancelled { return .cancelled }

        let fm = FileManager.default
        let staging = tempRoot.appendingPathComponent(state.folder, isDirectory: true)
        func abandon(_ outcome: Outcome) -> Outcome {
            try? fm.removeItem(at: staging)
            return outcome
        }
        func writeFailure(_ error: Error) -> Outcome {
            if !rootAvailable() { return .rootUnavailable }
            return Self.isOutOfSpace(error) ? .outOfSpace : .failed(Self.describe(error))
        }

        do {
            guard rootAvailable() else { return .rootUnavailable }
            if !fm.fileExists(atPath: tempRoot.path) {
                try fm.createDirectory(at: tempRoot, withIntermediateDirectories: false)
            }
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for text in texts {
                try writeData(Data(text.contents.utf8), staging.appendingPathComponent(text.name))
            }
        } catch {
            return abandon(writeFailure(error))
        }

        let failure = await Self.fetchAll(fonts, into: staging, transport: transport, backoff: backoff,
                                          limit: maxConcurrentFiles, writeData: writeData)
        if Task.isCancelled { return abandon(.cancelled) }
        switch failure {
        case .fetch(let name, let message)?: return abandon(.failed("\(name): \(message)"))
        case .write(let error)?: return abandon(writeFailure(error))
        case nil: break
        }

        guard rootAvailable() else { return abandon(.rootUnavailable) }
        let dest = root.appendingPathComponent(state.folder, isDirectory: true)
        do {
            try install(staging: staging, into: dest, names: texts.map(\.name) + fonts.map(\.name),
                        pruneOthers: state.downloadedModified != nil)
        } catch {
            return abandon(writeFailure(error))
        }
        try? fm.removeItem(at: staging)
        return .done
    }

    /// No `dest` yet: the staging folder is moved into place. Otherwise each new file replaces the file with the
    /// same name; with `pruneOthers` (an update of a family Fontory completed in this folder), regular files (and
    /// links) in `dest` whose names are not in the new set are then deleted. A first download into an existing
    /// folder (one the user made) never deletes anything.
    private func install(staging: URL, into dest: URL, names: [String], pruneOthers: Bool) throws {
        let fm = FileManager.default
        // attributesOfItem does not follow symlinks, so a link at `dest` is never written through.
        guard let destType = (try? fm.attributesOfItem(atPath: dest.path))?[.type] as? FileAttributeType else {
            try fm.moveItem(at: staging, to: dest)
            return
        }
        guard destType == .typeDirectory else { throw InstallError.notAFolder(dest.lastPathComponent) }

        for name in names {
            let source = staging.appendingPathComponent(name)
            let target = dest.appendingPathComponent(name)
            if let type = (try? fm.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType {
                guard type == .typeRegular else { throw InstallError.notAFile(name) }
                _ = try fm.replaceItemAt(target, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: target)
            }
        }

        guard pruneOthers else { return }
        let keep = Set(names.map { $0.lowercased() })
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        for item in try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            guard !keep.contains(item.lastPathComponent.lowercased()) else { continue }
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            try fm.removeItem(at: item)
        }
    }

    private func rootAvailable() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Helpers

    /// A single path component that cannot escape or hide inside the family folder.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// A write failed because the volume is full (Cocoa out-of-space, or POSIX ENOSPC, also as the underlying error).
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// Allowed-hosts rule: font files come only from https://fonts.gstatic.com.
    static func isAllowedFontURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host()?.lowercased() == fontHost
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case GoogleTransportError.http(let code): return "HTTP \(code)"
        case GoogleCatalogError.malformed: return "Malformed response"
        case GoogleCatalogError.noFonts: return "No fonts in manifest"
        case GoogleCatalogError.tooFewFamilies(let n): return "Catalogue lists only \(n) families"
        case InstallError.notAFolder(let name): return "\(name) exists and is not a folder"
        case InstallError.notAFile(let name): return "\(name) exists and is not a file"
        default: return error.localizedDescription
        }
    }

    /// Fetches with up to `maxAttempts` tries. Cancellation is never retried.
    static func fetch(_ url: URL, transport: GoogleTransport, backoff: [Duration]) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await transport.data(from: url)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                attempt += 1
                if attempt >= maxAttempts { throw error }
                let wait = attempt - 1 < backoff.count ? backoff[attempt - 1] : .zero
                if wait > .zero { try await Task.sleep(for: wait) }
            }
        }
    }

    private enum FileFailure: Sendable {
        case fetch(String, String)
        case write(Error)
    }

    /// Downloads `refs` into `dir` with at most `limit` requests in flight. Returns the first failure, if any;
    /// remaining requests are cancelled after it.
    private static func fetchAll(_ refs: [(name: String, url: URL)], into dir: URL, transport: GoogleTransport,
                                 backoff: [Duration], limit: Int,
                                 writeData: @escaping @Sendable (Data, URL) throws -> Void) async -> FileFailure? {
        await withTaskGroup(of: FileFailure?.self) { group in
            var next = 0
            var failure: FileFailure?
            func enqueue() {
                let ref = refs[next]
                next += 1
                group.addTask {
                    let data: Data
                    do {
                        data = try await fetch(ref.url, transport: transport, backoff: backoff)
                    } catch {
                        return .fetch(ref.name, describe(error))
                    }
                    do {
                        try writeData(data, dir.appendingPathComponent(ref.name))
                    } catch {
                        return .write(error)
                    }
                    return nil
                }
            }
            while next < min(limit, refs.count) { enqueue() }
            while let result = await group.next() {
                if let result {
                    if failure == nil { failure = result }
                    group.cancelAll()
                } else if failure == nil, !Task.isCancelled, next < refs.count {
                    enqueue()
                }
            }
            return failure
        }
    }
}
