import AppKit
import FontoryCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// The face the Characters tab shows: where to load it from and the metrics that size its cells.
struct GlyphFace: Equatable, Sendable {
    let faceID: Int64
    let fileURL: URL
    let faceIndex: Int
    let postScriptName: String
    /// The face's cell box (`GlyphInventory.cellBox`), shared by all its cells.
    let box: GlyphCellBox

    /// The point size of this face in a cell `side` points high.
    func cellPointSize(_ side: CGFloat) -> CGFloat {
        GlyphCellRenderer.pointSize(cellHeight: side, box: box)
    }
}

/// The Characters tab's glyph grid: an `NSCollectionView` with an arithmetic grid layout (`GlyphGridLayout`), so
/// only the visible cells exist and render, and reloads and size changes do not measure every glyph. Inputs are explicit so `updateNSView` runs exactly when one changes; `entriesVersion` stands for the
/// entries (comparing tens of thousands of entries on every update would be wasted work).
struct GlyphGridView: NSViewRepresentable {
    let model: AppModel
    let face: GlyphFace
    let entries: [GlyphEntry]
    let entriesVersion: Int
    let cellSize: Double
    let preview: PreviewSettings
    let selection: UInt32?
    let onSelect: (GlyphEntry?) -> Void

    func makeCoordinator() -> GlyphGridController {
        GlyphGridController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        c.update(cellSize: CGFloat(cellSize), preview: preview)
        c.update(face: face, entries: entries, version: entriesVersion)
        c.update(selection: selection)
    }
}

