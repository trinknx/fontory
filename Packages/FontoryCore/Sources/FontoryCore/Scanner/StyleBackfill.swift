import CoreText
import Foundation

public struct BackfillProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}

/// Classifies faces indexed before the classifier existed (or under an older `StyleClassifier.version`), in the
/// background. Only online faces are read; faces on an unplugged volume wait for the next run.
public final class StyleBackfill: Sendable {
    static let batchSize = 200
    let store: FontStore

    public init(store: FontStore) { self.store = store }

    /// Classifies online faces whose class_version < StyleClassifier.version, in batches of at most 200
    /// (one transaction each). A face whose file is present but unreadable gets .unknown with the current version
    /// (no endless retries); one whose file cannot be reached (a pulled drive, a deleted file) is left untouched, so
    /// a later run classifies it once the file is back. The run walks the faces in id order, so skipped faces do not
    /// stall it.
    ///
    /// Each batch is read and written in a detached `.utility` task (never on the caller's actor), which the
    /// iterating task awaits: when iteration ends, no work of the run is left in flight. Cancelling the iterating
    /// task stops the run between faces; the batch in progress is not written, written batches stay.
    public func run() -> AsyncStream<BackfillProgress> {
        let state = RunState(store: store)
        return AsyncStream(unfolding: { await state.next() })
    }

    /// The progress of one run, advanced by the stream's iterator (one call at a time).
    private final class RunState: @unchecked Sendable {
        let store: FontStore
        var total: Int?
        var done = 0
        /// The last face id handed out; the next batch starts after it.
        var cursor: Int64 = 0
        var finished = false

        init(store: FontStore) { self.store = store }

        func next() async -> BackfillProgress? {
            if finished || Task.isCancelled { return nil }
            let store = store
            guard let total else {
                // First step: the count, reported as 0 of N (nothing when there is nothing to do).
                let count = await Self.detached { try store.countFacesNeedingClassification() } ?? 0
                total = count
                if count == 0 || Task.isCancelled { finished = true; return nil }
                return BackfillProgress(done: 0, total: count)
            }
            let cursor = cursor
            let step = await Self.detached { () -> (count: Int, lastID: Int64)? in
                let batch = try store.facesNeedingClassification(limit: StyleBackfill.batchSize, afterID: cursor)
                guard let last = batch.last else { return nil }
                guard let classes = StyleBackfill.classify(batch, isCancelled: { Task.isCancelled }) else { return nil }
                if !classes.isEmpty { try store.setStyleClasses(classes, version: StyleClassifier.version) }
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

    /// Reads each file once per batch, whatever the number of its faces. Faces whose file cannot be reached are
    /// left out (not classified, not stamped). Returns nil as soon as `isCancelled` says so (checked before every
    /// face).
    static func classify(_ batch: [(faceID: Int64, url: URL, faceIndex: Int)],
                         isCancelled: () -> Bool) -> [(faceID: Int64, styleClass: StyleClass)]? {
        var cache: [URL: [CTFontDescriptor]?] = [:]
        var out: [(faceID: Int64, styleClass: StyleClass)] = []
        out.reserveCapacity(batch.count)
        for item in batch {
            if isCancelled() { return nil }
            let descriptors: [CTFontDescriptor]
            if let hit = cache[item.url] {
                guard let hit else { continue }  // unreachable
                descriptors = hit
            } else {
                let read = (CTFontManagerCreateFontDescriptorsFromURL(item.url as CFURL) as? [CTFontDescriptor]) ?? []
                // Nothing read: an unparsable file (classified unknown) or one that is not there (left for later).
                if read.isEmpty && (try? item.url.checkResourceIsReachable()) != true {
                    cache[item.url] = .some(nil)
                    continue
                }
                cache[item.url] = read
                descriptors = read
            }
            guard item.faceIndex >= 0, item.faceIndex < descriptors.count else { out.append((item.faceID, .unknown)); continue }
            out.append((item.faceID, FontParser.styleClass(descriptor: descriptors[item.faceIndex],
                                                            fallbackName: item.url.deletingPathExtension().lastPathComponent)))
        }
        return out
    }
}
