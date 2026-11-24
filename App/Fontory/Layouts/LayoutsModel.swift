import AppKit
import FontoryCore
import Observation
import OSLog

/// The Layouts window's state: the layout and template lists, the open document with its undo stack and autosave,
/// the font resolutions it needs and the rendered page. Files go through `LayoutLibrary`; resolution and rendering
/// run off the main thread.
@Observable @MainActor
final class LayoutsModel {
    nonisolated static let windowID = "layouts"
    static let autosaveDelay: Duration = .seconds(1)
    static let undoLimit = 200
    static let coalesceInterval: Duration = .seconds(1)
    static let zoomRange: ClosedRange<CGFloat> = 0.05...8
    static let zoomStep: CGFloat = 1.25
    /// The largest bitmap side the canvas renders, in pixels.
    static let maxRenderPixels: CGFloat = 8192

    // MARK: Files

    let layoutsDirectory: URL
    let templatesDirectory: URL
    @ObservationIgnored let library: LayoutLibrary
    /// The user's layouts (unreadable files included, with their error), sorted by name.
    var items: [LayoutLibrary.Item] = []
    /// The templates, built-ins first in bundle order.
    var templates: [LayoutLibrary.Item] = []
    /// The last failure, shown as an alert by the window.
    var errorMessage: String?
    /// Moves one file to the Trash: its new URL, or an error message. The smoke run replaces it with a fake.
    @ObservationIgnored var recycle: @MainActor (URL) async -> (trashedURL: URL?, error: String?) = { await AppModel.workspaceRecycle($0) }

    // MARK: Document

    var current: LayoutDocument?
    var currentURL: URL?
    /// The open layout has changes not yet written.
    var isDirty = false
    /// The selected block (the canvas overlay draws it; the inspector shows it).
    var selectedBlockID: UUID?
    /// The in-place text editor is open (its text is not in `current` yet). Undo/Redo Layout Edit are disabled.
    var isEditingText = false
    /// Commits the in-place editor's text into `current` and closes it; set by the canvas while editing. Called
    /// before anything saves or replaces the document, so typed text is never lost.
    @ObservationIgnored var commitPendingTextEdit: (() -> Void)?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// The open layout's candidate families, in order.
    var candidates: [FontReference] { current?.candidates ?? [] }
    @ObservationIgnored private var undoStack: [LayoutDocument] = []
    @ObservationIgnored private var redoStack: [LayoutDocument] = []
    /// The document before the live edit in progress (a drag), registered as one undo step when it ends.
    @ObservationIgnored private var liveEditBase: LayoutDocument?
    /// The key and time of the last coalescing edit (e.g. the colour panel); a repeat soon after adds no undo step.
    @ObservationIgnored private var lastCoalesced: (key: String, time: ContinuousClock.Instant)?
    /// Bumped by every change of `current`; a save clears `isDirty` only if nothing changed since its snapshot.
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// The last write; each write waits for the previous one, so they land in order.
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    // MARK: Fonts and rendering

    /// Where references resolve; nil until the library is open (blocks then draw in the system font).
    @ObservationIgnored var fontStore: @MainActor () -> FontStore? = { nil }
    /// Resolutions of the open layout's references (blocks and candidates), filled off the main thread.
    @ObservationIgnored private(set) var resolved: [FontReference: ResolvedFont] = [:]
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderGeneration = 0
    /// The page bitmap at `renderedScale` pixels per page point.
    var renderedImage: CGImage?
    @ObservationIgnored private(set) var renderedScale: CGFloat = 0
    var report = LayoutRenderReport()

    // MARK: Pairing Studio

    /// Family styles by lowercased family (cycling, closest style), filled off the main thread.
    @ObservationIgnored var familyStyleCache: [String: [PairingStyle]] = [:]
    /// Bumped when the caches are cleared, so a lookup started before is not stored.
    @ObservationIgnored var pairingCacheGeneration = 0
    /// The strip's family-name images drawn in their real fonts, by reference and size. (A missing font's image is
    /// not kept, so it is drawn again once the font is back.)
    @ObservationIgnored var candidateImageCache: [CandidateImageKey: CGImage] = [:]
    /// Bumped when fonts are resolved again (the strip asks for its images again).
    var fontsVersion = 0
    /// Cycling and candidate changes run one after another, each on the result of the one before (quick repeats).
    @ObservationIgnored var pairingChain: Task<Void, Never>?

    // MARK: Export

