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
            model.isShowingPreviewOptions.toggle()
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
    private weak var model: AppModel?
    /// When the popover last closed. A click on the toolbar button first closes the (semitransient) popover on
    /// mouse-down and then toggles it on mouse-up; that click must not reopen it.
    private var closedAt = Date.distantPast

    func show(model: AppModel) {
        guard popover == nil else { return }
        self.model = model
        guard Date().timeIntervalSince(closedAt) > 0.3 else {
            model.isShowingPreviewOptions = false
            return
        }
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
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        closedAt = Date()
        if model?.isShowingPreviewOptions == true { model?.isShowingPreviewOptions = false }
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
                    model.preview.text = new
                    model.preview.showsFontNames = false
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
private struct OptionToggle<Content: View>: View {
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

private struct IconToggleStyle: ToggleStyle {
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
                        model.preview.dynamicStyle = style
                    }
                }
            }
            check("Font Names", model.preview.showsFontNames) {
                model.preview.text = ""
                model.preview.showsFontNames = true
            }
            ForEach(PreviewSamples.letterSets) { sample($0) }
            Divider()
            ForEach(PreviewSamples.symbolSets) { sample($0) }
            Divider()
            Menu("Languages") {
                ForEach(PreviewSamples.languages) { sample($0) }
            }
            Divider()
            if !model.presets.isEmpty {
                ForEach(model.presets) { preset in
                    check(preset.name, isCurrent(preset.text)) { use(preset.text) }
                }
                Divider()
            }
            Button("Save Current Text…") {
                model.isShowingPreviewOptions = false
                model.isNamingPreset = true
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

    private func isCurrent(_ text: String) -> Bool {
        !model.preview.showsFontNames && model.preview.text == text
    }

    private func use(_ text: String) {
        model.preview.text = text
        model.preview.showsFontNames = false
    }

    private func sample(_ sample: PreviewSamples.Sample) -> some View {
        check(sample.name, isCurrent(sample.text)) { use(sample.text) }
    }

    /// A menu item with a checkmark when `on`.
    private func check(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
    }
}
