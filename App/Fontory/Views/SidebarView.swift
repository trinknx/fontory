import AppKit
import FontoryCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        List(selection: selection) {
            Section("Library") {
                libraryRow("All Fonts", "textformat", .all, model.counts.all)
                libraryRow("System", "lock", .system, model.counts.system)
                    .help("Fonts that ship with macOS (read-only)")
                libraryRow("User", "person", .user, model.counts.user)
                    .help("Fonts active outside Fontory: /Library/Fonts, ~/Library/Fonts, Font Book, Adobe and other apps")
                libraryRow("Activated", "checkmark.circle", .activated, model.counts.activated)
                    .help("Everything active on this Mac: System, User and the fonts Fontory activated")
                libraryRow("Deactivated", "circle", .deactivated, model.counts.deactivated)
                    .help("Library fonts that are active nowhere")
                libraryRow("Offline", "externaldrive.badge.xmark", .offline, model.counts.offline)
                libraryRow("Last Import", "square.and.arrow.down", .recentImport, model.counts.lastImport)
                libraryRow("Untagged", "square.dashed", .untagged, model.organizationCounts.untagged)
                    .help("Fonts without any tag")
                libraryRow("Quick Collection", "bookmark", .quickCollection, model.organizationCounts.quickCollection)
            }

            Section("Locations") {
                if model.userLocations.isEmpty {
                    Text("Drop font folders or files here")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.userLocations) { LocationNode(location: $0) }
            }

            Section("Installed Fonts") {
                // The eye is the switch: open when system fonts are shown, slashed when hidden. No checkbox.
                Button {
                    model.query.includeSystem.toggle()
                } label: {
                    Label(model.query.includeSystem ? "System Fonts Shown" : "System Fonts Hidden",
                          systemImage: model.query.includeSystem ? "eye" : "eye.slash")
                        .foregroundStyle(model.query.includeSystem ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .help(model.query.includeSystem ? "Click to hide system fonts" : "Click to show system fonts")
                .accessibilityValue(model.query.includeSystem ? "Shown" : "Hidden")
                ForEach(model.installedLocations) { LocationNode(location: $0) }
            }

            TagsSection()
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarAddButton() }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], delegate: ImportDrop(model: model, isTargeted: $isDropTargeted))
    }

    /// Tag rows may be selected together (⌘-click); the model turns the list's change into a scope, reading the
    /// click's modifier keys (⌥ inverts a tag).
    private var selection: Binding<Set<SidebarItem>> {
        Binding(get: { model.sidebarSelection },
                set: { model.applySidebarSelection($0, modifiers: EventModifiers(NSApp.currentEvent?.modifierFlags ?? []),
                                                   time: NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime) })
    }

    private func libraryRow(_ title: String, _ symbol: String, _ scope: LibraryQuery.Scope, _ count: Int) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .tag(SidebarItem.scope(scope))
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
            .tag(SidebarItem.scope(.location(id: location.id, subfolder: nil)))
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
            .tag(SidebarItem.scope(.location(id: locationID, subfolder: path)))
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
        case .userInstalled: return "person.crop.square"
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
                let removed = model.removalNotices[location.id] ?? 0
                if progress.unreadableCount > 0 || progress.failed > 0 || removed > 0 {
                    Button { showingWarnings = true } label: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    .buttonStyle(.borderless)
                    .help(removed > 0 ? "Fonts with activation or notes were removed" : "Some files could not be read")
                    .popover(isPresented: $showingWarnings, arrowEdge: .trailing) {
                        ScanWarnings(progress: progress, removedWithUserData: removed) {
                            showingWarnings = false
                            model.dismissRemovalNotice(location.id)
                        }
                    }
                }
            }
        }
    }
}

private struct ScanWarnings: View {
    let progress: ScanProgress
    /// Faces with activation or notes removed by scans since the user last dismissed the notice.
    let removedWithUserData: Int
    let dismissRemovals: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if removedWithUserData > 0 {
                Text("\(removedWithUserData.formatted()) font\(removedWithUserData == 1 ? "" : "s") with activation or notes \(removedWithUserData == 1 ? "was" : "were") removed because \(removedWithUserData == 1 ? "its file is" : "their files are") gone.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK", action: dismissRemovals)
                    .controlSize(.small)
                if progress.failed > 0 || progress.unreadableCount > 0 || progress.skippedRemovals > 0 { Divider() }
            }
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
        if !location.kind.isReadOnly {
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

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
    }
}

/// Font files and folders dropped on the sidebar are imported. Fonts dragged from the browser also carry file URLs;
/// they are refused here (only plain tag rows take them), so dropping them on a Library or Style row does nothing.
private struct ImportDrop: DropDelegate {
    let model: AppModel
    @Binding var isTargeted: Bool

    private func isImport(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !info.hasItemsConforming(to: [.fontoryFaceIDs])
    }

    func validateDrop(info: DropInfo) -> Bool { isImport(info) }

    func dropEntered(info: DropInfo) { isTargeted = isImport(info) }

    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isImport(info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard isImport(info) else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        let collected = URLBox()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.append(url) }
                group.leave()
            }
        }
        let model = model
        group.notify(queue: .main) {
            let urls = collected.urls
            MainActor.assumeIsolated { if !urls.isEmpty { model.importDropped(urls) } }
        }
        return !providers.isEmpty
    }

    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        func append(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
    }
}
