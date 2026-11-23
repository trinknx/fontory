import CoreText
import Foundation

public struct BackfillProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// Fills in what faces indexed under older versions lack, in the background: the style class (`StyleClassifier.version`)
/// and the metadata (`FaceMetadata.version`: coverage, features, figures), both from one read of the face. Only online
/// faces are read; faces on an unplugged volume wait for the next run.
public final class FaceBackfill: Sendable {
    static let batchSize = 200
    let store: FontStore
    /// Reads a file's face descriptors (empty when unreadable or absent). A seam for counting reads in tests.
    let open: @Sendable (URL) -> [CTFontDescriptor]

    public convenience init(store: FontStore) { self.init(store: store, open: FaceBackfill.openDescriptors) }

    init(store: FontStore, open: @escaping @Sendable (URL) -> [CTFontDescriptor]) {
        self.store = store
        self.open = open
    }

    static func openDescriptors(_ url: URL) -> [CTFontDescriptor] {
        (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
    }

    /// Updates online faces whose class_version < StyleClassifier.version or meta_version < FaceMetadata.version, in
    /// batches of at most 200 (one transaction each). A face whose file is present but unreadable gets .unknown and
    /// empty metadata at the current versions (no endless retries); one whose file cannot be reached (a pulled drive,
    /// a deleted file) is left untouched, so a later run reads it once the file is back. The run walks the faces in id
    /// order, so skipped faces do not stall it.
    ///
    /// Each batch is read and written in a detached `.utility` task (never on the caller's actor), which the
    /// iterating task awaits: when iteration ends, no work of the run is left in flight. Cancelling the iterating
    /// task stops the run between faces; the batch in progress is not written, written batches stay.
    public func run() -> AsyncStream<BackfillProgress> {
        let state = RunState(store: store, open: open)
        return AsyncStream(unfolding: { await state.next() })
    }

    /// The progress of one run, advanced by the stream's iterator (one call at a time).
    private final class RunState: @unchecked Sendable {
        let store: FontStore
        let open: @Sendable (URL) -> [CTFontDescriptor]
        var total: Int?
        var done = 0
        /// The last face id handed out; the next batch starts after it.
        var cursor: Int64 = 0
        var finished = false

        init(store: FontStore, open: @escaping @Sendable (URL) -> [CTFontDescriptor]) {
            self.store = store
            self.open = open
        }

        func next() async -> BackfillProgress? {
            if finished || Task.isCancelled { return nil }
            let store = store
            let open = open
            guard let total else {
                // First step: the count, reported as 0 of N (nothing when there is nothing to do).
                let count = await Self.detached { try store.countFacesNeedingBackfill() } ?? 0
                total = count
                if count == 0 || Task.isCancelled { finished = true; return nil }
                return BackfillProgress(done: 0, total: count)
            }
            let cursor = cursor
            let step = await Self.detached { () -> (count: Int, lastID: Int64)? in
                let batch = try store.facesNeedingBackfill(limit: FaceBackfill.batchSize, afterID: cursor)
                guard let last = batch.last else { return nil }
                guard let results = FaceBackfill.read(batch, isCancelled: { Task.isCancelled }, open: open) else { return nil }
                if !results.isEmpty { try store.setBackfillResults(results) }
                return (batch.count, last.faceID)
            } ?? nil
            // A store failure, an empty batch or cancellation ends the run; the faces left are picked up next time.
            guard let step else { finished = true; return nil }
            self.cursor = step.lastID
            done += step.count
            return BackfillProgress(done: done, total: max(total, done))
        }

        /// Runs `work` in a detached utility task that is cancelled with the caller. Nil on error.
        private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
            let task = Task.detached(priority: .utility) { try work() }
            return await withTaskCancellationHandler { try? await task.value } onCancel: { task.cancel() }
        }
    }

    /// Reads each file once per batch, whatever the number of its faces, and makes one font per face for both its
    /// class and its metadata. Faces whose file cannot be reached are left out (not stamped). Returns nil as soon as
    /// `isCancelled` says so (checked before every face).
    static func read(_ batch: [(faceID: Int64, url: URL, faceIndex: Int)], isCancelled: () -> Bool,
                     open: (URL) -> [CTFontDescriptor] = openDescriptors)
        -> [(faceID: Int64, styleClass: StyleClass, metadata: FaceMetadata)]? {
        var cache: [URL: [CTFontDescriptor]?] = [:]
        var out: [(faceID: Int64, styleClass: StyleClass, metadata: FaceMetadata)] = []
        out.reserveCapacity(batch.count)
        for item in batch {
            if isCancelled() { return nil }
            let descriptors: [CTFontDescriptor]
            if let hit = cache[item.url] {
                guard let hit else { continue }  // unreachable
                descriptors = hit
            } else {
                let read = open(item.url)
                // Nothing read: an unparsable file (unknown, empty metadata) or one that is not there (left for later).
                if read.isEmpty && (try? item.url.checkResourceIsReachable()) != true {
                    cache[item.url] = .some(nil)
                    continue
                }
                cache[item.url] = read
                descriptors = read
            }
            guard item.faceIndex >= 0, item.faceIndex < descriptors.count else {
                out.append((item.faceID, .unknown, .empty))
                continue
            }
            let face = FontParser.backfill(descriptor: descriptors[item.faceIndex],
                                           fallbackName: item.url.deletingPathExtension().lastPathComponent)
            out.append((item.faceID, face.styleClass, face.metadata))
        }
        return out
    }
}
