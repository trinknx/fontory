import AppKit
import FontoryCore
import SwiftUI

/// The family page, shown in place of the browser: header (Back, name, large preview), a control bar (style count,
/// tabs, layout switch), the Styles or Info tab, and the size slider.
struct FamilyDetailView: View {
    @Bindable var model: AppModel
    let detail: FamilyDetail

    /// Whether the focused style is a variable font, from its row; nil until the row is loaded.
    @State private var focusedIsVariable: Bool?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.detailTab == .styles {
                Divider()
                bottomBar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: updateFocusedIsVariable)
        .onChange(of: focusedFaceID) { updateFocusedIsVariable() }
        .onChange(of: model.rowsVersion) { updateFocusedIsVariable() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.rowsLoadedNotification, object: model)) { _ in
            updateFocusedIsVariable()
        }
    }

    private func updateFocusedIsVariable() {
        let value = model.cachedRow(focusedFaceID)?.isVariable
        if value != focusedIsVariable { focusedIsVariable = value }
    }

    /// Tabs that cannot be chosen now, with the reason shown as their tooltip. While a variable font is open on
    /// Variables, the tab stays enabled even before its row loads.
    private var disabledTabs: [DetailTab: String] {
        focusedIsVariable == true || (focusedIsVariable == nil && model.detailTab == .variables)
            ? [:] : [.variables: "Not a variable font"]
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.closeFamilyDetail()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help("Back to all fonts (⌘[ or Esc)")
                Text(detail.family)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            FamilyHeaderPreview(model: model, faceID: detail.representativeID, rowsVersion: model.rowsVersion,
                                preview: model.preview)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            Text(detail.faceIDs.count == 1 ? "1 Style" : "\(detail.faceIDs.count) Styles")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .accessibilityLabel("\(detail.faceIDs.count) styles in this family")
            Spacer(minLength: 0)
            DetailTabBar(selection: $model.detailTab, disabled: disabledTabs)
            Spacer(minLength: 0)
            Picker("Layout", selection: $model.detailLayout) {
                Image(systemName: "rectangle.grid.1x2").tag(DetailLayout.rows).help("Rows: a large preview per style")
                Image(systemName: "list.bullet").tag(DetailLayout.compact).help("Compact list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.detailTab != .styles)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.detailTab {
        case .styles:
            FamilyStylesView(model: model, faceIDs: detail.faceIDs, rowsVersion: model.rowsVersion, preview: model.preview,
                             pointSize: model.detailPointSize, layout: model.detailLayout, selection: model.detailSelection)
        case .characters:
            CharactersTabView(model: model, detail: detail, faceID: focusedFaceID)
        case .text:
            TextTabView(model: model, detail: detail, faceID: focusedFaceID)
        case .features:
            FeaturesTabView(model: model, detail: detail, faceID: focusedFaceID)
        case .variables:
            VariablesTabView(model: model, detail: detail, faceID: focusedFaceID)
        case .info:
            FamilyInfoView(model: model, detail: detail, faceID: focusedFaceID, rowsVersion: model.rowsVersion)
        }
    }

    /// Characters, Text, Features, Variables and Info show the first selected style, or the family's representative.
    private var focusedFaceID: Int64 {
        detail.faceIDs.first(where: model.detailSelection.contains) ?? detail.representativeID
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(selectionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $model.detailPointSize, in: AppModel.detailPointSizeRange)
                .frame(width: 160)
                .controlSize(.small)
                .accessibilityLabel("Preview size")
                .help(model.detailLayout == .compact
                      ? "Preview size of the styles (⌘+ / ⌘−); the compact list draws at most \(Int(AppModel.compactMaxPointSize)) pt"
                      : "Preview size of the styles (⌘+ / ⌘−)")
            Image(systemName: "textformat.size.larger").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(model.effectiveDetailPointSize) pt")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var selectionSummary: String {
        let n = model.detailSelection.count
        return n == 0 ? "" : "\(n) of \(detail.faceIDs.count) selected"
    }
}

