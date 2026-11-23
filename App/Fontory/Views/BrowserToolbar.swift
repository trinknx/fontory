import FontoryCore
import SwiftUI

struct BrowserToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SearchScopeMenu(model: model)
        }

        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 4) {
                TextField("Preview text", text: $model.preview.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 280)
                PresetMenu(model: model)
            }
        }

        ToolbarItemGroup {
            Slider(value: pointSize, in: 0...288) { Text("Size") }
                .frame(width: 90)
                .help(model.preview.pointSizeOverride.map { "Preview size: \(Int($0)) pt (drag fully left to follow zoom)" }
                      ?? "Preview size follows the zoom")
            Slider(value: $model.preview.tracking, in: -5...20) { Text("Tracking") }
                .frame(width: 70)
                .help("Tracking: \(model.preview.tracking.formatted(.number.precision(.fractionLength(1)))) pt")
            ColorPicker("Text Color", selection: $model.preview.foreground, supportsOpacity: false)
                .labelsHidden()
                .help("Text color")
            ColorPicker("Background Color", selection: $model.preview.background, supportsOpacity: false)
                .labelsHidden()
                .help("Background color")
            Picker("Alignment", selection: $model.preview.alignment) {
                ForEach(PreviewAlignment.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Alignment")
            Toggle(isOn: $model.preview.smoothing) { Image(systemName: "circle.lefthalf.filled") }
                .toggleStyle(.button)
                .help("Font smoothing")
            Toggle(isOn: $model.preview.autoSize) { Image(systemName: "textformat.size") }
                .toggleStyle(.button)
                .help("Auto size: match the visible height of every font")
        }

        ToolbarItemGroup {
            Slider(value: zoom, in: 0...1) { Text("Zoom") }
                .frame(width: 90)
                .help("Zoom")
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid).help("Grid (⌘1)")
                Image(systemName: "list.bullet").tag(ViewMode.list).help("List (⌘3)")
            }
            .pickerStyle(.segmented)
            SortMenu(model: model)
        }
    }

    private var pointSize: Binding<Double> {
        Binding(get: { model.preview.pointSizeOverride ?? 0 },
                set: { model.preview.pointSizeOverride = $0 < 6 ? nil : $0.rounded() })
    }

    private var zoom: Binding<Double> {
        Binding(get: { model.zoom[model.viewMode] ?? 0.25 }, set: { model.zoom[model.viewMode] = $0 })
    }
}

private struct SearchScopeMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Section("Search In") {
                ForEach(SearchText.Field.allCases, id: \.self) { field in
                    Toggle(title(field), isOn: Binding(
                        get: { model.searchScope.contains(field) },
                        set: { on in
                            if on { model.searchScope.insert(field) } else { model.searchScope.remove(field) }
                        }))
                }
            }
            Section("Matching") {
                Text("word — contains")
                Text("word* — starts with")
                Text("*word — ends with")
                Text("\"Exact Name\" — whole name")
                Text("#tag — tag")
                Text("Several words must all match")
            }
        } label: {
            Label("Search Options", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Search fields and syntax")
    }

    private func title(_ field: SearchText.Field) -> String {
        switch field {
        case .name: "Name"
        case .family: "Family"
        case .foundry: "Foundry"
        case .designer: "Designer"
        case .notes: "Notes"
        }
    }
}

private struct PresetMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.presets) { preset in
                Button(preset.name) { model.preview.text = preset.text }
            }
            if !model.presets.isEmpty { Divider() }
            Button("Save Current Text…") { model.isNamingPreset = true }
                .disabled(model.preview.text.isEmpty)
            if !model.presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "text.badge.star")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Preview text presets")
    }
}

private struct SortMenu: View {
    @Bindable var model: AppModel

    private static let options: [(String, LibraryQuery.Sort)] = [
        ("Family", .family), ("Name", .name), ("Weight", .weight), ("Date Added", .dateAdded), ("Last Activated", .lastActivated),
    ]

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.0) { title, sort in
                Button { model.chooseSort(sort) } label: {
                    if model.query.sort == sort {
                        Label(title, systemImage: model.query.ascending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(title)
                    }
                }
            }
            Divider()
            Button {
                model.chooseSort(.random(seed: 0))
            } label: {
                if case .random = model.query.sort { Label("Shuffle Again", systemImage: "shuffle") } else { Text("Shuffle") }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort order (choose again to reverse)")
    }
}
