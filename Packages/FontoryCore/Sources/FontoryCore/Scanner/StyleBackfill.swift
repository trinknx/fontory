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
    /// (one transaction each). An unreadable face gets .unknown with the current version (no endless retries).
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
            let written = await Self.detached { () -> Int? in
                let batch = try store.facesNeedingClassification(limit: StyleBackfill.batchSize)
                if batch.isEmpty { return nil }
                guard let classes = StyleBackfill.classify(batch, isCancelled: { Task.isCancelled }) else { return nil }
                try store.setStyleClasses(classes, version: StyleClassifier.version)
                return batch.count
            } ?? nil
            // A store failure, an empty batch or cancellation ends the run; the faces left are picked up next time.
            guard let written else { finished = true; return nil }
            done += written
            return BackfillProgress(done: done, total: max(total, done))
        }

        /// Runs `work` in a detached utility task that is cancelled with the caller. Nil on error.
        private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
            let task = Task.detached(priority: .utility) { try work() }
            return await withTaskCancellationHandler { try? await task.value } onCancel: { task.cancel() }
        }
    }

    /// Reads each file once per batch, whatever the number of its faces. Returns nil as soon as `isCancelled`
    /// says so (checked before every face).
    static func classify(_ batch: [(faceID: Int64, url: URL, faceIndex: Int)],
                         isCancelled: () -> Bool) -> [(faceID: Int64, styleClass: StyleClass)]? {
        var cache: [URL: [CTFontDescriptor]] = [:]
        var out: [(faceID: Int64, styleClass: StyleClass)] = []
        out.reserveCapacity(batch.count)
        for item in batch {
            if isCancelled() { return nil }
            let descriptors: [CTFontDescriptor]
            if let hit = cache[item.url] {
                descriptors = hit
            } else {
                descriptors = (CTFontManagerCreateFontDescriptorsFromURL(item.url as CFURL) as? [CTFontDescriptor]) ?? []
                cache[item.url] = descriptors
            }
            guard item.faceIndex >= 0, item.faceIndex < descriptors.count else { out.append((item.faceID, .unknown)); continue }
            out.append((item.faceID, FontParser.styleClass(descriptor: descriptors[item.faceIndex],
                                                            fallbackName: item.url.deletingPathExtension().lastPathComponent)))
        }
        return out
    }
}