    /// Set while a long PDF export (more than 10 pages) runs; the window shows a progress sheet with Cancel.
    var exportProgress: ExportProgress?
    /// The smoke run's stand-in for the save panels: the destination used without asking.
    @ObservationIgnored var exportDestinationOverride: URL?
    /// Smoke only: seconds to wait after each page, so a cancel can land mid-export.
    @ObservationIgnored var exportPageDelay: TimeInterval = 0
    @ObservationIgnored var exportJob: Task<Void, Error>?

    // MARK: Zoom

    /// The explicit zoom (view points per page point), used when `zoomsToFit` is off.
    var zoom: CGFloat = 1
    var zoomsToFit = true
    /// The zoom that fits the page in the canvas, reported by the canvas.
    var fitZoom: CGFloat = 0.5
    /// The canvas window's backing scale.
    @ObservationIgnored var backingScale: CGFloat = 2
    var effectiveZoom: CGFloat { zoomsToFit ? fitZoom : zoom }

    // MARK: Window

    /// The Layouts window, recorded by `LayoutsWindow`; shortcuts act on it only while it is key.
    @ObservationIgnored weak var window: NSWindow?
    var windowIsKey: Bool { window != nil && NSApp.keyWindow === window }
    /// Observable copy of `windowIsKey`, for menu items.
    var isKey = false

    nonisolated static let log = Logger(subsystem: "local.fontory.app", category: "layouts")

    init(layoutsDirectory: URL, templatesDirectory: URL) {
        self.layoutsDirectory = layoutsDirectory
        self.templatesDirectory = templatesDirectory
        library = LayoutLibrary(layoutsDirectory: layoutsDirectory, templatesDirectory: templatesDirectory)
    }

    /// `~/Library/Application Support/Fontory/<name>` (the path only; nothing is created).
    nonisolated static func defaultDirectory(_ name: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Fontory/\(name)", isDirectory: true)
    }

    // MARK: Lists

