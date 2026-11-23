import AppKit
import FontoryCore
import SwiftUI

/// The Characters tab: every glyph of the focused style in a virtualized grid, an inspector strip for the selected
/// glyph, and a bottom bar (style, category, search, order, cell size). The face's inventory and every filtering
/// pass run off the main actor.
struct CharactersTabView: View {
    @Bindable var model: AppModel
    let detail: FamilyDetail
    let faceID: Int64

    @State private var face: GlyphFace?
    @State private var inventory: GlyphInventory?
    @State private var loadedID: Int64?
    @State private var failure: String?
    @State private var shown: [GlyphEntry] = []
    @State private var shownVersion = 0
    @State private var selected: GlyphEntry?
    /// The filter the shown entries were computed with, so a pass is not repeated.
    @State private var appliedKey: FilterKey?
    /// Style names by face, from the rows.
    @State private var styleNames: [Int64: String] = [:]

    private struct LoadKey: Equatable {
        let faceID: Int64
        let glyphsVersion: Int
    }

    private struct FilterKey: Equatable {
        let faceID: Int64?
        let glyphsVersion: Int
        let filter: GlyphFilter
        let search: String
        let order: GlyphOrder
    }

    var body: some View {
        VStack(spacing: 0) {
            grid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            GlyphInspector(model: model, face: face, entry: selected)
        }
        .glassBottomBar { bottomBar }
        .task(id: LoadKey(faceID: faceID, glyphsVersion: model.glyphsVersion)) { await load() }
        .task(id: filterKey(faceID: loadedID)) { await applyFilter() }
        .onAppear { updateStyleNames() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.rowsLoadedNotification, object: model)) { _ in
            updateStyleNames()
        }
    }

    // MARK: Grid

    @ViewBuilder
    private var grid: some View {
        if let failure, loadedID == faceID {
            ContentUnavailableView(failure, systemImage: "character.textbox")
        } else if let face, let inventory {
            ZStack {
                GlyphGridView(model: model, face: face, entries: shown, entriesVersion: shownVersion,
                              cellSize: model.glyphCellSize, preview: model.preview, selection: selected?.id,
                              onSelect: { selected = $0 })
                    .opacity(loadedID == faceID ? 1 : 0.5)
                if shown.isEmpty, inventory.entries.count > 0 {
                    Text(model.glyphSearch.isEmpty ? "No glyphs in this category" : "No glyphs match “\(model.glyphSearch)”")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func load() async {
        let id = faceID
        model.prefetchRows(detail.faceIDs)
        guard let info = await model.faceInfo(id), !Task.isCancelled else {
            if !Task.isCancelled { fail("This style is no longer in the library.", id) }
            return
        }
        guard info.online else {
            fail("The file of this style is offline.", id)
            return
        }
        let cache = model.glyphInventories
        let url = info.fileURL, index = info.faceIndex
        let key = filterKey(faceID: id)
        let filter = model.glyphFilter, order = model.glyphOrder
        let search = GlyphSearch(model.glyphSearch)
        // The inventory and its first filtered list arrive together, so the grid never pairs the new face with the
        // old face's glyph IDs.
        let result = await Task.detached(priority: .userInitiated) { () -> (GlyphInventory, [GlyphEntry])? in
            guard let inventory = cache.inventory(fileURL: url, faceIndex: index) else { return nil }
            return (inventory, inventory.entries(filter: filter, search: search, order: order))
        }.value
        guard !Task.isCancelled else { return }
        guard let result else {
            fail("This font file could not be read.", id)
            return
        }
        let (loaded, entries) = result
        failure = nil
        inventory = loaded
        face = GlyphFace(faceID: id, fileURL: url, faceIndex: index, postScriptName: info.postScriptName,
                         box: loaded.cellBox)
        publish(entries, key: key)
        loadedID = id
        updateStyleNames()
    }

    /// A face that cannot be shown: its message, and no selection left over from the previous face.
    private func fail(_ message: String, _ id: Int64) {
        failure = message
        selected = nil
        loadedID = id
    }

    private func filterKey(faceID: Int64?) -> FilterKey {
        FilterKey(faceID: faceID, glyphsVersion: model.glyphsVersion, filter: model.glyphFilter, search: model.glyphSearch,
                  order: model.glyphOrder)
    }

    /// Shows `entries`. The selection follows its character (or glyph) into the new list, or is cleared.
    private func publish(_ entries: [GlyphEntry], key: FilterKey) {
        shown = entries
        shownVersion &+= 1
        appliedKey = key
        if let s = selected { selected = entries.first { $0.id == s.id } }
    }

    private func applyFilter() async {
        let key = filterKey(faceID: loadedID)
        guard let inventory, loadedID != nil, key != appliedKey else { return }
        let filter = model.glyphFilter, order = model.glyphOrder
        let search = GlyphSearch(model.glyphSearch)
        // Typing: wait for a pause before filtering tens of thousands of glyphs.
        if search != nil {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        let result = await Task.detached(priority: .userInitiated) {
            inventory.entries(filter: filter, search: search, order: order)
        }.value
        // The face may have changed while filtering: never pair its glyph IDs with another face.
        guard !Task.isCancelled, key.faceID == loadedID else { return }
        publish(result, key: key)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if detail.faceIDs.count > 1 { stylePicker }
            categoryPicker
            searchField
            Picker("Order", selection: $model.glyphOrder) {
                Text("Unicode").tag(GlyphOrder.unicode)
                Text("Glyph ID").tag(GlyphOrder.glyph)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Sort by Unicode code point or by glyph ID")
            Text(countLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "square.grid.4x3.fill").foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
            Slider(value: $model.glyphCellSize, in: AppModel.glyphCellSizeRange)
                .frame(width: 120)
                .controlSize(.small)
                .accessibilityLabel("Cell size")
                .help("Cell size (⌘+ / ⌘−)")
            Image(systemName: "square.grid.2x2.fill").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var countLabel: String {
        guard let inventory else { return "" }
        let total = inventory.count(for: model.glyphFilter)
        let n = shown.count
        let noun = n == 1 ? "glyph" : "glyphs"
        return n == total || model.glyphSearch.isEmpty ? "\(n.formatted()) \(noun)" : "\(n.formatted()) of \(total.formatted())"
    }

    private var stylePicker: some View {
        Picker("Style", selection: Binding(get: { faceID }, set: { model.detailSelection = [$0] })) {
            ForEach(detail.faceIDs, id: \.self) { id in
                Text(styleNames[id] ?? "Style \(detail.faceIDs.firstIndex(of: id).map { $0 + 1 } ?? 0)").tag(id)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("The style whose characters are shown")
    }

    private var categoryPicker: some View {
        Picker("Show", selection: $model.glyphFilter) {
            Text(title(.all, "All Characters")).tag(GlyphFilter.all)
            Divider()
            ForEach(GlyphCategory.allCases, id: \.self) { c in
                Text(title(.category(c), c.title)).tag(GlyphFilter.category(c))
            }
            Divider()
            ForEach(scriptsShown, id: \.self) { s in
                Text(title(.script(s), s.title)).tag(GlyphFilter.script(s))
            }
            Divider()
            Text(title(.unmapped, "Additional Glyphs")).tag(GlyphFilter.unmapped)
        }
        .labelsHidden()
        .fixedSize()
        .help("Category")
    }

    /// Scripts the face has, plus the chosen one (so the picker never loses its selection).
    private var scriptsShown: [GlyphScript] {
        GlyphScript.allCases.filter { s in
            (inventory?.count(for: .script(s)) ?? 0) > 0 || model.glyphFilter == .script(s)
        }
    }

    private func title(_ filter: GlyphFilter, _ name: String) -> String {
        guard let inventory else { return name }
        return "\(name) (\(inventory.count(for: filter).formatted()))"
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField("Character, name, U+code or glyph", text: $model.glyphSearch)
                .textFieldStyle(.plain)
                .frame(minWidth: 120, idealWidth: 200, maxWidth: 240)
            if !model.glyphSearch.isEmpty {
                Button {
                    model.glyphSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        .help("Search by character, Unicode name, code point (U+00E4, 00e4, 228) or glyph name")
    }

    private func updateStyleNames() {
        var names = styleNames
        for id in detail.faceIDs {
            if let row = model.cachedRow(id) { names[id] = row.style.isEmpty ? row.fullName : row.style }
        }
        if names != styleNames { styleNames = names }
    }
}

// MARK: Inspector

/// The selected glyph, large, with its code point, names, glyph ID and advance, and the copy buttons.
private struct GlyphInspector: View {
    let model: AppModel
    let face: GlyphFace?
    let entry: GlyphEntry?

    @State private var image: CGImage?
    /// Whether the selected glyph has a vector outline (bitmap and colour glyphs have none: no SVG).
    @State private var hasOutline = true
    @Environment(\.displayScale) private var displayScale

    static let side: CGFloat = 96

    private struct RenderKey: Equatable {
        let face: GlyphFace?
        let entry: GlyphEntry?
        let foreground: [CGFloat]
        let background: [CGFloat]
        let scale: CGFloat
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(cgColor: model.preview.background))
                if let image, entry != nil {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            if let entry {
                details(entry)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Copy Character") { GlyphExport.copyCharacter(entry) }
                        .disabled(!entry.isMapped)
                        .help(entry.isMapped ? "Copy \(entry.character) as text" : "This glyph has no character")
                    Button("Copy SVG") { copySVG(entry) }
                        .disabled(!hasOutline)
                        .help(hasOutline ? "Copy the outline as an SVG document" : "This glyph has no outline (bitmap/colour)")
                }
                .controlSize(.small)
            } else {
                Text("Select a glyph to see its code point, names and metrics. Drag a glyph out to save it as SVG.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: Self.side + 20)
        .task(id: RenderKey(face: face, entry: entry, foreground: PreviewRequest.components(model.preview.foreground),
                            background: PreviewRequest.components(model.preview.background), scale: displayScale)) {
            await render()
        }
    }

    @ViewBuilder
    private func details(_ entry: GlyphEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.codePointLabel ?? "No character")
                .font(.title3.weight(.semibold).monospacedDigit())
                .textSelection(.enabled)
            Text(entry.unicodeName?.capitalized ?? (entry.isMapped ? "Unnamed character" : "Additional glyph"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Text("Glyph \(entry.glyphID)" + (entry.glyphName.map { " · \($0)" } ?? ""))
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
            Text("Advance \(Int(entry.advance.rounded())) units"
                 + (entry.category.map { " · \($0.title)" } ?? "") + (entry.script.map { " · \($0.title)" } ?? ""))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func render() async {
        guard let face, let entry else { image = nil; hasOutline = true; return }
        let renderer = model.previewRenderer
        let side = Self.side
        let style = GlyphCellStyle(size: CGSize(width: side, height: side), scale: displayScale,
                                   foreground: model.preview.foreground, background: model.preview.background)
        let pointSize = face.cellPointSize(side)
        let rendered = await Task.detached(priority: .userInitiated) { () -> (CGImage?, Bool) in
            guard let font = renderer.font(fileURL: face.fileURL, faceIndex: face.faceIndex, pointSize: pointSize) else {
                return (nil, false)
            }
            return (GlyphCellRenderer.render(font: font, glyph: entry.glyphID, style: style, box: face.box),
                    GlyphSVG.hasOutline(font: font, glyph: entry.glyphID))
        }.value
        guard !Task.isCancelled else { return }
        image = rendered.0
        hasOutline = rendered.1
    }

    private func copySVG(_ entry: GlyphEntry) {
        guard let face,
              let font = model.previewRenderer.font(fileURL: face.fileURL, faceIndex: face.faceIndex, pointSize: 1),
              let svg = GlyphSVG.document(font: font, glyph: entry.glyphID) else {
            return NSSound.beep()
        }
        GlyphExport.copySVG(svg)
    }
}