@MainActor
final class GlyphGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
    static let spacing: CGFloat = 6
    static let renderResumeDelay: Duration = .milliseconds(150)
    /// Intervals "Glyph grid reload" and "Glyph grid resize" (Instruments ▸ os_signpost, subsystem local.fontory.app).
    static let signposter = OSSignposter(subsystem: "local.fontory.app", category: "characters")

    private let model: AppModel
    private let pipeline: GlyphPipeline
    private(set) var collectionView: GlyphCollectionView!
    private let layout = GlyphGridLayout()
    private let promiseWriter = GlyphPromiseWriter()

    private var face: GlyphFace?
    private var entries: [GlyphEntry] = []
    private var version = -1
    private var cellSize: CGFloat = 0
    private var preview = PreviewSettings()
    private var selection: UInt32?
    private var applyingSelection = false
    private var renderSuspended = false
    private var resumeTask: Task<Void, Never>?
    var onSelect: ((GlyphEntry?) -> Void)?

    init(model: AppModel) {
        self.model = model
        pipeline = model.glyphPipeline
        super.init()
        pipeline.addRenderObserver(self) { [weak self] key, image in self?.rendered(key, image) }
    }

    func makeScrollView() -> NSScrollView {
        layout.spacing = Self.spacing
        layout.inset = Self.spacing * 2

        let cv = GlyphCollectionView()
        cv.controller = self
        cv.collectionViewLayout = layout
        cv.register(GlyphGridItem.self, forItemWithIdentifier: GlyphGridItem.identifier)
        cv.isSelectable = true
        cv.allowsMultipleSelection = false
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        cv.setAccessibilityLabel("Characters")
        collectionView = cv

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    // MARK: Updates from SwiftUI

    func update(face newFace: GlyphFace, entries newEntries: [GlyphEntry], version newVersion: Int) {
        guard newFace != face || newVersion != version else { return }
        let faceChanged = newFace != face
        face = newFace
        entries = newEntries
        version = newVersion
        pipeline.cancelAll()
        let state = Self.signposter.beginInterval("Glyph grid reload", "\(newEntries.count) glyphs")
        collectionView.reloadData()
        collectionView.layoutSubtreeIfNeeded()
        Self.signposter.endInterval("Glyph grid reload", state)
        applySelection(scroll: false)
        if faceChanged || selectedIndex == nil { collectionView.scroll(.zero) } else { scrollSelectionToVisible() }
    }

    func update(cellSize newSize: CGFloat, preview newPreview: PreviewSettings) {
        guard newSize != cellSize || newPreview != preview else { return }
        let sizeChanged = newSize != cellSize && cellSize != 0
        cellSize = newSize
        preview = newPreview
        let itemSize = GlyphGridItem.itemSize(cellSize: newSize)
        if layout.itemSize != itemSize {
            let state = Self.signposter.beginInterval("Glyph grid resize", "\(self.entries.count) glyphs")
            layout.itemSize = itemSize
            collectionView.layoutSubtreeIfNeeded()
            Self.signposter.endInterval("Glyph grid resize", state)
        }
        pipeline.cancelAll()
        // Slider drags: cells keep their image scaled; renders resume once the size settles.
        if sizeChanged { suspendRendering() }
        reconfigureVisible()
    }

    func update(selection new: UInt32?) {
        guard new != selection else { return }
        selection = new
        applySelection(scroll: true)
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return entries.firstIndex { $0.id == selection }
    }

    private func applySelection(scroll: Bool) {
        let wanted: Set<IndexPath> = selectedIndex.map { [IndexPath(item: $0, section: 0)] } ?? []
        guard wanted != collectionView.selectionIndexPaths else { return }
        applyingSelection = true
        collectionView.selectionIndexPaths = wanted
        applyingSelection = false
        if scroll { scrollSelectionToVisible() }
    }

    private func scrollSelectionToVisible() {
        guard let i = selectedIndex else { return }
        collectionView.scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    // MARK: Rendering

    private func suspendRendering() {
        renderSuspended = true
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: GlyphGridController.renderResumeDelay)
            guard !Task.isCancelled, let self else { return }
            self.renderSuspended = false
            self.reconfigureVisible()
        }
    }

    func settingsChanged() {
        pipeline.cancelAll()
        reconfigureVisible()
    }

    private func reconfigureVisible() {
        for ip in collectionView.indexPathsForVisibleItems() {
            if let item = collectionView.item(at: ip) as? GlyphGridItem { configure(item, at: ip.item) }
        }
    }

    private func key(for entry: GlyphEntry, face: GlyphFace) -> GlyphPipeline.Key {
        let scale = collectionView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let side = GlyphGridItem.glyphSide(cellSize: cellSize)
        let style = GlyphCellStyle(size: CGSize(width: side, height: side), scale: scale,
                                   foreground: preview.foreground, background: preview.background)
        let pointSize = face.cellPointSize(side)
        return GlyphPipeline.Key(faceID: face.faceID, glyph: entry.glyphID, pointSize: pointSize, box: face.box, style: style)
    }

    private func configure(_ item: GlyphGridItem, at index: Int) {
        guard let face, entries.indices.contains(index), cellSize > 0 else { return }
        let entry = entries[index]
        let key = key(for: entry, face: face)
        item.configure(entry: entry, key: key, cellSize: cellSize, background: preview.background)
        if let image = pipeline.image(for: key) {
            item.show(image)
        } else if !renderSuspended {
            pipeline.request(key, fileURL: face.fileURL, faceIndex: face.faceIndex)
        }
    }

    private func requestRender(at index: Int) {
        guard let face, entries.indices.contains(index), cellSize > 0, !renderSuspended else { return }
        pipeline.request(key(for: entries[index], face: face), fileURL: face.fileURL, faceIndex: face.faceIndex)
    }

    private func rendered(_ key: GlyphPipeline.Key, _ image: CGImage) {
        guard key.faceID == face?.faceID else { return }
        for ip in collectionView.indexPathsForVisibleItems() {
            if let item = collectionView.item(at: ip) as? GlyphGridItem, item.wantedKey == key { item.show(image) }
        }
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GlyphGridItem.identifier, for: indexPath) as! GlyphGridItem
        configure(item, at: indexPath.item)
        return item
    }

    // MARK: NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if let item = item as? GlyphGridItem { configure(item, at: indexPath.item) }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        // A reused cell may already show the same glyph elsewhere: cancel only when no visible cell wants it.
        guard let key = (item as? GlyphGridItem)?.wantedKey else { return }
        let stillWanted = collectionView.visibleItems().contains { $0 !== item && ($0 as? GlyphGridItem)?.wantedKey == key }
        if !stillWanted { pipeline.cancel(key) }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        pushSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        pushSelection()
    }

    private func pushSelection() {
        guard !applyingSelection else { return }
        let entry = collectionView.selectionIndexPaths.first.flatMap { entries.indices.contains($0.item) ? entries[$0.item] : nil }
        selection = entry?.id
        onSelect?(entry)
    }

    // MARK: NSCollectionViewPrefetching

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for ip in indexPaths { requestRender(at: ip.item) }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        guard let face else { return }
        for ip in indexPaths where entries.indices.contains(ip.item) { pipeline.cancel(key(for: entries[ip.item], face: face)) }
    }

    // MARK: Drag and copy

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    /// An SVG file promise, plus the character as plain text. A glyph without an outline, or of a colour or bitmap
    /// face, drags only its character, and not at all when it has none.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let face, entries.indices.contains(indexPath.item) else { return nil }
        let entry = entries[indexPath.item]
        guard let svg = svg(of: entry, face: face) else {
            return entry.isMapped ? entry.character as NSString : nil
        }
        let provider = GlyphPromiseProvider(fileType: UTType.svg.identifier, delegate: promiseWriter)
        provider.character = entry.character
        provider.userInfo = GlyphPromiseProvider.Payload(fileName: GlyphExport.fileName(entry, face: face), svg: svg)
        return provider
    }

    func svg(of entry: GlyphEntry, face: GlyphFace) -> String? {
        model.previewRenderer.font(fileURL: face.fileURL, faceIndex: face.faceIndex, pointSize: 1)
            .flatMap { GlyphSVG.exportDocument(font: $0, glyph: entry.glyphID) }
    }

    var selectedEntry: GlyphEntry? {
        selectedIndex.map { entries[$0] }
    }

    /// ⌘C: the character; for an unmapped glyph the glyph image (PNG + SVG, rendered off the main thread); a beep
    /// when there is neither.
    func copySelection() {
        guard let entry = selectedEntry, let face else { return NSSound.beep() }
        if entry.isMapped {
            GlyphExport.copyCharacter(entry)
            return
        }
        let renderer = model.previewRenderer
        let glyph = entry.glyphID
        // copyGlyphAsync beeps when it writes nothing.
        Task {
            await GlyphExport.copyGlyphAsync(font: {
                renderer.font(fileURL: face.fileURL, faceIndex: face.faceIndex, pointSize: 1)
            }, glyph: glyph)
        }
    }
}

