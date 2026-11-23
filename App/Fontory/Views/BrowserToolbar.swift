import FontoryCore
import SwiftUI

struct BrowserToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SearchScopeMenu(model: model)
        }

        ToolbarItemGroup {
            PreviewOptionsButton(model: model)
            if model.detail != nil {
                // On the family page the size slider drives the page's own size (as do ⌘+/⌘−/⌘0 and its slider).
                Slider(value: $model.detailPointSize, in: AppModel.detailPointSizeRange) { Text("Size") }
                    .frame(width: 90)
                    .help("Preview size of the styles: \(model.effectiveDetailPointSize) pt")
            } else {
                Slider(value: pointSize, in: 0...288) { Text("Size") }
                    .frame(width: 90)
                    .help(model.preview.pointSizeOverride.map { "Preview size: \(Int($0)) pt (drag fully left to follow zoom)" }
                          ?? "Preview size follows the zoom")
            }
        }

        ToolbarItemGroup {
            // Zoom and the grid/list switch belong to the browser; the family page has its own layout switch.
            Slider(value: zoom, in: 0...1) { Text("Zoom") }
                .frame(width: 90)
                .help("Zoom")
                .disabled(model.detail != nil)
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid).help("Grid (⌘1)")
                Image(systemName: "list.bullet").tag(ViewMode.list).help("List (⌘3)")
            }
            .pickerStyle(.segmented)
            .disabled(model.detail != nil)
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
