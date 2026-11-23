import AppKit
import FontoryCore
import SwiftUI

/// The Styles tab: every face of the family with its activation dot and a preview at the page's size, as big rows
/// or a compact list. An `NSTableView`, wrapped for SwiftUI; inputs are explicit so `updateNSView` runs exactly
/// when one changes.
struct FamilyStylesView: NSViewRepresentable {
    let model: AppModel
    let faceIDs: [Int64]
    let rowsVersion: Int
    let preview: PreviewSettings
    let pointSize: Double
    let layout: DetailLayout
    let selection: Set<Int64>

    func makeCoordinator() -> FamilyStylesController {
        FamilyStylesController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let c = context.coordinator
        // Size and settings first, so the first reload already lays out and renders at the right size.
        c.update(preview: preview, pointSize: CGFloat(pointSize), layout: layout)
        c.update(faceIDs: faceIDs)
        c.update(rowsVersion: rowsVersion)
        c.update(selection: selection)
    }
}

/// Data source and delegate of the styles table. Rows come from the model's cache, previews from the shared
/// `PreviewPipeline` (lane `detailStyles`).
@MainActor
final class FamilyStylesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let renderResumeDelay: Duration = .milliseconds(150)

    private let model: AppModel
    private let pipeline: PreviewPipeline
    private(set) var tableView: StylesTableView!
    private var scrollView: NSScrollView!

    private var faceIDs: [Int64] = []
    private var rowsVersion = 0
    private var preview = PreviewSettings()
    private var pointSize: CGFloat = 0
    private var layout: DetailLayout = .rows
    private var selection: Set<Int64> = []
    private var applyingSelection = false
    private var renderSuspended = false
    private var resumeTask: Task<Void, Never>?
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

    func makeScrollView() -> NSScrollView {
        let tv = StylesTableView()
        tv.controller = self
        tv.style = .inset
        tv.headerView = nil
        tv.allowsMultipleSelection = true
        tv.allowsEmptySelection = true
        tv.allowsTypeSelect = false
        tv.intercellSpacing = NSSize(width: 0, height: 4)
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("style"))
        column.resizingMask = .autoresizingMask
        tv.addTableColumn(column)
        tv.dataSource = self
        tv.delegate = self
        tv.setAccessibilityLabel("Styles")
        tableView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsFrameChangedNotifications = true
        scrollView = scroll

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widthChanged() }
        })
        observers.append(center.addObserver(forName: AppModel.rowsLoadedNotification, object: model, queue: .main) { [weak self] note in
            let ids = note.userInfo?[AppModel.rowIDsKey] as? [Int64] ?? []
            MainActor.assumeIsolated { self?.rowsLoaded(Set(ids)) }
        })
        return scroll
    }

    // MARK: Updates from SwiftUI

    func update(faceIDs new: [Int64]) {
        guard new != faceIDs else { return }
        faceIDs = new
        tableView.reloadData()
        model.prefetchRows(new)
        applySelection()
    }

    func update(rowsVersion new: Int) {
        guard new != rowsVersion else { return }
        rowsVersion = new
        // The row cache was dropped: fetch the family's rows again; cells keep their content until they arrive.
        model.prefetchRows(faceIDs)
    }

    func update(preview newPreview: PreviewSettings, pointSize newSize: CGFloat, layout newLayout: DetailLayout) {
        guard newPreview != preview || newSize != pointSize || newLayout != layout else { return }
        let sizeChanged = (newSize != pointSize || newLayout != layout) && pointSize != 0
        preview = newPreview
        pointSize = newSize
        layout = newLayout
        pipeline.cancelAll(lane: .detailStyles)
        let height = StyleCellView.rowHeight(layout: layout, pointSize: pointSize)
        if tableView.rowHeight != height {
            // Keep the first visible style's top edge where it is while rows grow or shrink.
            let visible = tableView.visibleRect
            let first = tableView.rows(in: visible).location
            let offset = first < tableView.numberOfRows ? tableView.rect(ofRow: first).minY - visible.minY : 0
            tableView.rowHeight = height
            if first > 0, first < tableView.numberOfRows {
                tableView.layoutSubtreeIfNeeded()
                let clip = scrollView.contentView
                let maxY = max(0, tableView.frame.height - clip.bounds.height)
                let y = min(maxY, max(0, tableView.rect(ofRow: first).minY - offset))
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        // Slider drags: show the previous images scaled, render once the size settles.
        if sizeChanged { suspendRendering() }
        reconfigureVisible()
    }

    func update(selection new: Set<Int64>) {
        guard new != selection else { return }
        selection = new
        applySelection()
    }

    private func applySelection() {
        let rows = IndexSet(faceIDs.indices.filter { selection.contains(faceIDs[$0]) })
        guard rows != tableView.selectedRowIndexes else { return }
        applyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        applyingSelection = false
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    private func pushSelection() {
        let ids = Set(tableView.selectedRowIndexes.compactMap { faceIDs.indices.contains($0) ? faceIDs[$0] : nil })
        selection = ids
        if model.detailSelection != ids { model.detailSelection = ids }
    }

    // MARK: Rendering

    private func widthChanged() {
        tableView.sizeLastColumnToFit()
        suspendRendering()
        reconfigureVisible()
    }

    private func suspendRendering() {
        renderSuspended = true
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: FamilyStylesController.renderResumeDelay)
            guard !Task.isCancelled, let self else { return }
            self.renderSuspended = false
            self.reconfigureVisible()
        }
    }

    private func forEachVisibleCell(_ body: (Int, StyleCellView) -> Void) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? StyleCellView { body(row, cell) }
        }
    }

    private func reconfigureVisible() {
        forEachVisibleCell { row, cell in configure(cell, row: row) }
    }

    private func rowsLoaded(_ ids: Set<Int64>) {
        forEachVisibleCell { row, cell in
            if faceIDs.indices.contains(row), ids.contains(faceIDs[row]) { configure(cell, row: row) }
        }
    }

    private func rendered(_ key: PreviewPipeline.Key, _ image: CGImage) {
        forEachVisibleCell { _, cell in
            if cell.wantedKey == key { cell.show(image: image) }
        }
    }

    private func configure(_ cell: StyleCellView, row index: Int) {
        guard faceIDs.indices.contains(index), pointSize > 0 else { return }
        let id = faceIDs[index]
        let row = model.cachedRow(id)
        cell.configure(faceID: id, row: row, layout: layout, background: preview.background)
        guard let row else {
            cell.wantedKey = nil
            model.prefetchRows(faceIDs)
            return
        }
        let width = tableView.bounds.width > 0 ? tableView.frameOfCell(atColumn: 0, row: index).width : 600
        let size = StyleCellView.previewSize(layout: layout, pointSize: pointSize, rowWidth: width)
        let key = DetailPreview.key(for: row, preview: preview, pointSize: StyleCellView.previewPointSize(layout: layout, pointSize: pointSize),
                                    size: size, scale: tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                                    styleNames: true)
        cell.wantedKey = key
        if let image = pipeline.image(for: key) {
            cell.show(image: image)
        } else if !renderSuspended, let url = row.fileURL {
            pipeline.request(key, fileURL: url, faceIndex: row.faceIndex, lane: .detailStyles)
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        faceIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: StyleCellView.identifier, owner: nil) as? StyleCellView) ?? StyleCellView()
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
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        if let id = (rowView.view(atColumn: 0) as? StyleCellView)?.faceID { pipeline.cancel(faceID: id, lane: .detailStyles) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        pushSelection()
    }

    // MARK: Keyboard and menu

    /// The selected styles in family order.
    private var orderedSelection: [Int64] {
        tableView.selectedRowIndexes.compactMap { faceIDs.indices.contains($0) ? faceIDs[$0] : nil }
    }

    /// Space: activates the selected styles, or deactivates them when none is off. Locked styles are skipped.
    func toggleSelectionActivation() {
        let ids = orderedSelection
        guard !ids.isEmpty else { return }
        Task { await model.toggleActivation(ids) }
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        let row = tableView.row(at: point)
        guard row >= 0 else { return nil }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            pushSelection()
        }
        let ids = orderedSelection
        return ids.isEmpty ? nil : FontContextMenu.make(for: ids, model: model)
    }

    func settingsChanged() {
        pipeline.cancelAll(lane: .detailStyles)
        reconfigureVisible()
    }
}