/// The grid's collection view: Copy (⌘C) and the keyboard focus when it appears.
final class GlyphCollectionView: NSCollectionView {
    weak var controller: GlyphGridController?

    private var claimedFocus = false

    /// The first time the tab is shown, the grid takes the keyboard (arrows, ⌘C), unless a text field is editing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !claimedFocus else { return }
        claimedFocus = true
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(self)
        }
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.settingsChanged()
    }
}

extension GlyphCollectionView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return controller?.selectedEntry != nil }
        return true
    }
}

/// One glyph cell: the rendered glyph and, when there is room, a caption (the code point, or the glyph name for
/// an unmapped glyph).
final class GlyphGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GlyphGridItem")
    static let captionHeight: CGFloat = 16
    /// Below this cell size the caption is left out.
    static let captionMinCell: CGFloat = 56

    static func itemSize(cellSize: CGFloat) -> CGSize {
        CGSize(width: floor(cellSize), height: floor(cellSize) + (cellSize >= captionMinCell ? captionHeight : 0))
    }

    static func glyphSide(cellSize: CGFloat) -> CGFloat { floor(cellSize) }

    private(set) var wantedKey: GlyphPipeline.Key?
    private let glyphLayer = CALayer()
    private let caption = NSTextField(labelWithString: "")
    private var hasCaption = true

    override func loadView() {
        let root = GlyphCellView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 5
        root.layer?.masksToBounds = true
        glyphLayer.contentsGravity = .resizeAspect
        glyphLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        root.layer?.addSublayer(glyphLayer)
        caption.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        root.addSubview(caption)
        root.onLayout = { [weak self] in self?.layoutParts() }
        view = root
    }

    private func layoutParts() {
        let b = view.bounds
        let captionHeight = hasCaption ? Self.captionHeight : 0
        glyphLayer.frame = CGRect(x: 0, y: 0, width: b.width, height: max(1, b.height - captionHeight))
        caption.frame = CGRect(x: 2, y: b.height - captionHeight + 1, width: max(0, b.width - 4), height: max(0, captionHeight - 2))
        caption.isHidden = !hasCaption
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    func configure(entry: GlyphEntry, key: GlyphPipeline.Key, cellSize: CGFloat, background: CGColor) {
        if wantedKey?.faceID != key.faceID || wantedKey?.glyph != key.glyph { glyphLayer.contents = nil }
        wantedKey = key
        view.layer?.backgroundColor = background
        let showCaption = cellSize >= Self.captionMinCell
        if showCaption != hasCaption { hasCaption = showCaption; view.needsLayout = true }
        caption.stringValue = entry.scalarValue.map { String(format: "%04X", $0) } ?? (entry.glyphName ?? "#\(entry.glyphID)")
        view.toolTip = GlyphExport.title(entry)
        view.setAccessibilityLabel(GlyphExport.title(entry))
        updateSelection()
    }

    func show(_ image: CGImage) {
        glyphLayer.contents = image
    }
}

private final class GlyphCellView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: Export

/// Copy and drag helpers shared by the grid and the inspector.
@MainActor
enum GlyphExport {
    /// "U+00E4 LATIN SMALL LETTER A WITH DIAERESIS", or the glyph name of an unmapped glyph.
    static func title(_ entry: GlyphEntry) -> String {
        if let code = entry.codePointLabel { return [code, entry.unicodeName].compactMap { $0 }.joined(separator: " ") }
        return entry.glyphName.map { "Glyph \(entry.glyphID) (\($0))" } ?? "Glyph \(entry.glyphID)"
    }