    /// Copies the bundled templates (`Contents/Resources/Templates`) into the templates folder once, then lists.
    func installBuiltInTemplates(from bundleDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Templates", isDirectory: true)) async {
        if let bundleDirectory {
            let library = library
            let result = await Task.detached(priority: .utility) { Result { try library.installBuiltInTemplates(from: bundleDirectory) } }.value
            if case .failure(let error) = result {
                Self.log.error("installing templates failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await reloadLists()
    }

    func reloadLists() async {
        let library = library
        let (layouts, templates) = await Task.detached(priority: .userInitiated) {
            (library.listLayouts(), library.listTemplates())
        }.value
        items = layouts
        self.templates = templates
    }

    // MARK: Open, new, duplicate, rename, delete

    /// Opens a layout, saving the one open before.
    func open(_ url: URL) async {
        commitPendingText()
        if url.standardizedFileURL == currentURL?.standardizedFileURL, current != nil { return }
        await flush()
        let library = library
        let result = await Task.detached(priority: .userInitiated) { Result { try library.load(url) } }.value
        switch result {
        case .success(let doc):
            closeCurrent()
            current = doc
            currentURL = url
            resolved = [:]
            refreshRender()
        case .failure(let error):
            errorMessage = "“\(url.deletingPathExtension().lastPathComponent)” could not be opened. \(error.localizedDescription)"
        }
    }

    /// A new layout from a template, named after it (“Poster”, then “Poster 2”…), opened.
    func newLayout(from template: URL) async {
        await createAndOpen { try $0.newLayout(from: template) }
    }

    /// A copy of a layout beside it (“Poster 2”…), opened.
    func duplicate(_ url: URL) async {
        await flush()
        await createAndOpen { try $0.duplicate(url) }
    }

    func rename(_ url: URL, to name: String) async {
        commitPendingText()
        let isCurrent = url.standardizedFileURL == currentURL?.standardizedFileURL
        if isCurrent { await flush() }
        let library = library
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result {
                let dest = try library.rename(url, to: name)
                // The document's name follows its file name.
                var doc = try library.load(dest)
                doc.name = dest.deletingPathExtension().lastPathComponent
                try library.save(doc, to: dest)
                return dest
            }
        }.value
        switch result {
        case .success(let dest):
            if isCurrent {
                let newName = dest.deletingPathExtension().lastPathComponent
                currentURL = dest
                current?.name = newName
                undoStack = undoStack.map { var d = $0; d.name = newName; return d }
                redoStack = redoStack.map { var d = $0; d.name = newName; return d }
            }
        case .failure(LayoutLibrary.LibraryError.nameTaken(let taken)):
            errorMessage = "A layout named “\(taken)” already exists."
        case .failure(LayoutLibrary.LibraryError.invalidName):
            errorMessage = "“\(name)” can't be used as a layout name."
        case .failure(let error):
            errorMessage = "The layout could not be renamed. \(error.localizedDescription)"
        }
        await reloadLists()
    }

    /// Moves a layout file to the Trash (through `recycle`); the open layout is closed first.
    func delete(_ url: URL) async {
        commitPendingText()
        if url.standardizedFileURL == currentURL?.standardizedFileURL {
            // Pending writes finish first so none recreates the file after it is trashed.
            autosaveTask?.cancel()
            autosaveTask = nil
            isDirty = false
            await writeChain?.value
            closeCurrent()
            current = nil
            currentURL = nil
        }
        let outcome = await recycle(url)
        if let error = outcome.error { errorMessage = "The layout could not be moved to the Trash. \(error)" }
        await reloadLists()
    }

    private func createAndOpen(_ make: @escaping @Sendable (LayoutLibrary) throws -> URL) async {
        commitPendingText()
        let library = library
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result {
                let url = try make(library)
                var doc = try library.load(url)
                doc.name = url.deletingPathExtension().lastPathComponent
                try library.save(doc, to: url)
                return url
            }
        }.value
        switch result {
        case .success(let url):
            await reloadLists()
            await open(url)
        case .failure(let error):
            errorMessage = "The layout could not be created. \(error.localizedDescription)"
            await reloadLists()
        }
    }

    /// Applies the in-place editor's text to the document it was opened on (before that document is saved or
    /// replaced).
    func commitPendingText() {
        guard let commit = commitPendingTextEdit else { return }
        commitPendingTextEdit = nil
        commit()
    }

    /// Forgets the open document's session state (undo, selection, render).
    private func closeCurrent() {
        commitPendingText()
        undoStack = []
        redoStack = []
        liveEditBase = nil
        lastCoalesced = nil
        selectedBlockID = nil
        renderTask?.cancel()
        renderTask = nil
        renderGeneration += 1
        renderedImage = nil
        renderedScale = 0
        report = LayoutRenderReport()
        isDirty = false
    }

    // MARK: Editing

    /// Changes the open document. An undoable change is one undo step; a change that leaves the document equal is
    /// ignored. Marks the layout dirty, schedules the autosave and re-renders. Undoable changes with the same
    /// `coalescing` key less than `coalesceInterval` apart share one undo step (a colour dragged in the colour panel).
    func apply(_ edit: (inout LayoutDocument) -> Void, undoable: Bool = true, coalescing: String? = nil) {
        guard let before = current else { return }
        var after = before
        edit(&after)
        guard after != before else { return }
        if undoable {
            let now = ContinuousClock.now
            let merges = coalescing != nil && lastCoalesced?.key == coalescing && !undoStack.isEmpty
                && lastCoalesced.map { now - $0.time < Self.coalesceInterval } == true
            if !merges {
                undoStack.append(before)
                if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            }
            redoStack = []
            lastCoalesced = coalescing.map { ($0, now) }
        } else {
            // Keep the change across undo/redo: replay it on every stored state.
            undoStack = undoStack.map { var d = $0; edit(&d); return d }
            redoStack = redoStack.map { var d = $0; edit(&d); return d }
            if let base = liveEditBase { var d = base; edit(&d); liveEditBase = d }
        }
        replaceCurrent(with: after)
    }

    /// Starts a live edit (a drag): `applyLive` changes then show at once, and `endLiveEdit` registers them as one
    /// undo step.
    func beginLiveEdit() {
        if liveEditBase != nil { endLiveEdit() }
        liveEditBase = current
    }

    /// An intermediate change of the live edit: shown and saved, but not an undo step of its own.
    func applyLive(_ edit: (inout LayoutDocument) -> Void) {
        guard var doc = current else { return }
        if liveEditBase == nil { liveEditBase = doc }
        edit(&doc)
        guard doc != current else { return }
        replaceCurrent(with: doc)
    }

    /// Ends the live edit: one undo step back to where it began, if anything changed.
    func endLiveEdit() {
        guard let base = liveEditBase else { return }
        liveEditBase = nil
        guard let doc = current, doc != base else { return }
        undoStack.append(base)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack = []
        lastCoalesced = nil
    }

    func undo() {
        endLiveEdit()
        lastCoalesced = nil
        guard let doc = current, let previous = undoStack.popLast() else { return }
        redoStack.append(doc)
        replaceCurrent(with: previous)
    }

    func redo() {
        endLiveEdit()
        lastCoalesced = nil
        guard let doc = current, let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        replaceCurrent(with: next)
    }

    private func replaceCurrent(with doc: LayoutDocument) {
        current = doc
        if let id = selectedBlockID, !doc.blocks.contains(where: { $0.id == id }) { selectedBlockID = nil }
        changeCount += 1
        isDirty = true
        scheduleAutosave()
        refreshRender()
    }

    // MARK: Autosave

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: LayoutsModel.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.autosaveTask = nil
            self.saveNow()
        }
    }

    /// Starts writing the open document if it has unsaved changes.
    private func saveNow() {
        guard isDirty, let doc = current, let url = currentURL else { return }
        let snapshot = changeCount
        let library = library
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) { Result { try library.save(doc, to: url) } }.value
            guard let self else { return }
            switch result {
            case .success:
                if self.changeCount == snapshot, self.currentURL == url { self.isDirty = false }
            case .failure(let error):
                Self.log.error("saving the layout failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "The layout could not be saved. \(error.localizedDescription)"
            }
        }
    }

    /// Writes pending changes now and waits for every write (window close, switching layouts, quit).
    func flush() async {
        commitPendingText()
        if autosaveTask != nil {
            autosaveTask?.cancel()
            autosaveTask = nil
        }
        saveNow()
        await writeChain?.value
    }

    // MARK: Rendering

    private static func references(of doc: LayoutDocument?) -> Set<FontReference> {
        guard let doc else { return [] }
        return Set(doc.blocks.map(\.font)).union(doc.candidates)
    }

    /// The bitmap scale for the current zoom: whole quarters, capped so the bitmap stays bounded.
    private func targetScale(for doc: LayoutDocument) -> CGFloat {
        let raw = max(0.25, effectiveZoom * backingScale)
        let quantized = (raw * 4).rounded(.up) / 4
        let cap = Self.maxRenderPixels / CGFloat(max(1, doc.pageSize.w, doc.pageSize.h))
        return max(0.05, min(quantized, cap))
    }

    /// Re-renders after the zoom changed, when the bitmap scale it needs differs.
    func zoomChanged() {
        guard let doc = current, targetScale(for: doc) != renderedScale else { return }
        refreshRender()
    }

    /// Re-resolves every reference (the library may have changed, e.g. a drive came back) and re-renders.
    func refreshFonts() {
        clearPairingCaches()
        fontsVersion += 1
        guard current != nil else { return }
        resolved = [:]
        refreshRender()
    }

    /// Resolves references not yet resolved (off the main thread), then renders off the main thread. A newer call
    /// supersedes an older one; a superseded render's result is dropped.
    private func refreshRender() {
        guard let doc = current else { return }
        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let scale = targetScale(for: doc)
        let store = fontStore()
        let known = resolved
        let wanted = Self.references(of: doc)
        renderTask = Task { [weak self] in
            var fonts = known
            let missing = wanted.subtracting(known.keys)
            if let store, !missing.isEmpty {
                let refs = Array(missing)
                let found = await Task.detached(priority: .userInitiated) { try? store.resolve(refs) }.value ?? [:]
                guard !Task.isCancelled, let self, generation == self.renderGeneration else { return }
                fonts.merge(found) { _, new in new }
                self.resolved.merge(found) { _, new in new }
            }
            guard !Task.isCancelled else { return }
            let rendered = await Task.detached(priority: .userInitiated) { () -> (CGImage?, LayoutRenderReport)? in
                guard !Task.isCancelled else { return nil }
                let out = LayoutRenderer.renderImage(doc, fonts: fonts, scale: scale)
                return (out.image, out.report)
            }.value
            guard !Task.isCancelled, let self, generation == self.renderGeneration, let rendered else { return }
            self.renderedImage = rendered.0
            self.renderedScale = scale
            if self.report != rendered.1 { self.report = rendered.1 }
            self.renderTask = nil
        }
    }

    // MARK: Zoom

    func zoomIn() { setZoom(effectiveZoom * Self.zoomStep) }
    func zoomOut() { setZoom(effectiveZoom / Self.zoomStep) }

    func zoomToFit() {
        zoomsToFit = true
        zoomChanged()
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        zoomsToFit = false
        zoomChanged()
    }

    /// Called by the canvas when its size or window changes.
    func canvasDidLayout(fitZoom fit: CGFloat, backingScale scale: CGFloat) {
        let fit = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, fit))
        if fit != fitZoom { fitZoom = fit }
        backingScale = scale
        zoomChanged()
    }

    // MARK: Keys

    /// ⌘Z / ⇧⌘Z in the Layouts window: handled here unless a text field is being edited (it keeps its own undo).
    static func handlesUndoKey(windowIsKey: Bool, editingText: Bool) -> Bool {
        windowIsKey && !editingText
    }
}

