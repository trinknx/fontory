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
            FiltersButton(model: model)
            if model.detail != nil {
                // On the family page the size slider drives the page's own size (as do ⌘+/⌘−/⌘0 and its slider).
                Slider(value: $model.detailPointSize, in: AppModel.detailPointSizeRange) { Text("Size") }
                    .frame(width: 90)
                    .help("Preview size of the styles: \(model.effectiveDetailPointSize) pt")
            } else {
                // One size control: the preview size, and with it how many fonts fit in a row.
                HStack(spacing: 6) {
                    Text("\(Int(GridMetrics.pointSize(zoom: zoom.wrappedValue)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    Slider(value: zoom, in: 0...1) { Text("Size") }
                        .frame(width: 120)
                }
                .help("Preview size: \(Int(GridMetrics.pointSize(zoom: zoom.wrappedValue))) pt (⌘+ / ⌘− / ⌘0, or pinch)")
            }
        }

        ToolbarItemGroup {
            // The grid/list switch belongs to the browser; the family page has its own layout switch.
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid).help("Grid (⌘1)")
                Image(systemName: "list.bullet").tag(ViewMode.list).help("List (⌘3)")
            }
            .pickerStyle(.segmented)
            .disabled(model.detail != nil)
            SortMenu(model: model)
        }
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
            // Not the funnel: that is the Filters button's symbol.
            Label("Search Options", systemImage: "text.magnifyingglass")
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

    /// Popular (Google's rank) is offered in the Google Fonts view only; leaving it restores the previous sort.
    private var options: [(String, LibraryQuery.Sort)] {
        model.query.scope == .googleFonts ? [("Popular", .popularity)] + Self.options : Self.options
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { title, sort in
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
