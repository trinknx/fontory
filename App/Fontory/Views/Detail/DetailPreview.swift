import AppKit
import FontoryCore
import SwiftUI

/// Keys that open the family page from the browser: Return (or Enter) and ⌘↓.
enum FamilyDetailKeys {
    static func opensFamily(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 36 || event.keyCode == 76 { return mods.isEmpty }   // Return, keypad Enter
        return event.keyCode == 125 && mods == .command                          // ⌘↓
    }
}

/// Preview requests of the family page: the current preview settings (text, colors, alignment, guides, features…)
/// at the page's own point size. Auto size is off: the styles of one family are compared at one size.
@MainActor
enum DetailPreview {
    static func key(for row: FaceRow, preview: PreviewSettings, pointSize: CGFloat, size: CGSize, scale: CGFloat,
                    styleNames: Bool) -> PreviewPipeline.Key {
        var request = preview.request(pointSize: pointSize, size: CGSize(width: floor(size.width), height: floor(size.height)),
                                      scale: scale)
        request.pointSize = pointSize   // not the toolbar's size override
        // Font Names: the header shows the family, each style its own full name.
        request.text = preview.showsFontNames && styleNames ? row.fullName : preview.text(for: row)
        return PreviewPipeline.Key(faceID: row.id, request: request, autoSize: false)
    }
}

/// The family page header's large preview of the representative face.
struct FamilyHeaderPreview: NSViewRepresentable {
    static let pointSize: CGFloat = 64

    let model: AppModel
    let faceID: Int64
    let rowsVersion: Int
    let preview: PreviewSettings

    func makeNSView(context: Context) -> HeaderPreviewNSView {
        HeaderPreviewNSView(model: model)
    }

    func updateNSView(_ view: HeaderPreviewNSView, context: Context) {
        view.update(faceID: faceID, rowsVersion: rowsVersion, preview: preview)
    }
}

/// Shows one preview rendered by the shared pipeline (lane `detailHeader`) at the view's size; re-renders 150 ms
/// after the last resize, showing the previous image scaled meanwhile.
final class HeaderPreviewNSView: NSView {
    private let model: AppModel
    private let previewLayer = CALayer()
    private var faceID: Int64?
    private var rowsVersion = -1
    private var preview = PreviewSettings()
    private var wantedKey: PreviewPipeline.Key?
    private var renderedSize: CGSize = .zero
    private var resizeTask: Task<Void, Never>?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        model.previewPipeline.addRenderObserver(self) { [weak self] key, image in
            guard let self, key == self.wantedKey else { return }
            self.previewLayer.contents = image
        }
        observer = NotificationCenter.default.addObserver(forName: AppModel.rowsLoadedNotification, object: model, queue: .main) { [weak self] note in
            let ids = note.userInfo?[AppModel.rowIDsKey] as? [Int64] ?? []
            MainActor.assumeIsolated {
                guard let self, let id = self.faceID, ids.contains(id) else { return }
                self.render()
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Family preview")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var wantsUpdateLayer: Bool { true }

    func update(faceID new: Int64, rowsVersion newVersion: Int, preview newPreview: PreviewSettings) {
        guard new != faceID || newVersion != rowsVersion || newPreview != preview else { return }
        if new != faceID { previewLayer.contents = nil }
        faceID = new
        rowsVersion = newVersion
        preview = newPreview
        render()
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        guard bounds.size != renderedSize else { return }
        // The first size renders at once; later resizes wait until they settle.
        if previewLayer.contents == nil { return render() }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.render()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    private func render() {
        layer?.backgroundColor = preview.background
        guard let faceID, bounds.width > 1, bounds.height > 1 else { return }
        guard let row = model.cachedRow(faceID) else {
            model.prefetchRows([faceID])
            return
        }
        renderedSize = bounds.size
        let key = DetailPreview.key(for: row, preview: preview, pointSize: FamilyHeaderPreview.pointSize, size: bounds.size,
                                    scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, styleNames: false)
        wantedKey = key
        previewLayer.opacity = row.online ? 1 : 0.4
        if let image = model.previewPipeline.image(for: key) {
            previewLayer.contents = image
        } else if let url = row.fileURL {
            model.previewPipeline.request(key, fileURL: url, faceIndex: row.faceIndex, lane: .detailHeader)
        }
    }
}
