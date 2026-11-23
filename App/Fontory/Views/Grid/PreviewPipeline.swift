import AppKit
import FontoryCore

/// Renders grid previews off the main thread and caches them.
///
/// Requests run on a concurrent queue (at most 6 at once) keyed by face and request; finished images go into an
/// LRU cache, and the newest image of every face is also kept so a cell can show it scaled while the exact size
/// renders (or while rendering is suspended during a zoom gesture).
@MainActor
final class PreviewPipeline {
    struct Key: Hashable, Sendable {
        let faceID: Int64
        let request: PreviewRequest
        /// With auto size, `request.pointSize` is the base size; the rendered size is chosen per face.
        let autoSize: Bool
    }

    /// Auto size: the ink height of the preview text as a fraction of the base point size.
    nonisolated static let autoSizeInkRatio: CGFloat = 0.72

    private let renderer: PreviewRenderer
    private let queue: OperationQueue
    private let images = LRUCache<Key, CGImage>(limit: 600)
    private let latestByFace = LRUCache<Int64, CGImage>(limit: 600)
    /// Ink height per point of size, per face and text. Linear in the point size, so measured once.
    private let inkPerPoint = LRUCache<InkKey, CGFloat>(limit: 4000)
    private var operations: [Int64: RenderOperation] = [:]

    /// Called on the main actor when the image for `key` is ready.
    var onRendered: ((Key, CGImage) -> Void)?

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        queue = OperationQueue()
        queue.name = "Fontory previews"
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
    }

    func image(for key: Key) -> CGImage? {
        images[key]
    }

    /// The most recently rendered image of a face, at whatever size or settings.
    func anyImage(forFace faceID: Int64) -> CGImage? {
        latestByFace[faceID]
    }

    /// Renders `key` unless it is cached or already rendering. A pending render of another key for the same face
    /// (an older size or text) is cancelled.
    func request(_ key: Key, fileURL: URL, faceIndex: Int) {
        if images[key] != nil { return }
        if let existing = operations[key.faceID] {
            if existing.key == key, !existing.isCancelled { return }
            existing.cancel()
        }
        let op = RenderOperation(key: key, fileURL: fileURL, faceIndex: faceIndex, renderer: renderer, inkPerPoint: inkPerPoint)
        op.completion = { [weak self, weak op] image in
            guard let self, let op else { return }
            if self.operations[key.faceID] === op { self.operations[key.faceID] = nil }
            guard let image else { return }
            self.images[key] = image
            self.latestByFace[key.faceID] = image
            self.onRendered?(key, image)
        }
        operations[key.faceID] = op
        queue.addOperation(op)
    }

    func cancel(faceID: Int64) {
        operations.removeValue(forKey: faceID)?.cancel()
    }

    func cancelAll() {
        for op in operations.values { op.cancel() }
        operations.removeAll()
    }
}

private struct InkKey: Hashable, Sendable {
    let faceID: Int64
    let text: String
}

/// One preview render. Checks for cancellation before and after the work; delivers on the main actor.
private final class RenderOperation: Operation, @unchecked Sendable {
    let key: PreviewPipeline.Key
    private let fileURL: URL
    private let faceIndex: Int
    private let renderer: PreviewRenderer
    private let inkPerPoint: LRUCache<InkKey, CGFloat>
    /// Set on the main actor before the operation is queued; read on the main actor only.
    @MainActor var completion: ((CGImage?) -> Void)?

    init(key: PreviewPipeline.Key, fileURL: URL, faceIndex: Int, renderer: PreviewRenderer, inkPerPoint: LRUCache<InkKey, CGFloat>) {
        self.key = key
        self.fileURL = fileURL
        self.faceIndex = faceIndex
        self.renderer = renderer
        self.inkPerPoint = inkPerPoint
    }

    override func main() {
        guard !isCancelled else { return deliver(nil) }
        var request = key.request
        if key.autoSize {
            request.pointSize = autoPointSize(base: request.pointSize, text: request.text)
        }
        let image = renderer.render(fileURL: fileURL, faceIndex: faceIndex, request: request)
        deliver(isCancelled ? nil : image)
    }

    /// The size whose ink height matches `autoSizeInkRatio` of the base size, clamped to a quarter…four times it.
    private func autoPointSize(base: CGFloat, text: String) -> CGFloat {
        let inkKey = InkKey(faceID: key.faceID, text: text)
        let perPoint: CGFloat
        if let cached = inkPerPoint[inkKey] {
            perPoint = cached
        } else {
            perPoint = renderer.inkHeight(fileURL: fileURL, faceIndex: faceIndex, text: text, pointSize: 100) / 100
            inkPerPoint[inkKey] = perPoint
        }
        guard perPoint > 0.001 else { return base }
        return min(base * 4, max(base / 4, base * PreviewPipeline.autoSizeInkRatio / perPoint))
    }

    private func deliver(_ image: CGImage?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.completion?(image)
                self.completion = nil
            }
        }
    }
}