// MARK: - Block editing

/// What the canvas and the inspector call. Every change goes through `apply` (or a live edit), so undo covers it.
extension LayoutsModel {
    enum Corner: CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

    nonisolated static let minBlockSize: Double = 20
    static let newBlockSize = LayoutSize(w: 300, h: 100)
    nonisolated static let sizeRange: ClosedRange<Double> = 1...2000
    static let lineHeightRange: ClosedRange<Double> = 0.1...10
    static let trackingRange: ClosedRange<Double> = -1000...10000

    var selectedBlock: LayoutBlock? {
        guard let id = selectedBlockID else { return nil }
        return current?.blocks.first { $0.id == id }
    }

    func select(_ id: UUID?) {
        if selectedBlockID != id { selectedBlockID = id }
    }

    /// The topmost block containing a page point (points, origin top-left).
    func blockID(atPage point: CGPoint) -> UUID? {
        current?.blocks.last { b in
            CGRect(x: b.frame.x, y: b.frame.y, width: b.frame.w, height: b.frame.h).contains(point)
        }?.id
    }

    /// Changes one block (one undo step).
    func updateBlock(_ id: UUID, coalescing: String? = nil, _ edit: (inout LayoutBlock) -> Void) {
        apply({ doc in
            guard let i = doc.blocks.firstIndex(where: { $0.id == id }) else { return }
            edit(&doc.blocks[i])
        }, coalescing: coalescing)
    }

