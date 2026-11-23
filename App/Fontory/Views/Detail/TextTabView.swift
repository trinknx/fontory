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
        .help(isEditing ? "Finish editing (Esc)" : "Edit the text (or double-click it)")
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
                    get: { model.textCustom == nil && model.textSample == sample },
                    set: { _ in model.chooseTextSample(sample) }))
            }
        } label: {
            Text(model.textCustom == nil ? model.textSample.title : "Edited Text")
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

/// Shows the specimen as rendered strips in a scroll view, re-rendered off the main actor when the settings change
/// and 150 ms after the width settles; or, while editing, a text view set in the same font (one column).
///
/// The editor uses the face's `CTFont` directly (toll-free bridged to `NSFont`), so nothing is registered with the
/// font manager.
final class BodyTextSpecimenView: NSView, NSTextViewDelegate {
    var onEdit: (String) -> Void = { _ in }
    var onRequestEditing: () -> Void = {}
    var onFinishEditing: () -> Void = {}

    private let renderer: PreviewRenderer
    private let scrollView = NSScrollView()
    private let documentView = SpecimenDocumentView()
    private var stripViews: [SpecimenStripView] = []
    private var editorScroll: NSScrollView?
    private var textView: SpecimenTextView?
    /// The config the editor's attributes were set from, text left out: typing does not restyle the whole text.
    private var editorStyleKey: SpecimenConfig?

    private var config: SpecimenConfig?
    private var isEditing = false

    private struct RenderKey: Equatable {
        let config: SpecimenConfig
        let width: CGFloat
        let scale: CGFloat
    }

    /// The key of the strips on screen, and of the render in flight.
    private var shownKey: RenderKey?
    private var pendingKey: RenderKey?
    private var work: Task<(CGSize, [BodyTextStrip])?, Never>?
    private var resizeTask: Task<Void, Never>?

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = documentView
        documentView.onDoubleClick = { [weak self] in self?.onRequestEditing() }
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    // MARK: Rendering

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
        let task = Task.detached(priority: .userInitiated) { () -> (CGSize, [BodyTextStrip])? in
            guard let font = renderer.font(fileURL: face.fileURL, faceIndex: face.faceIndex, pointSize: style.pointSize,
                                           features: features) else { return nil }
            let layout = BodyTextRenderer.layout(font: font, style: style)
            guard !Task.isCancelled else { return nil }
            let strips = BodyTextRenderer.render(layout, scale: scale, isCancelled: { Task.isCancelled })
            return Task.isCancelled ? nil : (layout.size, strips)
        }
        work = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.pendingKey == key, let result else { return }
            self.pendingKey = nil
            self.install(result.1, size: result.0, key: key)
        }
    }

    private func install(_ strips: [BodyTextStrip], size: CGSize, key: RenderKey) {
        // Keep the reading position: the same fraction of the text stays at the top.
        let clip = scrollView.contentView
        let oldHeight = documentView.frame.height
        let fraction = oldHeight > 1 ? clip.bounds.minY / oldHeight : 0
        clearStrips()
        documentView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: size.height))
        for strip in strips {
            let view = SpecimenStripView(image: strip.image, frame: strip.rect)
            documentView.addSubview(view)
            stripViews.append(view)
        }
        shownKey = key
        if fraction > 0 {
            let maxY = max(0, size.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maxY, (fraction * size.height).rounded())))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func clearStrips() {
        for view in stripViews { view.removeFromSuperview() }
        stripViews.removeAll()
        shownKey = nil
    }

    // MARK: Editing

    private func beginEditing() {
        work?.cancel()
        pendingKey = nil
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
        scrollView.isHidden = false
        render()
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
        if textReplaced { textView.string = style.text }
        guard textReplaced || styleKey != editorStyleKey else { return }
        editorStyleKey = styleKey
        let font: NSFont = renderer.font(fileURL: config.face.fileURL, faceIndex: config.face.faceIndex,
                                         pointSize: style.pointSize, features: config.features)
            .map { $0 as NSFont } ?? .systemFont(ofSize: style.pointSize)
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