    /// "Arial-BoldMT adieresis.svg": the PostScript name and the glyph name (or uniXXXX / glyph ID).
    static func fileName(_ entry: GlyphEntry, face: GlyphFace) -> String {
        fileName(postScriptName: face.postScriptName, glyphName: entry.glyphName, scalar: entry.scalarValue,
                 glyph: entry.glyphID, extension: "svg")
    }

    /// "PostScriptName glyphname.ext": the glyph name, else uniXXXX of its scalar, else glyph<ID>.
    static func fileName(postScriptName: String, glyphName: String?, scalar: UInt32?, glyph: CGGlyph,
                         extension ext: String) -> String {
        let name = glyphName.flatMap { $0.isEmpty ? nil : $0 }
            ?? scalar.map { String(format: "uni%04X", $0) } ?? "glyph\(glyph)"
        let base = [postScriptName, name].filter { !$0.isEmpty }.joined(separator: " ")
        let safe = base.map { "/:\\".contains($0) ? "-" : $0 }
        return String(safe.prefix(200)) + "." + ext
    }

    static func copyCharacter(_ entry: GlyphEntry) {
        guard entry.isMapped else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.character, forType: .string)
    }

    static let svgType = NSPasteboard.PasteboardType(UTType.svg.identifier)

    /// The glyph as a PNG and as an SVG (public.svg-image), and no plain text: a design app pastes text in preference
    /// to an image, so the clipboard offers images only. A colour or bitmap face gives the full-colour PNG only.
    /// False (nothing written) when the glyph has neither.
    @discardableResult
    static func copyGlyph(font: CTFont, glyph: CGGlyph, to pasteboard: NSPasteboard = .general) -> Bool {
        write(png: GlyphImage.png(font: font, glyph: glyph), svg: GlyphSVG.exportDocument(font: font, glyph: glyph),
              to: pasteboard)
    }

    /// Writes already-rendered data; the UI renders off the main thread and calls this afterwards.
    @discardableResult
    static func write(png: Data?, svg: String?, to pasteboard: NSPasteboard = .general) -> Bool {
        guard png != nil || svg != nil else { return false }
        var types: [NSPasteboard.PasteboardType] = []
        if png != nil { types.append(.png) }
        if svg != nil { types.append(svgType) }
        pasteboard.declareTypes(types, owner: nil)
        if let png { pasteboard.setData(png, forType: .png) }
        if let svg { pasteboard.setData(Data(svg.utf8), forType: svgType) }
        return true
    }

    /// The SVG as plain text only (for code editors).
    @discardableResult
    static func copySVGCode(_ svg: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(svg, forType: .string)
    }

    /// Copy Glyph for the UI: renders the PNG and SVG off the main thread, then writes; beeps when there is neither.
    @discardableResult
    static func copyGlyphAsync(font: @escaping @Sendable () -> CTFont?, glyph: CGGlyph,
                               to pasteboard: NSPasteboard = .general) async -> Bool {
        let rendered = await Task.detached(priority: .userInitiated) { () -> (Data?, String?) in
            guard let font = font() else { return (nil, nil) }
            return (GlyphImage.png(font: font, glyph: glyph), GlyphSVG.exportDocument(font: font, glyph: glyph))
        }.value
        let wrote = write(png: rendered.0, svg: rendered.1, to: pasteboard)
        if !wrote { NSSound.beep() }
        return wrote
    }
}

/// A dragged glyph: an SVG (or PNG) file promise, and the character as plain text when `character` is set.
final class GlyphPromiseProvider: NSFilePromiseProvider {
    struct Payload {
        let fileName: String
        /// The file's bytes, made when the drop asks for them (on the writer's background queue).
        let contents: @Sendable () -> Data?

        init(fileName: String, svg: String) {
            self.fileName = fileName
            let data = Data(svg.utf8)
            contents = { data }
        }

        init(fileName: String, contents: @escaping @Sendable () -> Data?) {
            self.fileName = fileName
            self.contents = contents
        }
    }

    var character = ""

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if !character.isEmpty { types.append(.string) }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string { return character }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Writes promised SVG and PNG files, off the main thread (a PNG renders when the drop asks for it).
final class GlyphPromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? GlyphPromiseProvider.Payload)?.fileName ?? "Glyph.svg"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let data = (filePromiseProvider.userInfo as? GlyphPromiseProvider.Payload)?.contents() else {
            return completionHandler(CocoaError(.fileWriteUnknown))
        }
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
