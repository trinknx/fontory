import AppKit
import FontoryCore

/// Renders the Characters tab's glyph cells off the main thread and caches them.
///
/// One render per visible cell, on a concurrent queue (at most 4 at once); a cell that scrolls out cancels its
/// pending render. Finished images go into an LRU cache bounded by pixel memory (64 MB). Fonts come from the shared
/// `PreviewRenderer`, so a face is parsed once for the whole app.
@MainActor
final class GlyphPipeline {
    struct Key: Hashable, Sendable {
        let faceID: Int64
        let glyph: CGGlyph
        let pointSize: CGFloat
        let style: GlyphCellStyle
    }

    static let imageCostLimit = 64 * 1024 * 1024

    private let renderer: PreviewRenderer
    private let queue: OperationQueue
    private let images = LRUCache<Key, CGImage>(limit: 6000, costLimit: GlyphPipeline.imageCostLimit)
    private var operations: [Key: GlyphRenderOperation] = [:]
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (Key, CGImage) -> Void
    }

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        queue = OperationQueue()
        queue.name = "Fontory glyph cells"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
    }

    /// Calls `handler` on the main actor whenever an image is ready, for as long as `owner` lives.
    func addRenderObserver(_ owner: AnyObject, handler: @escaping @MainActor (Key, CGImage) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    func image(for key: Key) -> CGImage? {
        images[key]
    }

    /// Renders `key` unless it is cached or already rendering.
    func request(_ key: Key, fileURL: URL, faceIndex: Int) {
        if images[key] != nil { return }
        if let existing = operations[key], !existing.isCancelled { return }
        let op = GlyphRenderOperation(key: key, fileURL: fileURL, faceIndex: faceIndex, renderer: renderer)
        op.completion = { [weak self, weak op] image in
            guard let self, let op else { return }
            if self.operations[key] === op { self.operations[key] = nil }
            guard let image else { return }
            self.images.setValue(image, forKey: key, cost: image.bytesPerRow * image.height)
            self.observers.removeAll { $0.owner == nil }
            for observer in self.observers { observer.handler(key, image) }
        }
        operations[key] = op
        queue.addOperation(op)
    }

    func cancel(_ key: Key) {
        operations.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        for op in operations.values { op.cancel() }
        operations.removeAll()
    }

    /// Drops every cached image (the font files may have changed).
    func removeAllImages() {
        cancelAll()
        images.removeAll()
    }
}

/// One glyph cell render. A cancelled operation that has not started does nothing; delivers on the main actor.
private final class GlyphRenderOperation: Operation, @unchecked Sendable {
    let key: GlyphPipeline.Key
    private let fileURL: URL
    private let faceIndex: Int
    private let renderer: PreviewRenderer
    /// Set on the main actor before the operation is queued; read on the main actor only.
    @MainActor var completion: ((CGImage?) -> Void)?

    init(key: GlyphPipeline.Key, fileURL: URL, faceIndex: Int, renderer: PreviewRenderer) {
        self.key = key
        self.fileURL = fileURL
        self.faceIndex = faceIndex
        self.renderer = renderer
    }

    override func main() {
        guard !isCancelled,
              let font = renderer.font(fileURL: fileURL, faceIndex: faceIndex, pointSize: key.pointSize) else {
            return deliver(nil)
        }
        // A render that finishes after being cancelled is still delivered and cached: the work is done, and the cell
        // may scroll back.
        deliver(GlyphCellRenderer.render(font: font, glyph: key.glyph, style: key.style))
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