/// The styles table: Space, the context menu, and the keyboard focus when it appears.
final class StylesTableView: NSTableView {
    weak var controller: FamilyStylesController?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The browser gave up the keyboard when the page opened; Space and the arrows act on the styles.
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if mods.isEmpty, event.characters == " " {
            controller?.toggleSelectionActivation()
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

/// One style: activation dot, style name (and PostScript name in rows), offline badge and the preview.
final class StyleCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("StyleCell")
    static let inset: CGFloat = 8
    static let labelStrip: CGFloat = 24
    static let compactNameWidth: CGFloat = 200
    static let compactMaxPointSize = CGFloat(AppModel.compactMaxPointSize)

    static func previewPointSize(layout: DetailLayout, pointSize: CGFloat) -> CGFloat {
        layout == .rows ? pointSize : min(pointSize, compactMaxPointSize)
    }

    static func rowHeight(layout: DetailLayout, pointSize: CGFloat) -> CGFloat {
        let preview = ceil(previewPointSize(layout: layout, pointSize: pointSize) * 1.5)
        switch layout {
        case .rows: return labelStrip + preview + inset
        case .compact: return max(28, preview + 6)
        }
    }

    /// The preview area of a row `rowWidth` wide.
    static func previewSize(layout: DetailLayout, pointSize: CGFloat, rowWidth: CGFloat) -> CGSize {
        let height = rowHeight(layout: layout, pointSize: pointSize)
        switch layout {
        case .rows:
            return CGSize(width: max(1, rowWidth - inset * 2), height: max(1, height - labelStrip - inset))
        case .compact:
            return CGSize(width: max(1, rowWidth - compactPreviewX - inset), height: max(1, height - 6))
        }
    }

    private static var compactPreviewX: CGFloat { inset + 22 + compactNameWidth + 8 }

    private(set) var faceID: Int64?
    var wantedKey: PreviewPipeline.Key?
    let dot = ActivationDot()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let offlineBadge = NSImageView()
    private let previewLayer = CALayer()
    private var layoutMode: DetailLayout = .rows

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        previewLayer.masksToBounds = true
        previewLayer.cornerRadius = 4
        layer?.addSublayer(previewLayer)

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        offlineBadge.image = NSImage(systemSymbolName: "externaldrive.badge.xmark", accessibilityDescription: "Offline")
        offlineBadge.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        offlineBadge.contentTintColor = .secondaryLabelColor
        offlineBadge.toolTip = "The file’s location is offline"
        offlineBadge.isHidden = true
        for v in [dot, nameLabel, detailLabel, offlineBadge] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = Self.inset
        switch layoutMode {
        case .rows:
            let midY = Self.labelStrip / 2 + 1
            dot.frame = CGRect(x: inset - 2, y: midY - 9, width: 18, height: 18)
            let nameWidth = min(nameLabel.intrinsicContentSize.width, max(40, b.width * 0.5))
            nameLabel.frame = CGRect(x: inset + 20, y: midY - 9, width: nameWidth, height: 18)
            offlineBadge.frame = CGRect(x: nameLabel.frame.maxX + 4, y: midY - 8, width: offlineBadge.isHidden ? 0 : 16, height: 16)
            let detailX = offlineBadge.frame.maxX + 8
            detailLabel.frame = CGRect(x: detailX, y: midY - 8, width: max(0, b.width - detailX - inset), height: 16)
            detailLabel.isHidden = false
            previewLayer.frame = CGRect(x: inset, y: Self.labelStrip, width: max(1, b.width - inset * 2),
                                        height: max(1, b.height - Self.labelStrip - inset))
        case .compact:
            let midY = b.height / 2
            dot.frame = CGRect(x: inset - 2, y: midY - 9, width: 18, height: 18)
            let badgeWidth: CGFloat = offlineBadge.isHidden ? 0 : 20
            nameLabel.frame = CGRect(x: inset + 20, y: midY - 9, width: Self.compactNameWidth - badgeWidth, height: 18)
            offlineBadge.frame = CGRect(x: nameLabel.frame.maxX + 4, y: midY - 8, width: badgeWidth == 0 ? 0 : 16, height: 16)
            detailLabel.isHidden = true
            let x = Self.compactPreviewX
            previewLayer.frame = CGRect(x: x, y: 3, width: max(1, b.width - x - inset), height: max(1, b.height - 6))
        }
    }