    // MARK: Move and resize (live edits between beginLiveEdit and endLiveEdit)

    /// Moves a block to `start` offset by `delta` page points.
    func moveBlock(_ id: UUID, from start: LayoutFrame, by delta: CGSize) {
        setFrameLive(id, LayoutFrame(x: start.x + delta.width, y: start.y + delta.height, w: start.w, h: start.h))
    }

    /// Resizes a block by dragging one corner of `start` by `delta`; the opposite corner stays put.
    func resizeBlock(_ id: UUID, from start: LayoutFrame, corner: Corner, by delta: CGSize) {
        setFrameLive(id, Self.resized(start, corner: corner, by: delta))
    }

    /// `start` with `corner` dragged by `delta`, at least `minBlockSize` on each side.
    nonisolated static func resized(_ start: LayoutFrame, corner: Corner, by delta: CGSize) -> LayoutFrame {
        var minX = start.x, minY = start.y, maxX = start.x + start.w, maxY = start.y + start.h
        switch corner {
        case .topLeft, .bottomLeft: minX = min(minX + delta.width, maxX - minBlockSize)
        case .topRight, .bottomRight: maxX = max(maxX + delta.width, minX + minBlockSize)
        }
        switch corner {
        case .topLeft, .topRight: minY = min(minY + delta.height, maxY - minBlockSize)
        case .bottomLeft, .bottomRight: maxY = max(maxY + delta.height, minY + minBlockSize)
        }
        return LayoutFrame(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    private func setFrameLive(_ id: UUID, _ frame: LayoutFrame) {
        applyLive { doc in
            guard let i = doc.blocks.firstIndex(where: { $0.id == id }) else { return }
            doc.blocks[i].frame = frame
        }
    }

    // MARK: Text and typography

    func setText(_ text: String, for id: UUID) {
        updateBlock(id) { $0.text = text }
    }

    func setSize(_ size: Double, for id: UUID) {
        guard size.isFinite else { return }
        updateBlock(id) { $0.size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size)) }
    }

    func setLineHeight(_ value: Double, for id: UUID) {
        guard value.isFinite else { return }
        updateBlock(id) { $0.lineHeight = min(Self.lineHeightRange.upperBound, max(Self.lineHeightRange.lowerBound, value)) }
    }

