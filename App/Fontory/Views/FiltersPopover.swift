import AppKit
import FontoryCore
import SwiftUI

// MARK: Toolbar button

/// The toolbar Filters button: filled with a count while filters are in effect; opens the Filters popover below itself
/// (same controller and behavior as the preview popover). Browser only: disabled on the family page and in the
/// Duplicates view, which ignores filters.
struct FiltersButton: View {
    @Bindable var model: AppModel
    @State private var controller = ToolbarPopoverController(isShowing: \.isShowingFilters) { model in
        let hosting = NSHostingController(rootView: FiltersView(model: model))
        hosting.sizingOptions = .preferredContentSize
        return hosting
    }

    var body: some View {
        let count = model.effectiveFilters.activeCount
        Button {
            // A click while open first closes it (semitransient, on mouse-down): that click means "close".
            model.isShowingFilters = !(controller.isShown || controller.closedByCurrentClick)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(count > 0 ? Color.accentColor : Color.primary)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
        }
        .help(count > 0 ? "Filters: \(count) active" : "Filters")
        .accessibilityLabel(count > 0 ? "Filters, \(count) active" : "Filters")
        .disabled(!model.filtersAvailable)
        .background(AnchorReader { controller.anchorView = $0 })
        .onChange(of: model.isShowingFilters) { _, show in
            // Out of the SwiftUI update, so AppKit can open its window transaction.
            DispatchQueue.main.async {
                if show { controller.show(model: model) } else { controller.close() }
            }
        }
        .onChange(of: model.filtersAvailable) { _, available in
            if !available { model.isShowingFilters = false }
        }
    }
}

// MARK: Popover content

private enum ScriptChoice: Hashable {
    case none, vietnamese, script(Int)
}

struct FiltersView: View {
    @Bindable var model: AppModel
    @State private var tagDraft = ""
    @State private var tagInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            characters
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                row("Script") { scriptMenu }
                row("Figures") {
                    segmented(model.filters.figures, set: { model.filters.figures = $0 },
                              [("Any", nil), ("Lining", FigureStyle.lining), ("Oldstyle", .oldstyle)])
                }
                row("Outline") {
                    segmented(model.filters.outline, set: { model.filters.outline = $0 },
                              [("Any", .any), ("TrueType", .trueType), ("CFF", .cff), ("Bitmap", .bitmap)])
                        .help("CFF includes CFF2")
                }
                row("Variable") { triState(model.filters.variable) { model.filters.variable = $0 } }
                row("Color") { triState(model.filters.color) { model.filters.color = $0 } }
                row("x-Height") {
                    segmented(model.filters.xHeight, set: { model.filters.xHeight = $0 },
                              [("Any", .any), ("Low", .low), ("Medium", .medium), ("High", .high)])
                        .help("x-height / cap height: low < 0.66, medium 0.66–0.74, high > 0.74. Fonts without metrics are left out.")
                }
                row("Features") { features }
            }
            if let note = model.filtersBackfillNote {
                Label(note, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                let active = model.effectiveFilters.activeCount
                Text(active == 0 ? "No filters" : active == 1 ? "1 filter" : "\(active) filters")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { model.clearFilters() }
                    .disabled(model.effectiveFilters.isEmpty && !model.followsPreviewText)
            }
        }
        .padding(12)
        .frame(width: 420)
        .onExitCommand { model.isShowingFilters = false }
    }

    // MARK: Characters

    private var characters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Supports the preview text", isOn: $model.followsPreviewText)
                .disabled(!model.canFollowPreviewText)
                .help("Every character typed in the preview field, ignoring spaces")
            if !model.canFollowPreviewText {
                Text("Type a preview text first (not Dynamic or Font Names).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Characters")
                TextField("Any", text: $model.filters.requiredCharacters)
                    .textFieldStyle(.roundedBorder)
                    .help("The font must have every character typed here (spaces are ignored)")
            }
        }
    }

    // MARK: Rows

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.trailing)
            content()
        }
    }

    private func segmented<T: Hashable>(_ value: T, set: @escaping (T) -> Void, _ options: [(String, T)]) -> some View {
        Picker("", selection: Binding(get: { value }, set: set)) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i].0).tag(options[i].1)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func triState(_ value: LibraryFilters.TriState, set: @escaping (LibraryFilters.TriState) -> Void) -> some View {
        segmented(value, set: set, [("Any", .any), ("Only", .only), ("Exclude", .exclude)])
    }

    // MARK: Script

    private var scriptChoice: Binding<ScriptChoice> {
        Binding(get: {
            if model.filters.vietnamese { return .vietnamese }
            return model.filters.scriptIndex.map(ScriptChoice.script) ?? .none
        }, set: { choice in
            // One assignment: one query change.
            var f = model.filters
            f.vietnamese = choice == .vietnamese
            if case .script(let i) = choice { f.scriptIndex = i } else { f.scriptIndex = nil }
            model.filters = f
        })
    }

    private var scriptMenu: some View {
        Picker("", selection: scriptChoice) {
            Text("None").tag(ScriptChoice.none)
            Divider()
            Text("Vietnamese").tag(ScriptChoice.vietnamese)
            Divider()
            ForEach(Array(SmartRule.scriptNames.enumerated()), id: \.offset) { i, name in
                Text(name).tag(ScriptChoice.script(i))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Vietnamese: every precomposed Vietnamese letter")
    }

    // MARK: Features

    private var features: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.filters.features.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(model.filters.features, id: \.self) { tag in token(tag) }
                }
            }
            HStack(spacing: 6) {
                Menu("Add") {
                    ForEach(AppModel.commonFeatureTags, id: \.self) { tag in
                        Button(tag) { model.addFeatureTag(tag) }
                            .disabled(model.filters.features.contains(tag))
                    }
                }
                .fixedSize()
                TextField("Tag", text: $tagDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 64)
                    .onSubmit {
                        if model.addFeatureTag(tagDraft) { tagDraft = "" } else { tagInvalid = true }
                    }
                    .onChange(of: tagDraft) { tagInvalid = false }
                    .help("Type any OpenType feature tag (4 characters) and press Return")
                if tagInvalid {
                    Text("4 ASCII characters, no spaces")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("All chosen features are required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func token(_ tag: String) -> some View {
        HStack(spacing: 2) {
            Text(tag).font(.callout.monospaced())
            Button {
                model.removeFeatureTag(tag)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(tag)")
            .accessibilityLabel("Remove \(tag)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
    }
}

/// Lays its subviews out left to right, wrapping to a new line when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(place(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
