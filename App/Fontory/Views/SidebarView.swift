import FontoryCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        List(selection: scope) {
            Section("Library") {
                libraryRow("All Fonts", "textformat", .all, model.counts.all)
                libraryRow("Activated", "checkmark.circle", .activated, model.counts.activated)
                libraryRow("Temporarily Activated", "clock", .temporary, model.counts.temporary)
                libraryRow("Deactivated", "circle", .deactivated, model.counts.deactivated)
                libraryRow("Offline", "externaldrive.badge.xmark", .offline, model.counts.offline)
                libraryRow("Last Import", "square.and.arrow.down", .recentImport, model.counts.lastImport)
            }

            Section("Locations") {
                if model.userLocations.isEmpty {
                    Text("Drop font folders or files here")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.userLocations) { LocationNode(location: $0) }
            }

            Section("System") {
                Toggle(isOn: $model.query.includeSystem) {
                    Label("Show System Fonts", systemImage: "eye")
                }
                .toggleStyle(.checkbox)
                .selectionDisabled()
                ForEach(model.systemLocations) { LocationNode(location: $0) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            model.importDropped(fileURLs)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var scope: Binding<LibraryQuery.Scope?> {
        Binding(get: { model.query.scope }, set: { if let s = $0 { model.query.scope = s } })
    }

    private func libraryRow(_ title: String, _ symbol: String, _ scope: LibraryQuery.Scope, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(scope)
    }
}

/// A location with lazily loaded subfolders and its scan status.
private struct LocationNode: View {
    @Environment(AppModel.self) private var model
    let location: LocationRecord
    @State private var isExpanded = false
    @State private var children: [String]?

    var body: some View {
        Group {
            if children?.isEmpty == true || location.kind == .fileSet {
                label
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children ?? [], id: \.self) { SubfolderNode(locationID: location.id, path: $0) }
                } label: {
                    label
                }
            }
        }
        .task(id: TaskKey(expanded: isExpanded, lastScan: location.lastScan)) {
            if isExpanded || children != nil {
                children = await model.subfolders(of: location.id, parent: nil)
            }
        }
    }

    private struct TaskKey: Equatable {
        var expanded: Bool
        var lastScan: Date?
    }

    private var label: some View {
        LocationRow(location: location)
            .tag(LibraryQuery.Scope.location(id: location.id, subfolder: nil))
            .contextMenu { LocationMenu(location: location) }
    }
}

private struct SubfolderNode: View {
    @Environment(AppModel.self) private var model
    let locationID: Int64
    let path: String
    @State private var isExpanded = false
    @State private var children: [String]?

    var body: some View {
        Group {
            if children?.isEmpty == true {
                label
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children ?? [], id: \.self) { SubfolderNode(locationID: locationID, path: path + "/" + $0) }
                } label: {
                    label
                }
            }
        }
        .task(id: isExpanded) {
            if isExpanded { children = await model.subfolders(of: locationID, parent: path) }
        }
    }

    private var label: some View {
        Label((path as NSString).lastPathComponent, systemImage: "folder")
            .tag(LibraryQuery.Scope.location(id: locationID, subfolder: path))
    }
}

private struct LocationRow: View {
    @Environment(AppModel.self) private var model
    let location: LocationRecord
    @State private var showingWarnings = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Label(location.displayName, systemImage: symbol)
                    .foregroundStyle(location.online ? .primary : .secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 22)
                }
            }
            Spacer(minLength: 4)
            status
        }
        .badge(model.counts.perLocation[location.id] ?? 0)
        .help(location.lastKnownPath)
    }

    private var symbol: String {
        if !location.online { return "externaldrive.badge.xmark" }
        switch location.kind {
        case .folder: return "folder"
        case .fileSet: return "doc.on.doc"
        case .system: return "lock"
        }
    }

    private var progress: ScanProgress? { model.scanProgress[location.id] }

    private var detail: String? {
        guard let progress else { return location.online ? nil : "Offline" }
        switch progress.phase {
        case .enumerating: return "Looking for fonts… \(progress.total.formatted())"
        case .parsing: return progress.total > 0 ? "Reading \(progress.processed.formatted()) of \(progress.total.formatted())" : "Reading…"
        case .applying: return "Updating index…"
        case .aborted(let reason): return "Scan stopped: \(reason)"
        case .done: return location.online ? nil : "Offline"
        }
    }

    @ViewBuilder private var status: some View {
        if let progress {
            switch progress.phase {
            case .enumerating, .applying:
                ProgressView().controlSize(.mini)
            case .parsing:
                if progress.total > 0 {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    ProgressView().controlSize(.mini)
                }
            case .aborted(let reason):
                Image(systemName: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .help(reason)
            case .done:
                if progress.unreadableCount > 0 || progress.failed > 0 {
                    Button { showingWarnings = true } label: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .buttonStyle(.borderless)
                    .help("Some files could not be read")
                    .popover(isPresented: $showingWarnings, arrowEdge: .trailing) {
                        ScanWarnings(progress: progress)
                    }
                }
            }
        }
    }
}

private struct ScanWarnings: View {
    let progress: ScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.failed > 0 {
                Text("\(progress.failed) file\(progress.failed == 1 ? "" : "s") could not be read as fonts.")
            }
            if progress.unreadableCount > 0 {
                Text("\(progress.unreadableCount) item\(progress.unreadableCount == 1 ? " was" : "s were") unreadable:")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(progress.unreadablePaths, id: \.self) {
                            Text($0).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if progress.unreadableCount > progress.unreadablePaths.count {
                            Text("…and \(progress.unreadableCount - progress.unreadablePaths.count) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            if progress.skippedRemovals > 0 {
                Text("\(progress.skippedRemovals) missing file\(progress.skippedRemovals == 1 ? " was" : "s were") kept in the library, because the folder could not be read completely.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

/// Rescan / reveal / relink / remove for a location; shared by the sidebar and Settings.
struct LocationMenu: View {
    @Environment(AppModel.self) private var model
    let location: LocationRecord

    var body: some View {
        Button("Rescan") { model.rescan(location.id) }
            .disabled(!location.online)
        Button("Reveal in Finder") { model.revealLocation(location.id) }
            .disabled(!location.online)
        if location.kind != .system {
            Button("Relink…") { chooseRelinkTarget(for: location, model: model) }
            Divider()
            Button("Remove from Library…") { model.confirmRemoveLocation(location.id) }
        }
    }
}

@MainActor
func chooseRelinkTarget(for location: LocationRecord, model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Relink"
    panel.message = "Choose the new place of “\(location.displayName)”."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await model.relink(location.id, to: url) }
}