    func setTracking(_ value: Double, for id: UUID) {
        guard value.isFinite else { return }
        updateBlock(id) { $0.tracking = min(Self.trackingRange.upperBound, max(Self.trackingRange.lowerBound, value)) }
    }

    func setAlignment(_ alignment: LayoutAlignment, for id: UUID) {
        updateBlock(id) { $0.alignment = alignment }
    }

    /// A `#RRGGBB` colour, or nil for the layout's foreground. Changes to one block in quick succession are one
    /// undo step.
    func setColor(_ hex: String?, for id: UUID) {
        guard hex.map(LayoutColor.isValid) ?? true else { return }
        updateBlock(id, coalescing: "color-\(id.uuidString)") { $0.color = hex }
    }

    /// Sets the waterfall sizes from a comma-separated field; false (and nothing changed) when it doesn't parse.
    @discardableResult
    func setSizes(_ text: String, for id: UUID) -> Bool {
        guard let sizes = Self.parseSizes(text) else { return false }
        updateBlock(id) { $0.sizes = sizes }
        return true
    }

    /// "12, 16, 24" → [12, 16, 24]; nil when empty or when any entry is not a size in `sizeRange`.
    nonisolated static func parseSizes(_ text: String) -> [Double]? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var out: [Double] = []
        for part in parts {
            guard let v = Double(part), v.isFinite, sizeRange.contains(v) else { return nil }
            out.append(v)
        }
        return out
    }

    nonisolated static func formatSizes(_ sizes: [Double]) -> String {
        sizes.map { $0.formatted(.number.grouping(.never)) }.joined(separator: ", ")
    }

    func setShowMissing(_ on: Bool) {
        apply { $0.showMissing = on }
    }

    // MARK: Add and delete

    /// Deletes the selected block (⌫ on the canvas).
    func deleteSelectedBlock() {
        guard let id = selectedBlockID else { return }
        apply { $0.blocks.removeAll { $0.id == id } }
    }

    /// "+ Text Block": a 300 × 100 text block at the page centre, in the selected block's font (else the first
    /// candidate's, else the first block's), selected.
    func addTextBlock() {
        guard let doc = current else { return }
        let size = Self.newBlockSize
        let font = selectedBlock?.font ?? doc.candidates.first ?? doc.blocks.first?.font
            ?? FontReference(postScriptName: "", family: "")
        let block = LayoutBlock(kind: .text,
                                frame: LayoutFrame(x: (doc.pageSize.w - size.w) / 2, y: (doc.pageSize.h - size.h) / 2,
                                                   w: size.w, h: size.h),
                                text: "Text", font: font, size: 24)
        apply { $0.blocks.append(block) }
        selectedBlockID = block.id
    }

    // MARK: Fonts

    /// Sets a block's font (the selected block's by default).
    func setFont(_ ref: FontReference, for id: UUID? = nil) {
        guard let id = id ?? selectedBlockID else { return }
        updateBlock(id) { $0.font = ref }
    }

    /// The styles of `ref`'s family (the style menu), looked up off the main thread.
    func styles(for ref: FontReference?) async -> [PairingStyle] {
        guard let ref, let store = fontStore() else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? store.styles(ofFamilyOf: ref)) ?? [] }.value
    }

    /// Families whose name matches `text` (Choose Font…), through the library search, off the main thread.
    func searchFamilies(_ text: String) async -> [FamilyGroup] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store = fontStore() else { return [] }
        var query = LibraryQuery()
        query.search = SearchText(trimmed, scope: [.name, .family])
        return await Task.detached(priority: .userInitiated) { (try? store.families(for: query)) ?? [] }.value
    }

    /// Choose Font…: the selected block takes the family's representative face.
    func chooseFamily(_ group: FamilyGroup) async {
        guard let id = selectedBlockID, let store = fontStore() else { return }
        let faceID = group.representativeID
        guard let ref = await Task.detached(priority: .userInitiated, operation: { try? store.reference(forFace: faceID) }).value
        else { return }
        setFont(ref, for: id)
    }

    /// A candidate from the family menu or the strip: the selected block takes that family's style closest to its
    /// current one (the candidate's own face when the current style is unknown).
    func applyCandidate(_ candidate: FontReference) async {
        enqueuePairing { model in
            guard let id = model.selectedBlockID, let currentFont = model.selectedBlock?.font else { return }
            let chosen = await model.closestStyle(in: candidate, to: currentFont)
            model.setFont(chosen, for: id)
        }
        await waitForPairing()
    }

    /// The block's font at `size` for the in-place editor, loaded off the main thread; nil when it is missing.
    func editorFont(for block: LayoutBlock, size: CGFloat) async -> NSFont? {
        guard let resolved = resolved[block.font], !resolved.isMissing, let url = resolved.url else { return nil }
        let faceIndex = resolved.faceIndex
        let variations = block.font.variations ?? [:]
        let box = await Task.detached(priority: .userInitiated) { () -> FontBox? in
            Self.loadFont(url: url, faceIndex: faceIndex, size: size, variations: variations).map(FontBox.init)
        }.value
        return box.map { $0.font as NSFont }
    }

    /// A face from its file at `size`, with variation axis values applied.
    nonisolated static func loadFont(url: URL, faceIndex: Int, size: CGFloat, variations: [String: Double]) -> CTFont? {
        guard let base = FontFile.font(at: url, faceIndex: faceIndex, size: size) else { return nil }
        guard !variations.isEmpty else { return base }
        let values = Dictionary(variations.map { (NSNumber(value: VariationInfo.code($0.key)), NSNumber(value: $0.value)) },
                                uniquingKeysWith: { a, _ in a })
        let attributes = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: values] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, attributes)
    }

    // MARK: Report notes

    /// "N characters missing" for a block, from the last render.
    func missingCharacters(in id: UUID) -> Int {
        report.missingCharacters[id.uuidString] ?? 0
    }

    /// "Missing font" for a block, from the last render.
    func isFontMissing(_ id: UUID) -> Bool {
        report.missingFontBlockIDs.contains(id.uuidString)
    }
}

