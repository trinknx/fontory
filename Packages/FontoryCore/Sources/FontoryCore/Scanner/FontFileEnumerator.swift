import Foundation

public struct ScannedFile: Sendable, Hashable {
    public var relativePath: String
    public var url: URL
    public var size: Int64
    public var mtime: Date
    /// Lowercased extension, or the sniffed format for extension-less files.
    public var format: String

    public init(relativePath: String, url: URL, size: Int64, mtime: Date, format: String) {
        self.relativePath = relativePath
        self.url = url
        self.size = size
        self.mtime = mtime
        self.format = format
    }
}

/// Collects items the enumerator could not read (unreadable subfolders, files whose attributes can't be read).
/// A non-empty report means the listing is incomplete: absence of a file proves nothing.
public final class EnumerationReport: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []
    private var storedCount = 0
    private let cap: Int

    public init(cap: Int = 50) { self.cap = cap }

    /// First `cap` unreadable relative paths.
    public var paths: [String] { lock.withLock { storedPaths } }
    /// Total number of unreadable items, including those beyond the stored cap.
    public var count: Int { lock.withLock { storedCount } }

    func record(_ relativePath: String) {
        lock.withLock {
            storedCount += 1
            if storedPaths.count < cap { storedPaths.append(relativePath) }
        }
    }
}

public enum FontFileEnumerator {
    public static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2", "pfb", "pfa", "pfm", "lwfn", "suit"]

    /// Walks `root` recursively. Skips hidden files and packages, follows no symlinks.
    /// Files with a listed extension are included unsniffed; extension-less files only when their magic bytes match a font.
    /// The stream finishes with an error only for root problems: the root is missing, is not a directory, or cannot itself be
    /// enumerated. Unreadable subfolders and files are skipped and noted in `report`; callers must treat a non-empty
    /// report as an incomplete listing and never as proof that files are gone.
    public static func enumerate(root: URL, report: EnumerationReport? = nil) -> AsyncThrowingStream<ScannedFile, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try walk(root: root, report: report) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `resolvingSymlinksInPath` drops the `/private` prefix, which `FileManager.enumerator` reports; use realpath instead.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Synchronous walk (`NSDirectoryEnumerator` iteration is unavailable in async contexts).
    private static func walk(root: URL, report: EnumerationReport?, emit: (ScannedFile) -> Void) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path, NSLocalizedDescriptionKey: "Not a directory"])
        }
        let given = root
        let root = URL(fileURLWithPath: realPath(root.path), isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        // The enumerator may report either the given or the symlink-resolved form of the root (e.g. /var vs /private/var).
        let prefixes = [root.path, given.path].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func relativePath(_ url: URL) -> String {
            let path = url.path
            return prefixes.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) } ?? url.lastPathComponent
        }
        let rootFailure = FailureBox()
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                let p = url.path
                if p == root.path || p == given.path || p + "/" == prefixes[0] || p + "/" == prefixes[1] {
                    rootFailure.record(error)
                    return false
                }
                report?.record(relativePath(url))
                return true
            }) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }
        for case let url as URL in walker {
            if Task.isCancelled { return }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                report?.record(relativePath(url))
                continue
            }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let format: String
            if extensions.contains(ext) {
                format = ext
            } else if ext.isEmpty, let sniffed = FontFormatSniffer.sniff(url: url) {
                format = sniffed
            } else {
                continue
            }
            emit(ScannedFile(
                relativePath: relativePath(url), url: url,
                size: Int64(values.fileSize ?? 0),
                mtime: values.contentModificationDate ?? .distantPast,
                format: format))
        }
        if let error = rootFailure.error { throw error }
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Error?
        var error: Error? { lock.withLock { first } }
        func record(_ error: Error) { lock.withLock { if first == nil { first = error } } }
    }
}
