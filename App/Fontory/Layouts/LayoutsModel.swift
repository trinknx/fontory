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
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// The open layout's candidate families, in order.
    var candidates: [FontReference] { current?.candidates ?? [] }
    @ObservationIgnored private var undoStack: [LayoutDocument] = []
    @ObservationIgnored private var redoStack: [LayoutDocument] = []
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

    /// Forgets the open document's session state (undo, selection, render).
    private func closeCurrent() {
        undoStack = []
        redoStack = []
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
    /// ignored. Marks the layout dirty, schedules the autosave and re-renders.
    func apply(_ edit: (inout LayoutDocument) -> Void, undoable: Bool = true) {
        guard let before = current else { return }
        var after = before
        edit(&after)
        guard after != before else { return }
        if undoable {
            undoStack.append(before)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            redoStack = []
        } else {
            // Keep the change across undo/redo: replay it on every stored state.
            undoStack = undoStack.map { var d = $0; edit(&d); return d }
            redoStack = redoStack.map { var d = $0; edit(&d); return d }
        }
        replaceCurrent(with: after)
    }

    func undo() {
        guard let doc = current, let previous = undoStack.popLast() else { return }
        redoStack.append(doc)
        replaceCurrent(with: previous)
    }

    func redo() {
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
