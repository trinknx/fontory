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

public enum FontFileEnumerator {
    public static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont", "woff", "woff2", "pfb", "pfa", "pfm", "lwfn", "suit"]

    /// Walks `root` recursively. Skips hidden files and packages, follows no symlinks.
    /// Files with a listed extension are included unsniffed; extension-less files only when their magic bytes match a font.
    public static func enumerate(root: URL) -> AsyncThrowingStream<ScannedFile, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                walk(root: root) { continuation.yield($0) }
                continuation.finish()
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
    private static func walk(root: URL, emit: (ScannedFile) -> Void) {
        let given = root
        let root = URL(fileURLWithPath: realPath(root.path), isDirectory: true)
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        // The enumerator may report either the given or the symlink-resolved form of the root (e.g. /var vs /private/var).
        let prefixes = [root.path, given.path].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        for case let url as URL in walker {
            if Task.isCancelled { return }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let format: String
            if extensions.contains(ext) {
                format = ext
            } else if ext.isEmpty, let sniffed = FontFormatSniffer.sniff(url: url) {
                format = sniffed
            } else {
                continue
            }
            let path = url.path
            let relative = prefixes.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) } ?? url.lastPathComponent
            emit(ScannedFile(
                relativePath: relative, url: url,
                size: Int64(values.fileSize ?? 0),
                mtime: values.contentModificationDate ?? .distantPast,
                format: format))
        }
    }
}