/// A CTFont handed back from a background load (CoreText fonts are immutable and thread-safe).
private struct FontBox: @unchecked Sendable {
    let font: CTFont
}

// MARK: - Pairing Studio

/// ⌘K candidates, cycling (←/→ families, ↑/↓ styles) on the selected block, Apply to All Blocks and the strip.
/// Store lookups run off the main thread; every change goes through `apply`, so each is one undo step.
extension LayoutsModel {
    enum CycleKey: Equatable, Sendable {
        case family(Int)
        case style(Int)
    }

    struct CandidateImageKey: Hashable {
        var reference: FontReference
        var pointSize: CGFloat
        var scale: CGFloat
    }

    /// What an arrow key does on the canvas: ←/→ the previous/next family, ↑/↓ the previous/next style.
    nonisolated static func cycleKey(keyCode: UInt16) -> CycleKey? {
        switch keyCode {
        case 123: .family(-1)
        case 124: .family(1)
        case 126: .style(-1)
        case 125: .style(1)
        default: nil
        }
    }

    /// ⌘K: with no candidates the families of `faceIDs` become the candidates; otherwise the families not listed
    /// yet are appended (one candidate per family, its representative face).
    func addCandidates(faceIDs: [Int64]) async {
        guard current != nil, !faceIDs.isEmpty, let store = fontStore() else { return }
        let url = currentURL
        let refs = await Task.detached(priority: .userInitiated) { (try? store.candidateReferences(faceIDs: faceIDs)) ?? [] }.value
        // Dropped when another layout was opened meanwhile.
        guard !refs.isEmpty, currentURL == url else { return }
        apply { $0.candidates = PairingCycler.merge($0.candidates, adding: refs) }
    }

    /// ⌫ on the strip: removes the candidate's family.
    func removeCandidate(_ ref: FontReference) {
        let key = ref.family.lowercased()
        apply { $0.candidates.removeAll { $0.family.lowercased() == key } }
    }

    /// ←/→: the selected block takes the previous/next candidate family, in its style closest to the current one.
    func cycleFamily(step: Int) {
        enqueuePairing { model in
            guard let id = model.selectedBlockID, let font = model.selectedBlock?.font,
                  let family = PairingCycler.nextFamily(from: font, candidates: model.candidates, step: step) else { return }
            let chosen = await model.closestStyle(in: family, to: font)
            // Dropped when the block changed meanwhile (an undo while the styles were looked up).
            guard model.current?.blocks.first(where: { $0.id == id })?.font == font else { return }
            model.setFont(chosen, for: id)
        }
    }

