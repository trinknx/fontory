import AppKit
import FontoryCore
import SwiftUI
import os

/// The zoomable font grid: an `NSCollectionView` with a flow layout, wrapped for SwiftUI.
/// Every input is passed in explicitly so SwiftUI calls `updateNSView` exactly when one of them changes.
struct FontGridView: NSViewRepresentable {
    let model: AppModel
    let faceIDs: [Int64]
    let rowsVersion: Int
    let zoom: Double
    let preview: PreviewSettings
    let selection: Set<Int64>
    /// Scope, search and sort: when they change, the next list reload starts at the top.
    let query: LibraryQuery

    func makeCoordinator() -> FontGridController {
        FontGridController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.update(query: query)
        c.update(faceIDs: faceIDs)
        c.update(rowsVersion: rowsVersion)
        c.update(preview: preview)
        c.update(zoom: zoom)
        c.update(selection: selection)
    }
}

/// Data source, delegate and prefetcher of the grid. Previews come from the app-wide `PreviewPipeline`.
@MainActor
final class FontGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
    private static let log = Logger(subsystem: "local.fontory.app", category: "grid")
    static let spacing: CGFloat = 12
    /// Above this many inserted + removed items a list change reloads instead of animating a diff.
    static let diffLimit = 2000
    static let renderResumeDelay: Duration = .milliseconds(150)
    static let typeSelectWindow: TimeInterval = 0.8
    /// Zoom change per unit of trackpad magnification.
    static let magnifySensitivity = 0.6

    private let model: AppModel
    private let pipeline: PreviewPipeline
    private(set) var collectionView: FontCollectionView!
    private var scrollView: NSScrollView!
    private let layout = NSCollectionViewFlowLayout()

    private var faceIDs: [Int64] = []
    private var query: LibraryQuery?
    /// The user changed scope, search or sort since the list was last applied.
    private var queryChanged = false
    private var indexByID: [Int64: Int] = [:]
    private var rowsVersion = 0
    private var preview = PreviewSettings()
    private var zoom = AppModel.defaultZoom
    private var metrics = GridMetrics.compute(zoom: AppModel.defaultZoom, availableWidth: 800, spacing: FontGridController.spacing)
    private var baseRequest: PreviewRequest?

    /// While true (zoom gesture or a burst of zoom/size changes) cells show cached images only.
    private var renderSuspended = false
    private var gestureActive = false
    private var resumeTask: Task<Void, Never>?

    private var missingRowIndexes = IndexSet()
    private var rowFetchScheduled = false

    private var typedPrefix = ""
    private var lastTypeTime = Date.distantPast
    private var typeSelectGeneration = 0

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    #if DEBUG
    private var createdAt = ContinuousClock.now
    private var loggedFirstFrame = false
    #endif

    init(model: AppModel) {
        self.model = model
        pipeline = model.previewPipeline
        super.init()
        pipeline.addRenderObserver(self) { [weak self] key, image in self?.rendered(key, image) }
    }

    deinit {
        // Pending renders and the resume task hold this controller weakly; only the observers need removing.
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        layout.sectionInset = NSEdgeInsets(top: Self.spacing, left: Self.spacing, bottom: Self.spacing, right: Self.spacing)
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.itemSize = Self.flooredSize(metrics.itemSize)

        let cv = FontCollectionView()
        cv.controller = self
        cv.collectionViewLayout = layout
        cv.register(FontGridItem.self, forItemWithIdentifier: FontGridItem.identifier)
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self
        collectionView = cv

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.contentView.postsFrameChangedNotifications = true
        scrollView = scroll

        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyLayout(anchorPoint: nil) }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: AppModel.rowsLoadedNotification, object: model, queue: .main) { [weak self] note in
                let ids = note.userInfo?[AppModel.rowIDsKey] as? [Int64] ?? []
                MainActor.assumeIsolated { self?.rowsLoaded(Set(ids)) }
            })
        #if DEBUG
        createdAt = .now
        #endif
        return scroll
    }

    private static func flooredSize(_ s: CGSize) -> CGSize {
        CGSize(width: floor(s.width), height: floor(s.height))
    }

    // MARK: Updates from SwiftUI

    func update(faceIDs new: [Int64]) {
        guard new != faceIDs else { return }
        let old = faceIDs
        var index: [Int64: Int] = [:]
        index.reserveCapacity(new.count)
        for (i, id) in new.enumerated() { index[id] = i }

        if let (removed, inserted) = Self.smallDiff(old: old, new: new, newIndex: index, oldIndex: indexByID) {
            collectionView.performBatchUpdates({
                faceIDs = new
                indexByID = index
                if !removed.isEmpty { collectionView.deleteItems(at: removed) }
                if !inserted.isEmpty { collectionView.insertItems(at: inserted) }
            }, completionHandler: nil)
        } else {
            // A new query starts at the top; otherwise (a rescan growing the list, say) keep the same face in place.
            let keep = queryChanged ? nil : captureAnchor(at: nil).map { (faceID: old[$0.indexPath.item], offset: $0.offset) }
            pipeline.cancelAll()
            faceIDs = new
            indexByID = index
            collectionView.reloadData()
            if let keep, let i = index[keep.faceID] {
                restore(Anchor(indexPath: IndexPath(item: i, section: 0), fraction: 0, offset: keep.offset))
            } else {
                collectionView.scroll(.zero)
            }
        }
        queryChanged = false
    }

    func update(query new: LibraryQuery) {
        if let query, query != new { queryChanged = true }
        query = new
    }

    /// The removed (old indexes) and inserted (new indexes) items when the change is a small set of insertions
    /// and removals that keeps the relative order of the remaining items. Nil means: reload.
    private static func smallDiff(old: [Int64], new: [Int64], newIndex: [Int64: Int], oldIndex: [Int64: Int])
        -> (Set<IndexPath>, Set<IndexPath>)? {
        guard !old.isEmpty, !new.isEmpty else { return nil }
        var removed = Set<IndexPath>(), inserted = Set<IndexPath>()
        var keptOld: [Int64] = [], keptNew: [Int64] = []
        for (i, id) in old.enumerated() {
            if newIndex[id] == nil { removed.insert(IndexPath(item: i, section: 0)) } else { keptOld.append(id) }
            if removed.count > diffLimit { return nil }
        }
        for (i, id) in new.enumerated() {
            if oldIndex[id] == nil { inserted.insert(IndexPath(item: i, section: 0)) } else { keptNew.append(id) }
            if removed.count + inserted.count > diffLimit { return nil }
        }
        return keptOld == keptNew ? (removed, inserted) : nil
    }

    func update(rowsVersion new: Int) {
        guard new != rowsVersion else { return }
        rowsVersion = new
        // The row cache was dropped; visible cells keep their content until the fresh rows arrive.
        let visible = collectionView.indexPathsForVisibleItems().map(\.item)
        if let lo = visible.min(), let hi = visible.max() {
            model.prefetchRows(faceIDs[max(0, lo - 100)..<min(faceIDs.count, hi + 200)])
        }
    }

    func update(preview new: PreviewSettings) {
        guard new != preview else { return }
        preview = new
        settingsChanged()
    }

    func update(zoom new: Double) {
        // Keyboard zoom anchors on the pointer; the slider and menu clicks on the selection or first visible item.
        // The flag is consumed even when the value did not change (zooming past the limits), so it cannot leak.
        let usePointer = model.zoomAnchorsOnPointer
        model.zoomAnchorsOnPointer = false
        guard abs(new - zoom) > 1e-9 else { return }
        zoom = new
        applyLayout(anchorPoint: usePointer ? mouseLocation() : nil)
    }

    func update(selection new: Set<Int64>) {
        let current = Set(collectionView.selectionIndexPaths.compactMap { faceIDs.indices.contains($0.item) ? faceIDs[$0.item] : nil })
        guard new != current else { return }
        collectionView.selectionIndexPaths = Set(new.compactMap { indexByID[$0].map { IndexPath(item: $0, section: 0) } })
    }

    /// Preview settings or the backing scale changed: drop pending renders and re-render what is visible.
    func settingsChanged() {
        pipeline.cancelAll()
        baseRequest = nil
        reconfigureVisible()
    }

    // MARK: Layout and zoom

    /// Recomputes the item size for the current zoom and width. The anchor item (under `anchorPoint`, else the
    /// first selected visible item, else the first visible item) keeps its position in the visible rect.
    private func applyLayout(anchorPoint: CGPoint?) {
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        let new = GridMetrics.compute(zoom: zoom, availableWidth: width, spacing: Self.spacing)
        guard new != metrics else { return }
        let anchor = captureAnchor(at: anchorPoint)
        // Resizes and zoom bursts render once they settle (nothing visible yet, e.g. the first layout: no wait).
        if anchor != nil || gestureActive { suspendRendering() }
        metrics = new
        baseRequest = nil
        pipeline.cancelAll()
        layout.itemSize = Self.flooredSize(new.itemSize)
        layout.invalidateLayout()
        if let anchor { restore(anchor) }
        reconfigureVisible()
    }

    private struct Anchor {
        let indexPath: IndexPath
        /// Where in the item the anchor point lies, 0 (top) … 1 (bottom).
        let fraction: CGFloat
        /// Distance of the anchor point from the top of the visible rect.
        let offset: CGFloat
    }

    private func captureAnchor(at point: CGPoint?) -> Anchor? {
        guard !faceIDs.isEmpty else { return nil }
        let visible = collectionView.visibleRect
        if let point, visible.contains(point), let ip = collectionView.indexPathForItem(at: point),
           let frame = layout.layoutAttributesForItem(at: ip)?.frame, frame.height > 0 {
            return Anchor(indexPath: ip, fraction: (point.y - frame.minY) / frame.height, offset: point.y - visible.minY)
        }
        let visibleItems = collectionView.indexPathsForVisibleItems()
        let selectedVisible = collectionView.selectionIndexPaths.filter { ip in
            layout.layoutAttributesForItem(at: ip).map { $0.frame.intersects(visible) } ?? false
        }
        guard let ip = selectedVisible.min() ?? visibleItems.min(),
              let frame = layout.layoutAttributesForItem(at: ip)?.frame else { return nil }
        return Anchor(indexPath: ip, fraction: 0, offset: frame.minY - visible.minY)
    }

    private func restore(_ anchor: Anchor) {
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = layout.layoutAttributesForItem(at: anchor.indexPath)?.frame else { return }
        let clip = scrollView.contentView
        let maxY = max(0, collectionView.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, frame.minY + anchor.fraction * frame.height - anchor.offset))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func mouseLocation() -> CGPoint? {
        guard let window = collectionView.window else { return nil }
        return collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    func magnify(by magnification: CGFloat, phase: NSEvent.Phase, at point: CGPoint) {
        if phase.contains(.began) { gestureActive = true }
        let new = min(1, max(0, zoom + Double(magnification) * Self.magnifySensitivity))
        if abs(new - zoom) > 1e-9 {
            zoom = new
            applyLayout(anchorPoint: point)
            model.zoom[.grid] = new
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            gestureActive = false
            suspendRendering()
        }
    }

    /// Shows cached (scaled) images only, and schedules a re-render of the visible items 150 ms after the last
    /// change once no gesture is active.
    private func suspendRendering() {
        renderSuspended = true
        resumeTask?.cancel()
        guard !gestureActive else { return }
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: FontGridController.renderResumeDelay)
            guard !Task.isCancelled, let self, !self.gestureActive else { return }
            self.renderSuspended = false
            self.reconfigureVisible()
        }
    }

    // MARK: Cells

    private func reconfigureVisible() {
        for case let item as FontGridItem in collectionView.visibleItems() {
            guard let ip = collectionView.indexPath(for: item) else { continue }
            configure(item, at: ip.item)
        }
    }

    /// The template request for the current settings and size; per-face text is filled in by `key(for:)`.
    private func currentBaseRequest() -> PreviewRequest {
        if let baseRequest { return baseRequest }
        let request = PreviewRequest(
            text: preview.text,
            pointSize: preview.pointSizeOverride.map { CGFloat($0) } ?? metrics.previewPointSize,
            tracking: CGFloat(preview.tracking),
            foreground: preview.foreground, background: preview.background,
            alignment: preview.alignment.ctAlignment, smoothing: preview.smoothing,
            size: FontGridItem.previewSize(itemSize: layout.itemSize),
            scale: collectionView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        baseRequest = request
        return request
    }

    private func key(for row: FaceRow) -> PreviewPipeline.Key {
        var request = currentBaseRequest()
        if preview.text.trimmingCharacters(in: .whitespaces).isEmpty { request.text = row.fullName }
        return PreviewPipeline.Key(faceID: row.id, request: request, autoSize: preview.autoSize)
    }

    private func configure(_ item: FontGridItem, at index: Int) {
        guard faceIDs.indices.contains(index) else { return }
        let id = faceIDs[index]
        let row = model.cachedRow(id)
        item.configure(faceID: id, row: row, locked: row.map(model.isActivationLocked) ?? false, background: preview.background)
        guard let row else {
            item.wantedKey = nil
            needRow(at: index)
            return
        }
        let key = key(for: row)
        item.wantedKey = key
        if let image = pipeline.image(for: key) {
            item.show(image: image)
            return
        }
        if !item.hasImage { item.show(image: pipeline.anyImage(forFace: id)) }
        if !renderSuspended, let url = row.fileURL {
            pipeline.request(key, fileURL: url, faceIndex: row.faceIndex)
        }
    }

    private func requestRender(at index: Int) {
        guard !renderSuspended, faceIDs.indices.contains(index), let row = model.cachedRow(faceIDs[index]),
              let url = row.fileURL else { return }
        pipeline.request(key(for: row), fileURL: url, faceIndex: row.faceIndex)
    }

    private func rendered(_ key: PreviewPipeline.Key, _ image: CGImage) {
        for case let item as FontGridItem in collectionView.visibleItems() where item.wantedKey == key {
            item.show(image: image)
            #if DEBUG
            if !loggedFirstFrame {
                loggedFirstFrame = true
                let sinceGrid = ContinuousClock.now - createdAt
                Self.log.notice("first grid preview after \(sinceGrid.formatted(.units(allowed: [.milliseconds])), privacy: .public) (grid created), \(Self.secondsSinceLaunch() * 1000, format: .fixed(precision: 0), privacy: .public) ms since process launch")
            }
            #endif
        }
    }

    #if DEBUG
    private static func secondsSinceLaunch() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }
    #endif

    // MARK: Rows

    /// Collects indexes without rows and fetches a window around them once per run loop turn.
    private func needRow(at index: Int) {
        missingRowIndexes.insert(index)
        guard !rowFetchScheduled else { return }
        rowFetchScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.fetchMissingRows() }
        }
    }

    private func fetchMissingRows() {
        rowFetchScheduled = false
        guard let lo = missingRowIndexes.first, let hi = missingRowIndexes.last else { return }
        missingRowIndexes.removeAll()
        let range = max(0, lo - 100)..<min(faceIDs.count, hi + 200)
        guard !range.isEmpty else { return }
        model.prefetchRows(faceIDs[range])
    }

    private func rowsLoaded(_ ids: Set<Int64>) {
        for case let item as FontGridItem in collectionView.visibleItems() {
            guard let ip = collectionView.indexPath(for: item), faceIDs.indices.contains(ip.item),
                  ids.contains(faceIDs[ip.item]) else { continue }
            configure(item, at: ip.item)
        }
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        faceIDs.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FontGridItem.identifier, for: indexPath) as! FontGridItem
        item.onToggleActivation = { [weak self] id in self?.toggleActivation(id) }
        item.activationMenu = { [weak self] id in self?.activationMenu(for: id) }
        configure(item, at: indexPath.item)
        return item
    }

    // MARK: NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        // Items prepared in the overdraw area may have missed renders and row loads delivered to visible items only.
        if let item = item as? FontGridItem { configure(item, at: indexPath.item) }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        if let id = (item as? FontGridItem)?.faceID { pipeline.cancel(faceID: id) }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        pushSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        pushSelection()
    }

    private func pushSelection() {
        let ids = Set(collectionView.selectionIndexPaths.compactMap { faceIDs.indices.contains($0.item) ? faceIDs[$0.item] : nil })
        if model.selection != ids { model.selection = ids }
    }

    // MARK: NSCollectionViewPrefetching

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let indexes = indexPaths.map(\.item).filter { faceIDs.indices.contains($0) }
        model.prefetchRows(indexes.map { faceIDs[$0] })
        for i in indexes { requestRender(at: i) }
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for ip in indexPaths where faceIDs.indices.contains(ip.item) {
            pipeline.cancel(faceID: faceIDs[ip.item])
        }
    }

    // MARK: Activation

    private func toggleActivation(_ id: Int64) {
        guard let row = model.cachedRow(id), !model.isActivationLocked(row) else { return }
        let state: ActivationState = row.activation == .off ? .on : .off
        Task { await model.setActivation([id], state) }
    }

    private func activationMenu(for id: Int64) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in FontContextMenu.activationItems(for: [id], model: model) { menu.addItem(item) }
        return menu
    }

    /// Space: activates the selection, or deactivates it when every unlocked selected face is already active.
    func toggleSelectionActivation() {
        let rows = model.selection.compactMap(model.cachedRow).filter { !model.isActivationLocked($0) }
        guard !rows.isEmpty else { return }
        let state: ActivationState = rows.contains { $0.activation == .off } ? .on : .off
        let ids = rows.map(\.id)
        Task { await model.setActivation(ids, state) }
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        guard let ip = collectionView.indexPathForItem(at: point), faceIDs.indices.contains(ip.item) else { return nil }
        if !collectionView.selectionIndexPaths.contains(ip) {
            collectionView.selectionIndexPaths = [ip]
            pushSelection()
        }
        let ids = collectionView.selectionIndexPaths.map(\.item).sorted().compactMap { faceIDs.indices.contains($0) ? faceIDs[$0] : nil }
        return FontContextMenu.make(for: ids, model: model)
    }

    // MARK: Type to scroll

    /// A prefix is being typed: a Space continues it instead of toggling activation.
    var isTypeSelecting: Bool {
        !typedPrefix.isEmpty && Date().timeIntervalSince(lastTypeTime) <= Self.typeSelectWindow
    }

    /// Typed letters within 0.8 s of each other form a prefix; the first face of a family with it is selected.
    func typeSelect(_ characters: String) {
        let now = Date()
        if now.timeIntervalSince(lastTypeTime) > Self.typeSelectWindow { typedPrefix = "" }
        lastTypeTime = now
        typedPrefix += characters
        typeSelectGeneration += 1
        let generation = typeSelectGeneration
        let prefix = typedPrefix
        Task { [weak self] in
            guard let self, let index = await self.model.firstIndex(familyPrefix: prefix),
                  generation == self.typeSelectGeneration, self.faceIDs.indices.contains(index) else { return }
            let ip = IndexPath(item: index, section: 0)
            self.collectionView.selectionIndexPaths = [ip]
            self.collectionView.scrollToItems(at: [ip], scrollPosition: .centeredVertically)
            self.pushSelection()
        }
    }
}

/// The grid's collection view: pinch zoom, Space, type-to-scroll and the context menu.
final class FontCollectionView: NSCollectionView {
    weak var controller: FontGridController?

    override func magnify(with event: NSEvent) {
        controller?.magnify(by: event.magnification, phase: event.phase, at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function])
        guard mods.isEmpty, let chars = event.characters, !chars.isEmpty else { return super.keyDown(with: event) }
        if chars == " ", controller?.isTypeSelecting != true {
            controller?.toggleSelectionActivation()
        } else if chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) {
            controller?.typeSelect(chars)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.settingsChanged()
    }
}

