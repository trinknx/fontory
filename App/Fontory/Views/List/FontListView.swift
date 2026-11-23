import AppKit
import FontoryCore
import SwiftUI

/// The family list: an `NSOutlineView` with families at the top level and their matching faces as children,
/// wrapped for SwiftUI. Every input is passed in explicitly so SwiftUI calls `updateNSView` exactly when one changes.
struct FontListView: NSViewRepresentable {
    let model: AppModel
    let families: [FamilyGroup]
    let rowsVersion: Int
    let zoom: Double
    let preview: PreviewSettings
    let selection: Set<Int64>
    /// Scope, search and sort: when they change, the next reload starts at the top.
    let query: LibraryQuery

    func makeCoordinator() -> FontListController {
        FontListController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.update(query: query)
        c.update(families: families)
        c.update(rowsVersion: rowsVersion)
        c.update(preview: preview)
        c.update(zoom: zoom)
        c.update(selection: selection)
    }
}

/// A top-level row. Children are created when the family is first expanded.
final class FamilyNode {
    let key: String
    let name: String
    /// Display order of the faces.
    let faceIDs: [Int64]
    let representativeID: Int64

    init(_ group: FamilyGroup) {
        key = group.id
        name = group.name
        faceIDs = group.faceIDs
        representativeID = group.representativeID
    }

    private(set) lazy var children: [FaceNode] = faceIDs.map { FaceNode(faceID: $0, family: self) }
    private lazy var childByFace: [Int64: FaceNode] = Dictionary(uniqueKeysWithValues: children.map { ($0.faceID, $0) })

    func child(for faceID: Int64) -> FaceNode? { childByFace[faceID] }
}

final class FaceNode {
    let faceID: Int64
    unowned let family: FamilyNode

    init(faceID: Int64, family: FamilyNode) {
        self.faceID = faceID
        self.family = family
    }
}

