import AppKit
import FontoryCore
import os
import SwiftUI

// MARK: Toolbar button and popover

/// Toolbar button that opens the preview popover below itself. The popover is an `NSPopover` with semitransient
/// behavior, so the color panel opened from its color wells does not close it; clicking the browser or Esc does.
struct PreviewOptionsButton: View {
    @Bindable var model: AppModel
    @State private var controller = PreviewPopoverController()

    var body: some View {
        Button {
            // A click on this button while the popover is open first closes it (semitransient: on mouse-down),
            // then runs this action on mouse-up. That click means "close", not "open again".
            model.isShowingPreviewOptions = !(controller.isShown || controller.closedByCurrentClick)
        } label: {
            Label("Preview", systemImage: "character.cursor.ibeam")
        }
        .help("Preview text and options (⌥⌘P)")
        .background(AnchorReader { controller.anchorView = $0 })
        .onChange(of: model.isShowingPreviewOptions) { _, show in
            // Out of the SwiftUI update, so AppKit can open its window transaction.
            DispatchQueue.main.async {
                if show { controller.show(model: model) } else { controller.close() }
            }
        }
    }
}

@MainActor
final class PreviewPopoverController: NSObject, NSPopoverDelegate {
    private static let log = Logger(subsystem: "local.fontory.app", category: "preview")
    weak var anchorView: NSView?
    private var popover: NSPopover?
    /// The popover between its will-close and did-close notifications; a did-close of any other popover is ignored,
    /// so the after-close action cannot run against a popover opened meanwhile.
    private var closingPopover: NSPopover?
    private weak var model: AppModel?
    /// Event number of the mouse click that closed the popover. Mouse-down and mouse-up of one click share it.
    private var closingClick: Int?

    var isShown: Bool { popover != nil }

    /// The current event is the same click that closed the popover.
    var closedByCurrentClick: Bool {
        guard let closingClick, let event = NSApp.currentEvent, Self.isMouseClick(event) else { return false }
        return event.eventNumber == closingClick
    }

    private static func isMouseClick(_ event: NSEvent) -> Bool {
        [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type)
    }

    func show(model: AppModel) {
        guard popover == nil else { return }
        self.model = model
        guard let view = anchorView, view.window != nil else {
            Self.log.error("preview popover has no anchor in a window")
            model.isShowingPreviewOptions = false
            return
        }
        let hosting = NSHostingController(rootView: PreviewOptionsView(model: model))
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = hosting
        popover.delegate = self
        self.popover = popover
        closingClick = nil
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
    }

    /// The popover counts as closed from here on, so ⌥⌘P during the close animation opens a new one.
    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === popover else { return }
        popover = nil
        closingPopover = closing
        closingClick = NSApp.currentEvent.flatMap { Self.isMouseClick($0) ? $0.eventNumber : nil }
        if model?.isShowingPreviewOptions == true { model?.isShowingPreviewOptions = false }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === closingPopover else { return }
        closingPopover = nil
        guard let model, let action = model.afterPreviewOptionsClose else { return }
        model.afterPreviewOptionsClose = nil
        // Next turn of the run loop: never inside the close animation's CA commit.
        DispatchQueue.main.async { action() }
    }
}