    /// ↑/↓: the selected block takes the previous/next style of its family (named instances included), wrapping.
    func cycleStyle(step: Int) {
        enqueuePairing { model in
            guard let id = model.selectedBlockID, let font = model.selectedBlock?.font else { return }
            let styles = await model.familyStyles(of: font)
            let next = PairingCycler.nextStyle(current: font, styles: styles, step: step)
            guard next != font, model.current?.blocks.first(where: { $0.id == id })?.font == font else { return }
            model.setFont(next, for: id)
        }
    }

    /// Apply to All Blocks: each block takes the family's style closest to its current style (one undo step).
    func applyFamilyToAll(_ ref: FontReference) async {
        enqueuePairing { model in
            guard let doc = model.current else { return }
            var chosen: [UUID: FontReference] = [:]
            for block in doc.blocks { chosen[block.id] = await model.closestStyle(in: ref, to: block.font) }
            model.apply { doc in
                for i in doc.blocks.indices {
                    if let font = chosen[doc.blocks[i].id] { doc.blocks[i].font = font }
                }
            }
        }
        await waitForPairing()
    }

    /// Waits for the queued cycling and candidate changes.
    func waitForPairing() async {
        while let task = pairingChain {
            await task.value
            if pairingChain == task { pairingChain = nil }
        }
    }

    /// The strip: `ref`'s family name drawn in its own font (the system font when it is missing), black on clear
    /// for use as a template image. Resolved and drawn off the main thread; cached.
    func candidateImage(for ref: FontReference, pointSize: CGFloat, scale: CGFloat) async -> CGImage? {
        let key = CandidateImageKey(reference: ref, pointSize: pointSize, scale: scale)
        if let cached = candidateImageCache[key] { return cached }
        let known = resolved[ref]
        let store = fontStore()
        let box = await Task.detached(priority: .userInitiated) { () -> (CandidateImageBox, Bool)? in
            let found = known ?? store.flatMap { try? $0.resolve([ref])[ref] }
            var font: CTFont?
            if let found, !found.isMissing, let url = found.url {
                font = Self.loadFont(url: url, faceIndex: found.faceIndex, size: pointSize, variations: ref.variations ?? [:])
            }
            let name = ref.family.isEmpty ? ref.postScriptName : ref.family
            let fallback = CTFontCreateUIFontForLanguage(.system, pointSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
            guard let image = Self.renderLine(name, font: font ?? fallback, scale: scale) else { return nil }
            return (CandidateImageBox(image: image), font != nil)
        }.value
        guard let (imageBox, isReal) = box else { return nil }
        if isReal { candidateImageCache[key] = imageBox.image }
        return imageBox.image
    }

    /// One line of text, black on clear, at `scale` pixels per point.
    nonisolated static func renderLine(_ text: String, font: CTFont, scale: CGFloat) -> CGImage? {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let w = Int(min(4096, (max(1, width) * scale).rounded(.up)))
        let h = Int(min(1024, (max(1, ascent + descent) * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    // MARK: Helpers

    /// Runs `work` after the pairing work queued before it.
    func enqueuePairing(_ work: @escaping @MainActor (LayoutsModel) async -> Void) {
        let previous = pairingChain
        pairingChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// The family's style closest to `font` (italic, then weight, then width); `family` itself when either
    /// family's styles are unknown.
    func closestStyle(in family: FontReference, to font: FontReference) async -> FontReference {
        let target = await familyStyles(of: family)
        let own = await familyStyles(of: font)
        guard !target.isEmpty else { return family }
        if target.contains(where: { $0.reference == font }) { return font }
        let style = own.first { $0.reference == font }
            ?? own.first { $0.reference.postScriptName == font.postScriptName && $0.reference.variations == nil }
        guard let style else { return family }
        return PairingCycler.closestStyle(to: style, in: target)
    }

    /// The styles of `ref`'s family, from the cache or looked up off the main thread.
    func familyStyles(of ref: FontReference) async -> [PairingStyle] {
        let key = ref.family.lowercased()
        if let cached = familyStyleCache[key] { return cached }
        guard let store = fontStore() else { return [] }
        let generation = pairingCacheGeneration
        let styles = await Task.detached(priority: .userInitiated) { (try? store.styles(ofFamilyOf: ref)) ?? [] }.value
        if generation == pairingCacheGeneration, !styles.isEmpty { familyStyleCache[key] = styles }
        return styles
    }

    func clearPairingCaches() {
        pairingCacheGeneration += 1
        familyStyleCache = [:]
    }
}

/// A CGImage handed back from a background render (immutable once made).
private struct CandidateImageBox: @unchecked Sendable {
    let image: CGImage
}