    func configure(faceID: Int64, row: FaceRow?, layout: DetailLayout, background: CGColor) {
        let sameFace = self.faceID == faceID
        if !sameFace { previewLayer.contents = nil }
        self.faceID = faceID
        if layoutMode != layout {
            layoutMode = layout
            needsLayout = true
        }
        previewLayer.backgroundColor = background
        guard let row else {
            // The rows were dropped and are being fetched again: keep showing this face until they arrive.
            if sameFace { return }
            nameLabel.stringValue = ""
            detailLabel.stringValue = ""
            dot.state = .placeholder
            dot.isOffline = false
            offlineBadge.isHidden = true
            toolTip = nil
            return
        }
        let name = row.style.isEmpty ? row.fullName : row.style
        if nameLabel.stringValue != name { nameLabel.stringValue = name; needsLayout = true }
        detailLabel.stringValue = row.postScriptName
        toolTip = row.fullName
        dot.state = ActivationDot.State(row.activationStatus)
        dot.isOffline = !row.online
        if offlineBadge.isHidden != row.online { offlineBadge.isHidden = row.online; needsLayout = true }
        previewLayer.opacity = row.online ? 1 : 0.4
        setAccessibilityLabel(row.fullName)
    }

    func show(image: CGImage?) {
        guard let image else { return }
        previewLayer.contents = image
    }
}
