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
    /// Stops early on cancellation (cancel the consuming task or stop iterating); written batches stay.
    public func run() -> AsyncStream<BackfillProgress> {
        let store = store
        return AsyncStream { continuation in
            let task = Task {
                do {
                    let total = try store.countFacesNeedingClassification()
                    var done = 0
                    if total > 0 { continuation.yield(BackfillProgress(done: 0, total: total)) }
                    while !Task.isCancelled {
                        let batch = try store.facesNeedingClassification(limit: Self.batchSize)
                        if batch.isEmpty { break }
                        try store.setStyleClasses(Self.classify(batch), version: StyleClassifier.version)
                        done += batch.count
                        continuation.yield(BackfillProgress(done: done, total: max(total, done)))
                    }
                } catch {
                    // A store failure ends the run; the faces stay unclassified and the next run picks them up.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reads each file once per batch, whatever the number of its faces.
    private static func classify(_ batch: [(faceID: Int64, url: URL, faceIndex: Int)]) -> [(faceID: Int64, styleClass: StyleClass)] {
        var cache: [URL: [CTFontDescriptor]] = [:]
        return batch.map { item in
            let descriptors: [CTFontDescriptor]
            if let hit = cache[item.url] {
                descriptors = hit
            } else {
                descriptors = (CTFontManagerCreateFontDescriptorsFromURL(item.url as CFURL) as? [CTFontDescriptor]) ?? []
                cache[item.url] = descriptors
            }
            guard item.faceIndex >= 0, item.faceIndex < descriptors.count else { return (item.faceID, .unknown) }
            return (item.faceID, FontParser.styleClass(descriptor: descriptors[item.faceIndex],
                                                       fallbackName: item.url.deletingPathExtension().lastPathComponent))
        }
    }
}