/// The page's tabs. Disabled tabs are shown but inert, with the reason as their tooltip.
private struct DetailTabBar: View {
    @Binding var selection: DetailTab
    /// Tab → why it is disabled.
    var disabled: [DetailTab: String] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                if let reason = disabled[tab] {
                    label(tab)
                        .foregroundStyle(.tertiary)
                        .help(reason)
                        .accessibilityLabel("\(tab.title), \(reason.lowercased())")
                } else {
                    Button {
                        selection = tab
                    } label: {
                        label(tab)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .help(tab == .info ? "Info (⌘I)" : tab.title)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
    }

    private func label(_ tab: DetailTab) -> some View {
        Text(tab.title)
            .font(.callout.weight(selection == tab ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background {
                if selection == tab {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)).shadow(radius: 0.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
    }
}

// MARK: Info

/// Indexed metadata of one style, read off the main actor whenever the style or the rows change.
struct FamilyInfoView: View {
    let model: AppModel
    let detail: FamilyDetail
    let faceID: Int64
    let rowsVersion: Int

    @State private var info: FaceInfo?
    @State private var loadedID: Int64?
    /// Style names by face, from the rows (the row cache is not observable, so they are copied in when loaded).
    @State private var styleNames: [Int64: String] = [:]

    private struct LoadKey: Equatable {
        let faceID: Int64
        let rowsVersion: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stylePicker
                if loadedID == faceID, info == nil {
                    Text("This style is no longer in the library.").foregroundStyle(.secondary)
                } else if let info {
                    // While the next style loads, the previous one stays (no flash of a spinner).
                    sections(info)
                        .opacity(loadedID == faceID ? 1 : 0.6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: LoadKey(faceID: faceID, rowsVersion: rowsVersion)) {
            let id = faceID
            // The rows were dropped (activation, rescan): fetch them again for the style names.
            model.prefetchRows(detail.faceIDs)
            let loaded = await model.faceInfo(id)
            guard !Task.isCancelled else { return }
            info = loaded
            loadedID = id
            updateStyleNames()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.rowsLoadedNotification, object: model)) { _ in
            updateStyleNames()
        }
    }

    private var stylePicker: some View {
        Picker("Style", selection: Binding(get: { faceID }, set: { model.detailSelection = [$0] })) {
            ForEach(detail.faceIDs, id: \.self) { id in
                Text(styleName(id)).tag(id)
            }
        }
        .fixedSize()
    }

    private func styleName(_ id: Int64) -> String {
        if id == info?.id, let info { return info.style.isEmpty ? info.fullName : info.style }
        return styleNames[id] ?? "Style \(detail.faceIDs.firstIndex(of: id).map { $0 + 1 } ?? 0)"
    }

    /// Copies the names of the cached rows into state; names already known are kept while rows reload.
    private func updateStyleNames() {
        var names = styleNames
        for id in detail.faceIDs {
            if let row = model.cachedRow(id) { names[id] = row.style.isEmpty ? row.fullName : row.style }
        }
        if names != styleNames { styleNames = names }
    }

    @ViewBuilder
    private func sections(_ info: FaceInfo) -> some View {
        InfoSection("Names") {
            InfoRow("PostScript name", info.postScriptName)
            InfoRow("Full name", info.fullName)
            InfoRow("Family", info.family == info.fontFamily ? info.family : "\(info.family) (in the font: \(info.fontFamily))")
            InfoRow("Style", info.style)
        }
        InfoSection("Font") {
            InfoRow("Version", info.version)
            InfoRow("Vendor", info.vendor)
            InfoRow("Designer", info.designer)
            InfoRow("Format", info.format.uppercased() + (info.faceIndex > 0 ? " (face \(info.faceIndex + 1) in the file)" : ""))
            InfoRow("Outlines", Self.outlineTitle(info.outlineType))
            InfoRow("Kind", Self.kinds(info))
            InfoRow("Layout tables", Self.layoutTables(info))
            InfoRow("Glyphs", info.glyphCount.formatted())
            InfoRow("Units per em", String(info.metrics.unitsPerEm))
            InfoRow("Weight · width", "\(Self.number(info.weight)) · \(Self.number(info.width))"
                    + (info.isItalic ? " · italic" : "") + (info.slant != 0 ? " · slant \(Self.number(info.slant))°" : ""))
            InfoRow("Metrics", "ascender \(Self.number(info.metrics.ascender)) · descender \(Self.number(info.metrics.descender))"
                    + " · cap height \(Self.number(info.metrics.capHeight)) · x-height \(Self.number(info.metrics.xHeight))")
        }
        InfoSection("Embedding (fsType)") {
            if let embedding = info.embedding {
                InfoRow("Permission", embedding.usage.title)
                InfoRow("Restrictions", Self.restrictions(embedding))
                InfoRow("Raw value", embedding.hex)
            } else {
                InfoRow("Permission", "Not specified (the font has no OS/2 table)")
            }
        }
        if info.isVariable {
            InfoSection("Variation axes") {
                if info.axes.isEmpty {
                    InfoRow("Axes", "None recorded")
                } else {
                    ForEach(info.axes, id: \.self) { axis in
                        InfoRow(axis.name.map { "\($0) (\(axis.tag))" } ?? axis.tag,
                                "\(Self.number(axis.min)) – \(Self.number(axis.max)), default \(Self.number(axis.defaultValue))")
                    }
                }
            }
        }
        InfoSection("File") {
            GridRow {
                InfoLabel("Path")
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.fileURL.path)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Button("Reveal in Finder") { model.revealFile(info.fileURL) }
                            .controlSize(.small)
                            .disabled(!info.online)
                        if !info.online {
                            Label("Offline", systemImage: "externaldrive.badge.xmark")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            InfoRow("Size", info.fileSize.formatted(.byteCount(style: .file)))
            InfoRow("Added", info.addedAt.map(Self.date))
        }
        InfoSection("Activation") {
            InfoRow("Status", status(info))
            InfoRow("Last activated", info.lastActivated.map(Self.date) ?? "Never")
        }
        InfoSection("Notes") {
            GridRow {
                InfoLabel("Notes")
                Text(info.note?.isEmpty == false ? info.note! : "No notes")
                    .foregroundStyle(info.note?.isEmpty == false ? .primary : .secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func status(_ info: FaceInfo) -> String {
        info.activationStatus.statusText(online: info.online)
    }

    private static func outlineTitle(_ type: OutlineType) -> String {
        switch type {
        case .truetype: "TrueType (glyf)"
        case .cff: "PostScript (CFF)"
        case .cff2: "PostScript (CFF2)"
        case .bitmap: "Bitmap only"
        case .unknown: "Unknown"
        }
    }

    private static func kinds(_ info: FaceInfo) -> String {
        var parts: [String] = []
        if info.isVariable { parts.append("Variable") }
        if info.isColor { parts.append("Color") }
        if info.isBitmap { parts.append("Bitmap glyphs") }
        return parts.isEmpty ? "Static" : parts.joined(separator: " · ")
    }

    private static func layoutTables(_ info: FaceInfo) -> String {
        let tables = [info.hasGSUB ? "GSUB" : nil, info.hasGPOS ? "GPOS" : nil].compactMap { $0 }
        return tables.isEmpty ? "None" : tables.joined(separator: " · ")
    }

    private static func restrictions(_ e: EmbeddingPermissions) -> String {
        var parts: [String] = []
        if e.noSubsetting { parts.append("No subsetting") }
        if e.bitmapOnly { parts.append("Bitmap embedding only") }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    private static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                content
            }
        }
    }
}

private struct InfoLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 140, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// A label and a selectable value; a missing value shows a dash.
private struct InfoRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            InfoLabel(label)
            Text(value?.isEmpty == false ? value! : "—")
                .foregroundStyle(value?.isEmpty == false ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
