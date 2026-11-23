import CoreServices
import Foundation

/// Directory-level FSEvents watch on one folder tree. The handler runs on the main queue.
final class FolderWatcher {
    /// Only ever invoked on the main queue.
    private final class Box: @unchecked Sendable {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }

    let path: String
    private let box: Box
    private var stream: FSEventStreamRef?

    init?(path: String, latency: TimeInterval = 2, handler: @escaping @MainActor () -> Void) {
        self.path = path
        self.box = Box(handler)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.handler() }
        }
        // File-level events stay off: any change anywhere below the root is enough to schedule a rescan.
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