/// Hands out the AppKit view it is placed in, to anchor the popover.
private struct AnchorReader: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onView(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Popover content

struct PreviewOptionsView: View {
    @Bindable var model: AppModel
    @FocusState private var textFocused: Bool
    @State private var showsColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            textField
            optionRow
            trackingRow
            if showsColors { colorRow }
        }
        .padding(12)
        .frame(width: 470)
        .onAppear { DispatchQueue.main.async { textFocused = true } }
        .onExitCommand { model.isShowingPreviewOptions = false }
    }

    // Row 1: the preview text with the preset menu inside the field.

    private var textBinding: Binding<String> {
        Binding(get: { model.preview.showsFontNames ? "" : model.preview.text },
                set: { new in
                    guard new != model.preview.text || model.preview.showsFontNames else { return }
                    model.preview.text = new
                    model.preview.showsFontNames = false
                    model.preview.textSource = nil
                })
    }

    private var placeholder: String {
        if model.preview.showsFontNames { return "Font Names" }
        return "Enter text to preview"
    }

    private var textField: some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: textBinding)
                .textFieldStyle(.plain)
                .focused($textFocused)
                .padding(.leading, 7)
            if !model.preview.text.isEmpty || model.preview.showsFontNames {
                Button {
                    model.preview.text = ""
                    model.preview.showsFontNames = false
                    model.preview.textSource = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear (back to Dynamic)")
            }
            PresetMenu(model: model)
        }
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // Row 2: option toggles.

    private var optionRow: some View {
        HStack(spacing: 3) {
            Picker("Alignment", selection: $model.preview.alignment) {
                ForEach(PreviewAlignment.allCases, id: \.self) { alignment in
                    Image(systemName: alignment.symbol).help(alignment.title).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Alignment")
            separator
            OptionToggle(help: "Auto Size: equal ink height in every cell", isOn: $model.preview.autoSize) {
                Image(systemName: "textformat.size")
            }
            OptionToggle(help: "Metrics guides: baseline, x-height, cap height, ascender, descender",
                         isOn: $model.preview.showGuides) {
                Image(systemName: "ruler")
            }
            OptionToggle(help: "Show missing glyphs as ◌ instead of a fallback font", isOn: $model.preview.showMissingGlyphs) {
                Image(systemName: "circle.dotted")
            }
            OptionToggle(help: "Outline", isOn: $model.preview.outline) {
                Image(systemName: "pencil.and.outline")
            }
            OptionToggle(help: "Underline", isOn: $model.preview.underline) {
                Image(systemName: "underline")
            }
            separator
            OptionToggle(help: "Ligatures (liga)", isOn: $model.preview.ligatures) {
                Text("fi").font(.system(size: 14, design: .serif))
            }
            OptionToggle(help: "Discretionary ligatures (dlig)", isOn: $model.preview.discretionaryLigatures) {
                Text("ct").font(.system(size: 14, design: .serif).italic())
            }
            OptionToggle(help: "Alternates and swashes (salt, swsh)", isOn: $model.preview.alternates) {
                Image(systemName: "textformat.alt")
            }
            OptionToggle(help: "Small caps (smcp; c2sc for all-capital text)", isOn: $model.preview.smallCaps) {
                Text("Sc").font(.system(size: 13).smallCaps())
            }
            separator
            OptionToggle(help: "Colors", isOn: colorsBinding) {
                Image(systemName: "paintpalette")
            }
        }
    }

    /// Shows the color row; tinted while it is open or while the colors differ from the defaults.
    private var colorsBinding: Binding<Bool> {
        Binding(get: { showsColors || !model.preview.hasDefaultColors },
                set: { _ in showsColors.toggle() })
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 3)
    }

    private var trackingRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right.text.vertical")
                .foregroundStyle(.secondary)
                .help("Tracking")
            Slider(value: $model.preview.tracking, in: -5...20)
                .controlSize(.small)
                .frame(width: 160)
                .help("Tracking")
            Text("\(model.preview.tracking.formatted(.number.precision(.fractionLength(1)))) pt")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            if model.preview.tracking != 0 {
                Button("Reset") { model.preview.tracking = 0 }
                    .controlSize(.small)
            }
            Spacer()
            OptionToggle(help: "Font smoothing", isOn: $model.preview.smoothing) {
                Image(systemName: "circle.lefthalf.filled")
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 12) {
            ColorPicker("Text", selection: $model.preview.foreground, supportsOpacity: false)
            ColorPicker("Background", selection: $model.preview.background, supportsOpacity: false)
            Spacer()
            Button("Reset") {
                model.preview.foreground = PreviewSettings.defaultForeground
                model.preview.background = PreviewSettings.defaultBackground
            }
            .controlSize(.small)
            .disabled(model.preview.hasDefaultColors)
        }
        .font(.callout)
    }
}

/// An icon button that toggles an option; tinted while on.
struct OptionToggle<Content: View>: View {
    let help: String
    @Binding var isOn: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Toggle(isOn: $isOn) { content }
            .toggleStyle(IconToggleStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .frame(width: 26, height: 22)
                .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Color.accentColor.opacity(0.16) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Preset menu

/// The ⌄ menu inside the preview field: Dynamic, fixed samples, languages and saved presets. The active choice
/// is checked.
private struct PresetMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Menu("Dynamic") {
                ForEach(PreviewSamples.DynamicStyle.allCases, id: \.self) { style in
                    check(style.title, model.preview.isDynamic && model.preview.dynamicStyle == style) {
                        model.preview.text = ""
                        model.preview.showsFontNames = false
                        model.preview.textSource = nil
                        model.preview.dynamicStyle = style
                    }
                }
            }
            check("Font Names", model.preview.showsFontNames) {
                model.preview.text = ""
                model.preview.showsFontNames = true
                model.preview.textSource = nil
            }
            ForEach(PreviewSamples.letterSets) { sample($0, kind: "sample") }
            Divider()
            ForEach(PreviewSamples.symbolSets) { sample($0, kind: "sample") }
            Divider()
            Menu("Languages") {
                ForEach(PreviewSamples.languages) { sample($0, kind: "language") }
            }
            Divider()
            if !model.presets.isEmpty {
                ForEach(model.presets) { preset in
                    check(preset.name, isCurrent("preset:" + preset.name)) { use(preset.text, source: "preset:" + preset.name) }
                }
                Divider()
            }
            Button("Save Current Text…") {
                // The name prompt is a window alert: present it once the popover has finished closing.
                let appModel: AppModel = model
                appModel.afterPreviewOptionsClose = { [weak appModel] in appModel?.isNamingPreset = true }
                model.isShowingPreviewOptions = false
            }
            .disabled(model.preview.text.isEmpty || model.preview.showsFontNames)
            if !model.presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 6)
        .help("Preview text presets")
    }

    /// Only the item that was chosen is checked, not every item with the same text.
    private func isCurrent(_ source: String) -> Bool {
        !model.preview.showsFontNames && !model.preview.text.isEmpty && model.preview.textSource == source
    }

    private func use(_ text: String, source: String) {
        model.preview.text = text
        model.preview.showsFontNames = false
        model.preview.textSource = source
    }

    private func sample(_ sample: PreviewSamples.Sample, kind: String) -> some View {
        let source = "\(kind):\(sample.name)"
        return check(sample.name, isCurrent(source)) { use(sample.text, source: source) }
    }

    /// A menu item with a checkmark when `on`.
    private func check(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
    }
}
