import FontoryCore
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Environment(AppModel.self) private var model
    @State private var presetName = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 380)
        } detail: {
            switch model.viewMode {
            case .grid:
                FontGridView(model: model, faceIDs: model.faceIDs, rowsVersion: model.rowsVersion,
                             zoom: model.zoom[.grid] ?? AppModel.defaultZoom, preview: model.preview,
                             selection: model.selection)
            case .list:
                BrowserPlaceholder()
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search fonts")
        .toolbar { BrowserToolbar(model: model) }
        .frame(minWidth: 820, minHeight: 480)
        .modelAlert(model, inSettings: false)
        .alert("Save Preview Text as Preset", isPresented: $model.isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                model.savePreset(named: presetName)
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text(model.preview.text)
        }
    }
}

/// Stand-in for the list view (Task 12): a count and a plain list of the first matches.
private struct BrowserPlaceholder: View {
    @Environment(AppModel.self) private var model
    private static let limit = 300

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Divider()
            List(Array(model.faceIDs.prefix(Self.limit)), id: \.self, selection: $model.selection) { id in
                if let row = model.row(id) {
                    HStack {
                        ActivationBadge(row: row, locked: model.isActivationLocked(row))
                        Text(row.fullName)
                        Spacer()
                        Text(row.family).foregroundStyle(.secondary)
                    }
                    .contextMenu { FaceContextMenu(ids: contextIDs(for: id)) }
                } else {
                    Text("Font #\(id)").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: String {
        let n = model.faceIDs.count
        let shown = n > Self.limit ? " (showing the first \(Self.limit))" : ""
        return "\(n.formatted()) font\(n == 1 ? "" : "s")\(shown)"
    }

    private func contextIDs(for id: Int64) -> [Int64] {
        model.selection.contains(id) ? Array(model.selection) : [id]
    }
}

private struct ActivationBadge: View {
    let row: FaceRow
    let locked: Bool

    var body: some View {
        Group {
            if locked {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            } else if !row.online {
                Image(systemName: "circle.slash").foregroundStyle(.secondary)
            } else {
                switch row.activation {
                case .on: Image(systemName: "circle.fill").foregroundStyle(.green)
                case .temporary: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange)
                case .off: Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
        }
        .imageScale(.small)
        .frame(width: 16)
    }
}

private struct FaceContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [Int64]

    var body: some View {
        Button("Activate") { Task { await model.setActivation(ids, .on) } }
        Button("Activate Temporarily") { Task { await model.setActivation(ids, .temporary) } }
        Button("Deactivate") { Task { await model.setActivation(ids, .off) } }
        Divider()
        Button("Reveal in Finder") { model.revealInFinder(ids) }
        Button("Copy Details") { model.copyDetails(ids) }
    }
}

/// Presents `AppModel.alert` on exactly one window: Settings while it is the key window, the main window otherwise.
private struct ModelAlert: ViewModifier {
    let model: AppModel
    let inSettings: Bool

    func body(content: Content) -> some View {
        content.alert(model.alert?.title ?? "", isPresented: presented, presenting: model.alert) { item in
            if let title = item.actionTitle, let action = item.action {
                Button(title, role: item.isDestructive ? .destructive : nil) { action() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { item in
            Text(item.message)
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { model.alert != nil && Self.settingsIsKey == inSettings },
                set: { if !$0 { model.alert = nil } })
    }

    private static var settingsIsKey: Bool {
        NSApp.keyWindow?.identifier?.rawValue.contains("Settings") == true
    }
}

extension View {
    func modelAlert(_ model: AppModel, inSettings: Bool) -> some View {
        modifier(ModelAlert(model: model, inSettings: inSettings))
    }
}
