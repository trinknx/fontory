import Foundation

/// A location on a volume, independent of where the volume is currently mounted.
public struct VolumeRef: Sendable, Hashable {
    public let volumeUUID: String
    /// Path relative to the volume root: no leading "/", "/" separators, "" = the root itself.
    public let relativePath: String

    public init(volumeUUID: String, relativePath: String) {
        self.volumeUUID = volumeUUID
        self.relativePath = relativePath
    }
}

public enum VolumeIdentity {
    public enum Failure: Error { case noVolumeUUID(URL) }

    private static let dataVolumePath = "/System/Volumes/Data"

    public static func ref(for url: URL) throws -> VolumeRef {
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try real.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        guard let uuid = values.volumeUUIDString, !uuid.isEmpty else { throw Failure.noVolumeUUID(url) }
        let volumePath = values.volume?.resolvingSymlinksInPath().standardizedFileURL.path ?? "/"
        return VolumeRef(volumeUUID: uuid, relativePath: relative(real.path, to: volumePath))
    }

    public static func resolve(
        _ ref: VolumeRef,
        mountedVolumes: [URL] = defaultVolumes(),
        uuidOf: (URL) -> String? = { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
    ) -> URL? {
        guard let volume = mountedVolumes.first(where: { uuidOf($0) == ref.volumeUUID }) else { return nil }
        // The Data volume is firmlinked into "/", so paths on it are addressed from "/".
        let isData = volume.standardizedFileURL.path == dataVolumePath
        let root = isData ? URL(fileURLWithPath: "/") : volume
        return ref.relativePath.isEmpty ? root : root.appendingPathComponent(ref.relativePath)
    }

    public static func defaultVolumes() -> [URL] {
        var urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes]) ?? []
        for extra in ["/", dataVolumePath] {
            let url = URL(fileURLWithPath: extra)
            if !urls.contains(where: { $0.standardizedFileURL.path == extra }) { urls.append(url) }
        }
        return urls
    }

    private static func relative(_ path: String, to volumePath: String) -> String {
        var rel = path
        if volumePath != "/", path == volumePath || path.hasPrefix(volumePath + "/") {
            rel = String(path.dropFirst(volumePath.count))
        }
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}
