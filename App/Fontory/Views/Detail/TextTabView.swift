import AppKit
import FontoryCore
import SwiftUI

/// The Text tab: a body-text specimen of the focused style, set in balanced columns by `BodyTextRenderer` off the
/// main actor, editable in place, with a bottom bar (style, sample, edit, reset, columns, alignment, guides, size,
/// line height).
struct TextTabView: View {
    @Bindable var model: AppModel
    let detail: FamilyDetail
    let faceID: Int64

    @State private var face: SpecimenFace?
    @State private var failure: String?
    @State private var loadedID: Int64?
    @State private var isEditing = false
    @State private var styleNames: [Int64: String] = [:]

    private struct LoadKey: Equatable {
        let faceID: Int64
        let rowsVersion: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            specimen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .task(id: LoadKey(faceID: faceID, rowsVersion: model.rowsVersion)) { await load() }
        .onAppear { updateStyleNames() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.rowsLoadedNotification, object: model)) { _ in
            updateStyleNames()
        }
    }

    // MARK: Specimen

    @ViewBuilder
    private var specimen: some View {
        if let failure, loadedID == faceID {
            ContentUnavailableView(failure, systemImage: "text.alignleft")
        } else if let face {
            BodyTextSpecimen(renderer: model.previewRenderer, config: config(face), isEditing: isEditing,
                             onEdit: { model.textCustom = $0 },
                             onRequestEditing: { isEditing = true },
                             onFinishEditing: { isEditing = false })
                .opacity(loadedID == faceID ? 1 : 0.5)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// The text shown: the edited text, or the chosen sample.
    private var text: String {
        model.textCustom ?? model.text(of: model.textSample, row: model.cachedRow(faceID))
    }

    private func config(_ face: SpecimenFace) -> SpecimenConfig {
        let preview = model.preview
        var style = BodyTextStyle(text: text, pointSize: CGFloat(model.textPointSize), foreground: preview.foreground,
                                  background: preview.background, width: 0)
        style.lineHeight = CGFloat(model.textLineHeight)
        style.tracking = CGFloat(preview.tracking)
        style.alignment = model.textAlignment.ctAlignment
        style.columns = model.textColumns
        style.showGuides = preview.showGuides
        return SpecimenConfig(face: face, style: style, features: preview.features, alignment: model.textAlignment)
    }

    private func load() async {
        let id = faceID
        model.prefetchRows(detail.faceIDs)
        guard let info = await model.faceInfo(id), !Task.isCancelled else {
            if !Task.isCancelled { fail("This style is no longer in the library.", id) }
            return
        }
        guard info.online else { return fail("The file of this style is offline.", id) }
        let renderer = model.previewRenderer
        let url = info.fileURL, index = info.faceIndex
        // Load (and cache) the face off the main actor, so the specimen and the editor find it ready.
        let readable = await Task.detached(priority: .userInitiated) {
            renderer.font(fileURL: url, faceIndex: index, pointSize: 1) != nil
        }.value
        guard !Task.isCancelled else { return }
        guard readable else { return fail("This font file could not be read.", id) }
        failure = nil
        face = SpecimenFace(faceID: id, fileURL: url, faceIndex: index)
        loadedID = id
        updateStyleNames()
    }

    private func fail(_ message: String, _ id: Int64) {
        failure = message
        isEditing = false
        loadedID = id
    }

    // MARK: Bottom bar

    /// One row when the page is wide enough, otherwise text controls above layout controls.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                textControls
                Spacer(minLength: 4)
                layoutControls
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    textControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    layoutControls
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Style, sample, Edit and Reset Text.
    @ViewBuilder
    private var textControls: some View {
        if detail.faceIDs.count > 1 { stylePicker }
        sampleMenu
        Toggle(isOn: $isEditing) {
            Label(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil")
        }
        .toggleStyle(.button)
        .help(isEditing ? "Finish editing (Esc)"
              : "Edit the text, up to \(AppModel.maxTextLength.formatted()) characters (or double-click it)")
        .disabled(face == nil || (failure != nil && loadedID == faceID))
        Button("Reset Text") { model.textCustom = nil }
            .disabled(model.textCustom == nil)
            .help("Restore the \(model.textSample.title) sample")
    }

    /// Columns, alignment, guides, size and line height.
    @ViewBuilder
    private var layoutControls: some View {
        Picker("Columns", selection: $model.textColumns) {
            Image(systemName: "rectangle").help("One column").tag(1)
            Image(systemName: "rectangle.split.2x1").help("Two columns").tag(2)
            Image(systemName: "rectangle.split.3x1").help("Three columns").tag(3)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Columns")
        Picker("Alignment", selection: $model.textAlignment) {
            ForEach(BodyTextAlignment.allCases, id: \.self) { a in
                Image(systemName: a.symbol).help(a.title).tag(a)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Alignment")
        OptionToggle(help: "Guides: baseline and x-height of every line", isOn: $model.preview.showGuides) {
            Image(systemName: "ruler")
        }
        sizeControl
        lineHeightControl
    }

    private var sampleMenu: some View {
        Menu {
            ForEach(TextSample.allCases, id: \.self) { sample in
                Toggle(sample.title, isOn: Binding(
                    get: { model.textSample == sample },
                    set: { _ in model.chooseTextSample(sample) }))
            }
        } label: {
            Text(model.textCustom == nil ? model.textSample.title : "\(model.textSample.title) (Edited)")
        }
        .fixedSize()
        .help("Sample text")
    }

    private var sizeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "textformat.size").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(get: { model.textPointSize }, set: { model.textPointSize = $0.rounded() }),
                   in: AppModel.textPointSizeRange)
                .frame(width: 90)
                .accessibilityLabel("Text size")
                .help("Text size (⌘+ / ⌘−)")
            Text("\(Int(model.textPointSize)) pt")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var lineHeightControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.and.down.text.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(get: { model.textLineHeight },
                                  set: { model.textLineHeight = ($0 * 20).rounded() / 20 }),
                   in: AppModel.textLineHeightRange)
                .frame(width: 80)
                .accessibilityLabel("Line height")
                .help("Line height, as a multiple of the text size")
            Text(model.textLineHeight.formatted(.number.precision(.fractionLength(2))))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var stylePicker: some View {
        Picker("Style", selection: Binding(get: { faceID }, set: { model.detailSelection = [$0] })) {
            ForEach(detail.faceIDs, id: \.self) { id in
                Text(styleNames[id] ?? "Style \(detail.faceIDs.firstIndex(of: id).map { $0 + 1 } ?? 0)").tag(id)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("The style the text is set in")
    }

    private func updateStyleNames() {
        var names = styleNames
        for id in detail.faceIDs {
            if let row = model.cachedRow(id) { names[id] = row.style.isEmpty ? row.fullName : row.style }
        }
        if names != styleNames { styleNames = names }
    }
}

// MARK: Specimen view

struct SpecimenFace: Equatable, Sendable {
    let faceID: Int64
    let fileURL: URL
    let faceIndex: Int
}

/// Everything the specimen shows, except the width (the view's own).
struct SpecimenConfig: Equatable {
    var face: SpecimenFace
    /// Its width is ignored; the view fills it in.
    var style: BodyTextStyle
    var features: PreviewFeatures
    var alignment: BodyTextAlignment
}

struct BodyTextSpecimen: NSViewRepresentable {
    let renderer: PreviewRenderer
    let config: SpecimenConfig
    let isEditing: Bool
    let onEdit: (String) -> Void
    let onRequestEditing: () -> Void
    let onFinishEditing: () -> Void

    func makeNSView(context: Context) -> BodyTextSpecimenView {
        BodyTextSpecimenView(renderer: renderer)
    }

    func updateNSView(_ view: BodyTextSpecimenView, context: Context) {
        view.onEdit = onEdit
        view.onRequestEditing = onRequestEditing
        view.onFinishEditing = onFinishEditing
        view.update(config: config, editing: isEditing)
    }
}

/// Shows the specimen in a scroll view, or, while editing, a text view set in the same font (one column).
///
/// The text is laid out once per settings/width change, off the main actor (width changes wait 150 ms to settle).
/// Only the strips in or next to the viewport are drawn, also off the main actor, and at most
/// `BodyTextStripCache.limit` are kept, so memory follows the window, not the length of the text.
///
/// The editor uses the face's `CTFont` directly (toll-free bridged to `NSFont`), so nothing is registered with the
/// font manager.
final class BodyTextSpecimenView: NSView, NSTextViewDelegate {
    var onEdit: (String) -> Void = { _ in }
    var onRequestEditing: () -> Void = {}
    var onFinishEditing: () -> Void = {}

    static let stripHeight: CGFloat = 512
    static let stripLimit = 6

    private let renderer: PreviewRenderer
    private let scrollView = NSScrollView()
    private let documentView = SpecimenDocumentView()

    private var config: SpecimenConfig?
    private var isEditing = false

    private struct RenderKey: Equatable {
        let config: SpecimenConfig
        let width: CGFloat
        let scale: CGFloat
    }

    // Layout
    /// The key of the layout on screen, and of the layout in flight.
    private var shownKey: RenderKey?
    private var pendingKey: RenderKey?
    private var work: Task<BodyTextLayout?, Never>?
    private var resizeTask: Task<Void, Never>?
    private var shownLayout: BodyTextLayout?

    // Strips of the shown layout
    private var cache: BodyTextStripCache?
    private var stripViews: [Int: SpecimenStripView] = [:]
    /// The previous layout's strips, kept until the new layout's visible strips are drawn (no blank flash).
    private var staleViews: [SpecimenStripView] = []
    /// Strip renders in flight; one leaving the wanted set is cancelled (it is not drawn if it has not started).
    private var stripTasks: [Int: Task<Void, Never>] = [:]
    private var layoutGeneration = 0
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    // Editor
    private var editorScroll: NSScrollView?
    private var textView: SpecimenTextView?
    /// The config the editor's attributes were set from, text left out: typing does not restyle the whole text.
    private var editorStyleKey: SpecimenConfig?
    /// The editor's own undo history, cleared when the text is replaced (sample menu, Reset Text).
    private var editorUndo = UndoManager()

    private struct FontKey: Equatable {
        let face: SpecimenFace
        let pointSize: CGFloat
        let features: PreviewFeatures
    }

    /// The editor's font, loaded off the main actor.
    private var editorFont: (key: FontKey, font: CTFont)?
    private var editorFontTask: Task<Void, Never>?
    private var editorFontLoading: FontKey?
    /// A font that failed to load: not loaded again (nor the editor restyled) on every keystroke.
    private var editorFontFailed: FontKey?

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        documentView.onDoubleClick = { [weak self] in self?.onRequestEditing() }
        addSubview(scrollView)
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibleStrips() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func update(config new: SpecimenConfig, editing: Bool) {
        // A new face keeps the previous strips (dimmed by the tab) until its own arrive: no blank flash.
        config = new
        let background = NSColor(cgColor: new.style.background) ?? .textBackgroundColor
        scrollView.backgroundColor = background
        documentView.setAccessibilityValue(new.style.text)
        if editing != isEditing {
            isEditing = editing
            editing ? beginEditing() : endEditing()
        }
        if isEditing {
            applyEditorStyle()
        } else {
            render()
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        editorScroll?.frame = bounds
        let width = scrollView.contentSize.width
        if documentView.frame.width != width {
            documentView.setFrameSize(NSSize(width: width, height: max(documentView.frame.height, 1)))
        }
        updateVisibleStrips()
        guard !isEditing, let shownKey, shownKey.width != width.rounded(.down) else {
            if shownKey == nil { render() }
            return
        }
        // Later widths wait until resizing settles; the old strips stay meanwhile.
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

    // MARK: Layout

    private func render() {
        guard let config, !isEditing, window != nil else { return }
        let width = scrollView.contentSize.width.rounded(.down)
        guard width > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let key = RenderKey(config: config, width: width, scale: scale)
        guard key != shownKey, key != pendingKey else { return }
        pendingKey = key
        work?.cancel()
        var style = config.style
        style.width = width
        let renderer = self.renderer, face = config.face, features = config.features
        let task = Task.detached(priority: .userInitiated) { () -> BodyTextLayout? in
            guard let font = renderer.font(fileURL: face.fileURL, faceIndex: face.faceIndex, pointSize: style.pointSize,
                                           features: features) else { return nil }
            let layout = BodyTextRenderer.layout(font: font, style: style)
            return Task.isCancelled ? nil : layout
        }
        work = task
        Task { [weak self] in
            let layout = await task.value
            guard let self, self.pendingKey == key else { return }
            // Also on failure, so the same settings can be tried again later.
            self.pendingKey = nil
            guard let layout else { return }
            self.install(layout, key: key)
        }
    }

    private func install(_ layout: BodyTextLayout, key: RenderKey) {
        // Keep the reading position: the same fraction of the text stays at the top.
        let clip = scrollView.contentView
        let oldHeight = documentView.frame.height
        let fraction = oldHeight > 1 ? clip.bounds.minY / oldHeight : 0
        staleViews += stripViews.values
        stripViews.removeAll()
        cancelStripTasks()
        layoutGeneration &+= 1
        shownLayout = layout
        shownKey = key
        cache = BodyTextStripCache(layoutSize: layout.size, stripHeight: Self.stripHeight, limit: Self.stripLimit)
        documentView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: layout.size.height))
        if fraction > 0 {
            let maxY = max(0, layout.size.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maxY, (fraction * layout.size.height).rounded())))
            scrollView.reflectScrolledClipView(clip)
        }
        updateVisibleStrips()
    }

    // MARK: Strips

    private var wantedStrips: [Int] {
        cache?.indices(near: scrollView.contentView.bounds) ?? []
    }

    /// Shows the cached strips near the viewport and draws the missing ones; renders of strips scrolled away are
    /// cancelled.
    private func updateVisibleStrips() {
        guard let cache, let layout = shownLayout, let key = shownKey, !isEditing else { return }
        let wanted = wantedStrips
        let wantedSet = Set(wanted)
        for (i, task) in stripTasks where !wantedSet.contains(i) {
            task.cancel()
            stripTasks[i] = nil
        }
        for i in wanted {
            if let image = cache.image(at: i) {
                if stripViews[i] == nil { addStripView(i, image) }
            } else if stripTasks[i] == nil {
                let generation = layoutGeneration, rect = cache.rect(at: i), scale = key.scale
                stripTasks[i] = Task.detached(priority: .userInitiated) { [weak self] in
                    guard !Task.isCancelled else { return }
                    let image = BodyTextRenderer.render(layout, scale: scale, rect: rect).map(StripImage.init)
                    guard !Task.isCancelled else { return }
                    await self?.stripFinished(i, image, generation: generation)
                }
            }
        }
        dropStaleViewsIfCovered()
    }

    /// A strip render ended (not cancelled before reaching the main actor).
    private func stripFinished(_ i: Int, _ image: StripImage?, generation: Int) {
        // Cancelled while waiting for the main actor: a newer task may own the index now.
        guard !Task.isCancelled, generation == layoutGeneration else { return }
        stripTasks[i] = nil
        guard let image else { return }
        stripArrived(i, image.image)
    }

    private func cancelStripTasks() {
        for task in stripTasks.values { task.cancel() }
        stripTasks.removeAll()
    }

    private func stripArrived(_ i: Int, _ image: CGImage) {
        guard let cache else { return }
        let wanted = wantedStrips
        for dropped in cache.insert(image, at: i, keeping: Set(wanted)) {
            stripViews.removeValue(forKey: dropped)?.removeFromSuperview()
        }
        if cache.image(at: i) != nil, stripViews[i] == nil { addStripView(i, image) }
        dropStaleViewsIfCovered()
    }

    private func addStripView(_ i: Int, _ image: CGImage) {
        guard let cache else { return }
        let view = SpecimenStripView(image: image, frame: cache.rect(at: i))
        documentView.addSubview(view)
        stripViews[i] = view
    }

    /// The previous layout's strips go once every visible strip of the new one is drawn.
    private func dropStaleViewsIfCovered() {
        guard !staleViews.isEmpty, wantedStrips.allSatisfy({ stripViews[$0] != nil }) else { return }
        for view in staleViews { view.removeFromSuperview() }
        staleViews.removeAll()
    }

    // MARK: Editing

    private func beginEditing() {
        work?.cancel()
        pendingKey = nil
        editorUndo = UndoManager()
        let scroll = NSScrollView(frame: bounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = SpecimenTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFontPanel = false
        textView.onEscape = { [weak self] in self?.onFinishEditing() }
        textView.string = config?.style.text ?? ""
        textView.delegate = self
        scroll.documentView = textView
        addSubview(scroll)
        editorScroll = scroll
        self.textView = textView
        scrollView.isHidden = true
        applyEditorStyle()
        window?.makeFirstResponder(textView)
    }

    private func endEditing() {
        if let textView, window?.firstResponder === textView { window?.makeFirstResponder(nil) }
        textView?.delegate = nil
        editorScroll?.removeFromSuperview()
        editorScroll = nil
        textView = nil
        editorStyleKey = nil
        editorFontTask?.cancel()
        editorFontLoading = nil
        editorFontFailed = nil
        editorUndo.removeAllActions()
        scrollView.isHidden = false
        render()
    }

    /// The editor's font for `config`: the cached one, the shown layout's when it matches, else nil while it loads
    /// off the main actor (the editor is restyled when it arrives).
    private func editorFont(for config: SpecimenConfig) -> CTFont? {
        let key = FontKey(face: config.face, pointSize: config.style.pointSize, features: config.features)
        if let editorFont, editorFont.key == key { return editorFont.font }
        if let layout = shownLayout, let shown = shownKey,
           FontKey(face: shown.config.face, pointSize: shown.config.style.pointSize, features: shown.config.features) == key {
            editorFont = (key, layout.font)
            return layout.font
        }
        guard editorFontLoading != key, editorFontFailed != key else { return nil }
        editorFontTask?.cancel()
        editorFontLoading = key
        let renderer = self.renderer
        editorFontTask = Task { [weak self] in
            let box = await Task.detached(priority: .userInitiated) {
                renderer.font(fileURL: key.face.fileURL, faceIndex: key.face.faceIndex, pointSize: key.pointSize,
                              features: key.features).map(FontBox.init)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.editorFontLoading = nil
            guard let font = box?.font else {
                self.editorFontFailed = key
                return
            }
            self.editorFont = (key, font)
            self.editorStyleKey = nil   // restyle with the new font
            self.applyEditorStyle()
        }
        return nil
    }

    /// Sets the editor's font, colors, spacing and alignment from the config; replaces its text only when the text
    /// changed elsewhere (sample menu, Reset Text).
    private func applyEditorStyle() {
        guard let textView, let config else { return }
        let style = config.style
        // Never touch the text while an input method is composing (Vietnamese Telex, Japanese…).
        guard !textView.hasMarkedText() else { return }
        var styleKey = config
        styleKey.style.text = ""
        let textReplaced = textView.string != style.text
        if textReplaced {
            textView.string = style.text
            editorUndo.removeAllActions()   // undoing into the replaced text would be confusing
        }
        guard textReplaced || styleKey != editorStyleKey else { return }
        let loaded = editorFont(for: config)
        // Until the face loads, keep the editor's current font (no system-font flash).
        let font: NSFont = loaded.map { $0 as NSFont } ?? textView.font ?? .systemFont(ofSize: style.pointSize)
        // A face that failed to load keeps the current font: styled once, not again on every keystroke.
        let failed = editorFontFailed == FontKey(face: config.face, pointSize: style.pointSize, features: config.features)
        if loaded != nil || failed { editorStyleKey = styleKey }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = config.alignment.nsAlignment
        paragraph.minimumLineHeight = style.lineSpacing
        paragraph.maximumLineHeight = style.lineSpacing
        paragraph.paragraphSpacing = style.paragraphSpacing
        let foreground = NSColor(cgColor: style.foreground) ?? .textColor
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph]
        if style.tracking != 0 { attributes[.kern] = style.tracking }
        textView.backgroundColor = NSColor(cgColor: style.background) ?? .textBackgroundColor
        editorScroll?.backgroundColor = textView.backgroundColor
        textView.insertionPointColor = foreground
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        onEdit(textView.string)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        editorUndo
    }

    /// The text is capped at `AppModel.maxTextLength` UTF-16 units; a change past it beeps (shortening is allowed).
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        let current = (textView.string as NSString).length
        let next = current - range.length + (replacementString.map { ($0 as NSString).length } ?? 0)
        guard next > AppModel.maxTextLength, next > current else { return true }
        NSSound.beep()
        return false
    }
}

/// A rendered strip crossing actors (CGImage is immutable).
private struct StripImage: @unchecked Sendable {
    let image: CGImage
}

/// A CTFont crossing actors: CoreText fonts are immutable and thread-safe.
private struct FontBox: @unchecked Sendable {
    let font: CTFont
}

/// The scroll view's document: flipped, so the specimen starts at the top. Double-click starts editing.
private final class SpecimenDocumentView: NSView {
    var onDoubleClick: () -> Void = {}

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Text specimen")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick() } else { super.mouseDown(with: event) }
    }
}

/// One rendered strip, shown as its layer's contents.
private final class SpecimenStripView: NSView {
    private let image: CGImage

    init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The editor: Esc finishes editing.
private final class SpecimenTextView: NSTextView {
    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}