/// Data source and delegate of the list. Rows come from the model's cache (fetched in windows around the visible
/// rows), previews from the app-wide `PreviewPipeline` shared with the grid.
@MainActor
final class FontListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let minRowHeight: CGFloat = 24
    static let maxRowHeight: CGFloat = 160
    /// Preview point size as a fraction of the row height.
    static let previewSizeRatio: CGFloat = 0.6
    static let autosaveName = "FontListColumns"
    static let hiddenColumnsKey = "FontListHiddenColumns"
    static let renderResumeDelay: Duration = .milliseconds(150)
    static let typeSelectWindow: TimeInterval = 0.8
    static let magnifySensitivity = 0.6
    /// Rows fetched around the visible ones.
    static let prefetchBefore = 50
    static let prefetchAfter = 100

    static func rowHeight(zoom: Double) -> CGFloat {
        (minRowHeight + (maxRowHeight - minRowHeight) * CGFloat(min(1, max(0, zoom)))).rounded()
    }

    private let model: AppModel
    private let pipeline: PreviewPipeline
    private(set) var outlineView: FontOutlineView!
    private var scrollView: NSScrollView!

    /// The families as the model delivered them (query order).
    private var sourceFamilies: [FamilyGroup] = []
    /// The displayed families (after any in-memory sort).
    private var nodes: [FamilyNode] = []
    private var nodeByKey: [String: FamilyNode] = [:]
    private var familyOfFace: [Int64: FamilyNode] = [:]
    private var lowercasedNames: [String] = []
    private var expandedKeys: Set<String> = []
    private var hasLoaded = false
    /// Families have been shown at least once (the first non-empty list scrolls to the shared selection).
    private var hasShownFamilies = false

    private var query: LibraryQuery?
    /// The user changed scope, search or sort since the list was last applied.
    private var queryChanged = false
    /// A header sort on a column the query cannot sort by.
    private var localSort: (column: ListColumn, ascending: Bool)?
    private var sortGeneration = 0
    /// The displayed order is stale (a column sort was dropped): apply the next family list even if unchanged.
    private var needsReapply = false

    private var rowsVersion = 0
    private var preview = PreviewSettings()
    private var zoom = AppModel.defaultZoom
    private var selection: Set<Int64> = []
    /// Set while the outline's selection is changed in code, so it is not pushed back to the model.
    private var applyingSelection = false

    private var baseRequest: PreviewRequest?
    private var renderSuspended = false
    private var gestureActive = false
    private var resumeTask: Task<Void, Never>?
    private var prefetchScheduled = false

    private var typedPrefix = ""
    private var lastTypeTime = Date.distantPast

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        pipeline = model.previewPipeline
        super.init()
        pipeline.addRenderObserver(self) { [weak self] key, image in self?.rendered(key, image) }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        let ov = FontOutlineView()
        ov.controller = self
        ov.style = .fullWidth
        ov.usesAlternatingRowBackgroundColors = true
        ov.allowsMultipleSelection = true
        ov.allowsEmptySelection = true
        ov.allowsColumnReordering = true
        ov.allowsColumnResizing = true
        ov.allowsColumnSelection = false
        ov.allowsTypeSelect = false
        ov.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        ov.indentationPerLevel = 14
        ov.autoresizesOutlineColumn = false
        ov.rowHeight = Self.rowHeight(zoom: zoom)

        for column in ListColumn.allCases {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tc.title = column.title
            tc.width = column.defaultWidth
            tc.minWidth = column == .preview ? 60 : 36
            tc.resizingMask = .userResizingMask
            if column.isNumeric { tc.headerCell.alignment = .right }
            ov.addTableColumn(tc)
            if column == .name { ov.outlineTableColumn = tc }
        }
        // Restores the saved order and widths.
        ov.autosaveName = Self.autosaveName
        ov.autosaveTableColumns = true
        let hidden = Self.hiddenColumns()
        for tc in ov.tableColumns {
            if let column = ListColumn(rawValue: tc.identifier.rawValue) { tc.isHidden = column.canHide && hidden.contains(column) }
        }

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        ov.headerView?.menu = headerMenu

        ov.dataSource = self
        ov.delegate = self
        outlineView = ov

        let scroll = NSScrollView()
        scroll.documentView = ov
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollView = scroll

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePrefetch() }
        })
        observers.append(center.addObserver(forName: AppModel.rowsLoadedNotification, object: model, queue: .main) { [weak self] note in
            let ids = note.userInfo?[AppModel.rowIDsKey] as? [Int64] ?? []
            MainActor.assumeIsolated { self?.rowsLoaded(Set(ids)) }
        })
        observers.append(center.addObserver(forName: NSTableView.columnDidResizeNotification, object: ov, queue: .main) { [weak self] note in
            let column = note.userInfo?["NSTableColumn"] as? NSTableColumn
            MainActor.assumeIsolated {
                if column?.identifier.rawValue == ListColumn.preview.rawValue { self?.previewColumnResized() }
            }
        })
        updateSortIndicators()
        return scroll
    }

    // MARK: Updates from SwiftUI

    func update(query new: LibraryQuery) {
        if let query, query != new { queryChanged = true }
        let sortChanged = query?.sort != new.sort || query?.ascending != new.ascending
        // A sort chosen elsewhere (the toolbar, or a header click mapped to the query) replaces a column sort.
        if query != nil, sortChanged, localSort != nil {
            localSort = nil
            sortGeneration += 1
            // Show the query's order even if the next family list happens to be unchanged.
            needsReapply = true
        }
        query = new
        if sortChanged { updateSortIndicators() }
    }

    func update(families new: [FamilyGroup]) {
        guard new != sourceFamilies || !hasLoaded || needsReapply else { return }
        needsReapply = false
        sourceFamilies = new
        applySorted()
    }

    func update(rowsVersion new: Int) {
        guard new != rowsVersion else { return }
        rowsVersion = new
        // The row cache was dropped; visible cells keep their content until the fresh rows arrive.
        schedulePrefetch()
    }

    func update(preview new: PreviewSettings) {
        guard new != preview else { return }
        preview = new
        settingsChanged()
    }

    func update(zoom new: Double) {
        // The keyboard-zoom flag is meant for the grid's pointer anchor; the list always anchors on the
        // selection or the first visible row. Consume it so it does not leak into the grid.
        model.zoomAnchorsOnPointer = false
        guard abs(new - zoom) > 1e-9 else { return }
        zoom = new
        applyRowHeight(anchorPoint: nil)
    }

    func update(selection new: Set<Int64>) {
        guard new != selection else { return }
        selection = new
        applySelectionToOutline()
    }

    /// Preview settings or the backing scale changed: drop pending renders and re-render what is visible.
    func settingsChanged() {
        pipeline.cancelAll()
        baseRequest = nil
        reconfigureVisible()
    }

    // MARK: Family list

    /// Applies `sourceFamilies`, sorted in memory first when a local sort is active.
    private func applySorted() {
        sortGeneration += 1
        guard let localSort else {
            apply(sourceFamilies.map(FamilyNode.init))
            return
        }
        let generation = sortGeneration
        let source = sourceFamilies
        // Everything the keys need from the main actor is captured here; the keys and the sort run off it.
        let lockedLocations = Set(model.systemLocations.map(\.id))
        let locationNames = Dictionary(model.locations.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        Task { [weak self] in
            guard let self else { return }
            let rows = await self.model.rowsForAction(source.flatMap(\.faceIDs))
            guard generation == self.sortGeneration else { return }
            let sorted = await Task.detached(priority: .userInitiated) { () -> [FamilyGroup] in
                var keys: [Int64: FamilySortKey] = [:]
                keys.reserveCapacity(rows.count)
                for row in rows {
                    keys[row.id] = localSort.column.sortKey(row, locked: lockedLocations.contains(row.locationID),
                                                            locationName: locationNames[row.locationID])
                }
                return FamilyListSorter.sorted(source, keys: keys, ascending: localSort.ascending)
            }.value
            guard generation == self.sortGeneration else { return }
            self.apply(sorted.map(FamilyNode.init))
        }
    }

    /// Replaces the displayed families, keeping expansion, selection and (unless the query changed) the scroll
    /// position of the first selected visible row, else the first visible row.
    private func apply(_ newNodes: [FamilyNode]) {
        let anchor = queryChanged || !hasLoaded ? nil : captureAnchor(at: nil)
        let firstLoad = !hasShownFamilies && !newNodes.isEmpty
        queryChanged = false
        hasLoaded = true
        if !newNodes.isEmpty { hasShownFamilies = true }

        nodes = newNodes
        nodeByKey = Dictionary(newNodes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        familyOfFace = [:]
        familyOfFace.reserveCapacity(newNodes.reduce(0) { $0 + $1.faceIDs.count })
        for node in newNodes { for id in node.faceIDs { familyOfFace[id] = node } }
        lowercasedNames = newNodes.map { $0.name.lowercased() }

        pipeline.cancelAll()
        applyingSelection = true
        outlineView.reloadData()
        for key in expandedKeys { if let node = nodeByKey[key] { outlineView.expandItem(node) } }
        applyingSelection = false
        applySelectionToOutline()

        if let anchor, let row = row(for: anchor.target) {
            restore(anchor, row: row)
        } else if let anchor, outlineView.numberOfRows > 0 {
            // The anchored family is gone (not a query change): stay at about the same place.
            restore(anchor, row: min(anchor.row, outlineView.numberOfRows - 1))
        } else if firstLoad, let first = outlineView.selectedRowIndexes.first {
            // Coming from the grid: bring the shared selection into view.
            outlineView.scrollRowToVisible(first)
        } else {
            outlineView.scroll(.zero)
        }
        schedulePrefetch()
    }

    // MARK: Scroll anchor

    private enum AnchorTarget {
        case family(String)
        case face(Int64)
    }

    private struct Anchor {
        let target: AnchorTarget
        let row: Int
        /// Where in the row the anchor point lies, 0 (top) … 1 (bottom).
        let fraction: CGFloat
        /// Distance of the anchor point from the top of the visible rect.
        let offset: CGFloat
    }

    private func captureAnchor(at point: CGPoint?) -> Anchor? {
        let visible = outlineView.visibleRect
        let rows = outlineView.rows(in: visible)
        guard rows.length > 0 else { return nil }
        var row: Int
        var fraction: CGFloat = 0
        if let point, visible.contains(point), outlineView.row(at: point) >= 0 {
            row = outlineView.row(at: point)
            let rect = outlineView.rect(ofRow: row)
            fraction = rect.height > 0 ? (point.y - rect.minY) / rect.height : 0
        } else {
            let visibleRange = rows.location..<(rows.location + rows.length)
            row = outlineView.selectedRowIndexes.first { visibleRange.contains($0) } ?? rows.location
        }
        let rect = outlineView.rect(ofRow: row)
        let pointY = rect.minY + fraction * rect.height
        let target: AnchorTarget
        switch outlineView.item(atRow: row) {
        case let face as FaceNode: target = .face(face.faceID)
        case let family as FamilyNode: target = .family(family.key)
        default: return nil
        }
        return Anchor(target: target, row: row, fraction: fraction, offset: pointY - visible.minY)
    }

    /// The row now showing `target`: the face's own row, else its (collapsed) family's row.
    private func row(for target: AnchorTarget) -> Int? {
        let item: AnyObject?
        switch target {
        case .family(let key): item = nodeByKey[key]
        case .face(let id):
            guard let family = familyOfFace[id] else { return nil }
            item = outlineView.isItemExpanded(family) ? family.child(for: id) : family
        }
        guard let item else { return nil }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? row : nil
    }

    private func restore(_ anchor: Anchor, row: Int) {
        let rect = outlineView.rect(ofRow: row)
        let clip = scrollView.contentView
        let maxY = max(0, outlineView.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, rect.minY + anchor.fraction * rect.height - anchor.offset))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Zoom

    private func applyRowHeight(anchorPoint: CGPoint?) {
        let height = Self.rowHeight(zoom: zoom)
        guard height != outlineView.rowHeight else { return }
        let anchor = captureAnchor(at: anchorPoint)
        if anchor != nil || gestureActive { suspendRendering() }
        pipeline.cancelAll()
        baseRequest = nil
        outlineView.rowHeight = height
        if let anchor { restore(anchor, row: anchor.row) }
        reconfigureVisible()
        schedulePrefetch()
    }

    func magnify(by magnification: CGFloat, phase: NSEvent.Phase, at point: CGPoint) {
        if phase.contains(.began) { gestureActive = true }
        let new = min(1, max(0, zoom + Double(magnification) * Self.magnifySensitivity))
        if abs(new - zoom) > 1e-9 {
            zoom = new
            applyRowHeight(anchorPoint: point)
            model.zoom[.list] = new
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            gestureActive = false
            suspendRendering()
        }
    }

    private func previewColumnResized() {
        guard hasLoaded else { return }
        pipeline.cancelAll()
        baseRequest = nil
        suspendRendering()
        reconfigureVisible()
    }

    /// Shows cached (scaled) images only, and re-renders the visible rows 150 ms after the last change once no
    /// gesture is active.
    private func suspendRendering() {
        renderSuspended = true
        resumeTask?.cancel()
        guard !gestureActive else { return }
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: FontListController.renderResumeDelay)
            guard !Task.isCancelled, let self, !self.gestureActive else { return }
            self.renderSuspended = false
            self.reconfigureVisible()
        }
    }

    // MARK: Rows

    private func faceID(for item: Any?) -> Int64? {
        switch item {
        case let face as FaceNode: face.faceID
        case let family as FamilyNode: family.representativeID
        default: nil
        }
    }

    /// Fetches the rows around the visible ones, once per run loop turn.
    private func schedulePrefetch() {
        guard !prefetchScheduled else { return }
        prefetchScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prefetchScheduled = false
                self.prefetchVisible()
            }
        }
    }

    private func prefetchVisible() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        let lo = max(0, visible.location - Self.prefetchBefore)
        let hi = min(count, visible.location + visible.length + Self.prefetchAfter)
        guard lo < hi else { return }
        model.prefetchRows((lo..<hi).compactMap { faceID(for: outlineView.item(atRow: $0)) })
    }

    private func rowsLoaded(_ ids: Set<Int64>) {
        forEachVisibleRow { row, item in
            if let id = faceID(for: item), ids.contains(id) { reconfigure(row: row) }
        }
    }

    private func forEachVisibleRow(_ body: (Int, Any?) -> Void) {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) { body(row, outlineView.item(atRow: row)) }
    }

    private func reconfigureVisible() {
        forEachVisibleRow { row, _ in reconfigure(row: row) }
    }

    /// Reconfigures the existing cell views of `row` in place.
    private func reconfigure(row: Int) {
        let item = outlineView.item(atRow: row)
        for (index, tc) in outlineView.tableColumns.enumerated() where !tc.isHidden {
            guard let column = ListColumn(rawValue: tc.identifier.rawValue),
                  let view = outlineView.view(atColumn: index, row: row, makeIfNecessary: false) else { continue }
            configure(view, column: column, item: item)
        }
    }

    // MARK: Cells

    /// The template request for the current settings and row size; per-face text is filled in by `key(for:)`.
    private func currentBaseRequest() -> PreviewRequest {
        if let baseRequest { return baseRequest }
        let height = outlineView.rowHeight
        let width = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.preview.rawValue))?.width
            ?? ListColumn.preview.defaultWidth
        let request = PreviewRequest(
            text: preview.text,
            pointSize: preview.pointSizeOverride.map { CGFloat($0) } ?? height * Self.previewSizeRatio,
            tracking: CGFloat(preview.tracking),
            foreground: preview.foreground, background: preview.background,
            alignment: preview.alignment.ctAlignment, smoothing: preview.smoothing,
            size: ListPreviewCell.previewSize(cellSize: CGSize(width: width, height: height)),
            scale: outlineView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        baseRequest = request
        return request
    }

    private func key(for row: FaceRow) -> PreviewPipeline.Key {
        var request = currentBaseRequest()
        if preview.text.trimmingCharacters(in: .whitespaces).isEmpty { request.text = row.fullName }
        return PreviewPipeline.Key(faceID: row.id, request: request, autoSize: preview.autoSize)
    }

    private func makeCell<T: NSView>(_ identifier: NSUserInterfaceItemIdentifier, _ make: () -> T) -> T {
        (outlineView.makeView(withIdentifier: identifier, owner: nil) as? T) ?? make()
    }

    private func configure(_ view: NSView, column: ListColumn, item: Any?) {
        guard let id = faceID(for: item) else { return }
        let row = model.cachedRow(id)
        if row == nil { schedulePrefetch() }
        let family = item as? FamilyNode
        switch view {
        case let cell as ListPreviewCell:
            configurePreview(cell, faceID: id, row: row)
        case let cell as ListStatusCell:
            // Family rows show no status: their faces may differ.
            if family != nil {
                cell.configure(faceID: nil, row: nil, locked: false)
            } else {
                cell.configure(faceID: id, row: row, locked: row.map(model.isActivationLocked) ?? false)
            }
        case let cell as ListTextCell:
            configureText(cell, column: column, family: family, row: row)
        default:
            break
        }
    }

    private func configurePreview(_ cell: ListPreviewCell, faceID id: Int64, row: FaceRow?) {
        cell.configure(faceID: id, online: row?.online ?? true, background: preview.background)
        guard let row else {
            cell.wantedKey = nil
            return
        }
        let key = key(for: row)
        cell.wantedKey = key
        if let image = pipeline.image(for: key) {
            cell.show(image: image)
            return
        }
        if !cell.hasImage { cell.show(image: pipeline.anyImage(forFace: id)) }
        if !renderSuspended, let url = row.fileURL {
            pipeline.request(key, fileURL: url, faceIndex: row.faceIndex)
        }
    }

    private func configureText(_ cell: ListTextCell, column: ListColumn, family: FamilyNode?, row: FaceRow?) {
        let label = cell.label
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.alignment = column.isNumeric ? .right : .natural
        label.textColor = (row?.online ?? true) ? .labelColor : .secondaryLabelColor
        label.toolTip = nil
        if let family {
            switch column {
            case .name:
                let count = family.faceIDs.count
                let text = NSMutableAttributedString(string: family.name, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
                text.append(NSAttributedString(string: "  \(count)", attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                label.attributedStringValue = text
            case .family:
                label.stringValue = family.name
            case .style:
                let count = family.faceIDs.count
                label.stringValue = count == 1 ? (row?.style ?? "") : "\(count) styles"
            default:
                label.stringValue = ""
            }
            return
        }
        label.stringValue = row.map { column.text(for: $0, locationName: model.location($0.locationID)?.displayName) } ?? ""
        label.toolTip = column == .location ? label.stringValue : nil
    }

    static func statusText(_ row: FaceRow, locked: Bool) -> String {
        if locked { return "System" }
        if !row.online { return "Offline" }
        switch row.activation {
        case .on: return "Active"
        case .temporary: return "Temporary"
        case .off: return "Off"
        }
    }

    private func rendered(_ key: PreviewPipeline.Key, _ image: CGImage) {
        let index = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.preview.rawValue))
        guard index >= 0 else { return }
        forEachVisibleRow { row, _ in
            if let cell = outlineView.view(atColumn: index, row: row, makeIfNecessary: false) as? ListPreviewCell,
               cell.wantedKey == key {
                cell.show(image: image)
            }
        }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: nodes.count
        case let family as FamilyNode: family.faceIDs.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let family = item as? FamilyNode { return family.children[index] }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FamilyNode
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let view: NSView
        switch column {
        case .preview:
            view = makeCell(ListPreviewCell.identifier) { ListPreviewCell() }
        case .status:
            let cell = makeCell(ListStatusCell.identifier) { ListStatusCell() }
            cell.dot.onClick = { [weak self, weak cell] in
                guard let self, let id = cell?.faceID else { return }
                Task { await self.model.toggleActivation([id]) }
            }
            cell.dot.menuProvider = { [weak self, weak cell] in
                guard let self, let id = cell?.faceID else { return nil }
                let menu = NSMenu()
                menu.autoenablesItems = false
                for item in FontContextMenu.activationItems(for: [id], model: self.model) { menu.addItem(item) }
                return menu
            }
            view = cell
        default:
            view = makeCell(ListTextCell.identifier) { ListTextCell() }
        }
        configure(view, column: column, item: item)
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        let index = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.preview.rawValue))
        guard index >= 0, index < rowView.numberOfColumns,
              let id = (rowView.view(atColumn: index) as? ListPreviewCell)?.faceID else { return }
        // A family row and its face's own row can show the same face; keep the render if one is still visible.
        var stillShown = false
        forEachVisibleRow { _, item in if faceID(for: item) == id { stillShown = true } }
        if !stillShown { pipeline.cancel(faceID: id) }
    }

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        guard let column = ListColumn(rawValue: tableColumn.identifier.rawValue) else { return }
        if let sort = column.querySort {
            let hadLocalSort = localSort != nil
            localSort = nil
            if hadLocalSort, query?.sort == sort {
                // The query already sorts by this column: show its order again.
                queryChanged = true
                updateSortIndicators()
                applySorted()
            } else {
                // The new query flows back through update(query:) and update(families:).
                model.chooseSort(sort)
            }
        } else if column.sortsInMemory {
            let ascending = localSort?.column == column ? !(localSort?.ascending ?? false) : true
            localSort = (column, ascending)
            queryChanged = true
            updateSortIndicators()
            applySorted()
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let family = notification.userInfo?["NSObject"] as? FamilyNode else { return }
        expandedKeys.insert(family.key)
        schedulePrefetch()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let family = notification.userInfo?["NSObject"] as? FamilyNode else { return }
        expandedKeys.remove(family.key)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        pushSelection()
    }

    // MARK: Sort indicators

    private func updateSortIndicators() {
        guard let outlineView else { return }
        let active: ListColumn?
        let ascending: Bool
        if let localSort {
            active = localSort.column
            ascending = localSort.ascending
        } else if let query {
            active = ListColumn.forQuerySort(query.sort)
            ascending = query.ascending
        } else {
            active = nil
            ascending = true
        }
        var highlighted: NSTableColumn?
        for tc in outlineView.tableColumns {
            let isActive = tc.identifier.rawValue == active?.rawValue
            outlineView.setIndicatorImage(isActive ? NSImage(named: ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil,
                                          in: tc)
            if isActive { highlighted = tc }
        }
        outlineView.highlightedTableColumn = highlighted
    }

    // MARK: Column visibility (header menu)

    private static func hiddenColumns() -> Set<ListColumn> {
        guard let saved = UserDefaults.standard.stringArray(forKey: hiddenColumnsKey) else { return ListColumn.defaultHidden }
        return Set(saved.compactMap(ListColumn.init(rawValue:)))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for tc in outlineView.tableColumns {
            guard let column = ListColumn(rawValue: tc.identifier.rawValue) else { continue }
            let item = ClosureMenuItem(column.title) { [weak self] in self?.toggleColumn(column) }
            item.state = tc.isHidden ? .off : .on
            item.isEnabled = column.canHide
            menu.addItem(item)
        }
    }

    private func toggleColumn(_ column: ListColumn) {
        guard column.canHide,
              let tc = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue)) else { return }
        tc.isHidden.toggle()
        let hidden = outlineView.tableColumns.filter(\.isHidden).map(\.identifier.rawValue)
        UserDefaults.standard.set(hidden, forKey: Self.hiddenColumnsKey)
        if column == .preview, !tc.isHidden { settingsChanged() }
    }

    // MARK: Selection

    /// The selected faces: a family row stands for all of its (matching) faces.
    private func pushSelection() {
        var ids = Set<Int64>()
        for row in outlineView.selectedRowIndexes {
            switch outlineView.item(atRow: row) {
            case let face as FaceNode: ids.insert(face.faceID)
            case let family as FamilyNode: ids.formUnion(family.faceIDs)
            default: break
            }
        }
        selection = ids
        if model.selection != ids { model.selection = ids }
    }

    /// Selects the rows that show `selection`: a face's own row when its family is expanded, else the family row.
    /// A family with only some of its faces selected is expanded first, so the selection is shown (and pushed
    /// back) exactly: a family row always stands for all of its faces.
    private func applySelectionToOutline() {
        guard hasLoaded else { return }
        var selectedPerFamily: [ObjectIdentifier: (family: FamilyNode, count: Int)] = [:]
        for id in selection {
            guard let family = familyOfFace[id] else { continue }
            selectedPerFamily[ObjectIdentifier(family), default: (family, 0)].count += 1
        }
        applyingSelection = true
        for (family, count) in selectedPerFamily.values where count < family.faceIDs.count && !outlineView.isItemExpanded(family) {
            outlineView.expandItem(family)
        }
        applyingSelection = false
        var rows = IndexSet()
        for id in selection {
            guard let family = familyOfFace[id] else { continue }
            let item: AnyObject? = outlineView.isItemExpanded(family) ? family.child(for: id) : family
            if let item {
                let row = outlineView.row(forItem: item)
                if row >= 0 { rows.insert(row) }
            }
        }
        guard rows != outlineView.selectedRowIndexes else { return }
        applyingSelection = true
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
        applyingSelection = false
    }

    /// The selected faces in display order.
    private func orderedSelection() -> [Int64] {
        nodes.flatMap { $0.faceIDs.filter(selection.contains) }
    }

    // MARK: Activation and context menu

    /// Space: activates the selection, or deactivates it when every unlocked selected face is already active.
    func toggleSelectionActivation() {
        let ids = orderedSelection()
        guard !ids.isEmpty else { return }
        Task { await model.toggleActivation(ids) }
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row >= 0 else { return nil }
        if !outlineView.selectedRowIndexes.contains(row) {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            pushSelection()
        }
        let ids = orderedSelection()
        return ids.isEmpty ? nil : FontContextMenu.make(for: ids, model: model)
    }

    // MARK: Type to scroll

    /// A prefix is being typed: a Space continues it instead of toggling activation.
    var isTypeSelecting: Bool {
        !typedPrefix.isEmpty && Date().timeIntervalSince(lastTypeTime) <= Self.typeSelectWindow
    }

    /// Typed letters within 0.8 s of each other form a prefix; the first family starting with it is selected.
    func typeSelect(_ characters: String) {
        let now = Date()
        if now.timeIntervalSince(lastTypeTime) > Self.typeSelectWindow { typedPrefix = "" }
        lastTypeTime = now
        typedPrefix += characters
        let needle = typedPrefix.lowercased()
        guard let index = lowercasedNames.firstIndex(where: { $0.hasPrefix(needle) }) else { return }
        let row = outlineView.row(forItem: nodes[index])
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        pushSelection()
        scrollToCenter(row: row)
    }

    private func scrollToCenter(row: Int) {
        let rect = outlineView.rect(ofRow: row)
        let clip = scrollView.contentView
        let maxY = max(0, outlineView.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, rect.midY - clip.bounds.height / 2))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
