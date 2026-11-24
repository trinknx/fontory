import FontoryCore
import SwiftUI

enum SettingsTab: Hashable, Sendable {
    case general, locations, duplicates, backups
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            LocationSettings()
                .tabItem { Label("Locations", systemImage: "folder") }
                .tag(SettingsTab.locations)
            DuplicateSettings()
                .tabItem { Label("Duplicates", systemImage: "doc.on.doc") }
                .tag(SettingsTab.duplicates)
            BackupsSettingsView()
                .tabItem { Label("Backups", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.backups)
        }
        .frame(width: 560, height: 460)
        // One presenter for every tab.
        .modelAlert(model, inSettings: true)
        // Every restore starts here (the File menu's Restore Library… opens the Backups tab).
        .sheet(isPresented: Binding(get: { model.restoreState != nil }, set: { if !$0 { model.dismissRestore() } })) {
            RestoreSheet()
                .environment(model)
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.keepRunningInMenuBar) private var keepRunningInMenuBar = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginNote: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in updateLaunchAtLogin(on) }
            if let loginNote {
                HStack {
                    Text(loginNote).font(.caption).foregroundStyle(.secondary)
                    if loginNote.contains("System Settings") {
                        Button("Open Login Items") { SMAppServiceSettings.open() }.controlSize(.small)
                    }
                }
            }
            Toggle("Keep running in menu bar when the window is closed", isOn: $keepRunningInMenuBar)
            Toggle("Show system fonts", isOn: $model.query.includeSystem)
        }
        .formStyle(.grouped)
    }

    private func updateLaunchAtLogin(_ on: Bool) {
        guard on else {
            loginNote = LaunchAtLogin.disable().map { "Could not remove the login item: \($0)" }
            return
        }
        switch LaunchAtLogin.enable() {
        case .registered: loginNote = nil
        case .requiresApproval: loginNote = "Allow Fontory in System Settings › General › Login Items."
        case .launchAgent: loginNote = "Installed as a launch agent in ~/Library/LaunchAgents."
        case .failed(let message):
            loginNote = "Launch at login could not be set up: \(message)"
            launchAtLogin = false
        }
    }
}

import ServiceManagement

private enum SMAppServiceSettings {
    static func open() { SMAppService.openSystemSettingsLoginItems() }
}

private struct LocationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.listedLocations, selection: $selection) {
                TableColumn("Name") { loc in
                    Label(loc.displayName, systemImage: symbol(loc.kind))
                }
                TableColumn("Path") { loc in
                    Text(loc.lastKnownPath).foregroundStyle(.secondary).truncationMode(.middle)
                }
                TableColumn("Fonts") { loc in
                    Text((model.counts.perLocation[loc.id] ?? 0).formatted())
                }
                .width(60)
                TableColumn("Status") { loc in
                    Text(status(loc)).foregroundStyle(loc.online ? Color.secondary : Color.orange)
                }
                .width(90)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if let id = ids.first, let loc = model.location(id) { LocationMenu(location: loc) }
            }

            HStack {
                Button { model.showImportPanel() } label: { Image(systemName: "plus") }
                    .help("Add folders or fonts")
                Button { if let selected { model.confirmRemoveLocation(selected.id) } } label: { Image(systemName: "minus") }
                    .disabled(selected == nil || selected?.kind.isReadOnly == true)
                    .help("Remove the location from the library")
                Spacer()
                Button("Relink…") { if let selected { chooseRelinkTarget(for: selected, model: model) } }
                    .disabled(selected == nil || selected?.kind.isReadOnly == true)
                Button("Rescan") { if let selected { model.rescan(selected.id) } }
                    .disabled(selected?.online != true)
            }
        }
        .padding()
    }

    private var selected: LocationRecord? { selection.flatMap(model.location) }

    private func symbol(_ kind: LocationKind) -> String {
        switch kind {
        case .system: "lock"
        case .userInstalled: "person.crop.square"
        case .fileSet: "doc.on.doc"
        case .folder: "folder"
        }
    }

    private func status(_ loc: LocationRecord) -> String {
        if !loc.online { return "Offline" }
        switch model.scanProgress[loc.id]?.phase {
        case .enumerating, .parsing, .applying: return "Scanning…"
        case .aborted: return "Scan stopped"
        default: return loc.lastScan.map { $0.formatted(.relative(presentation: .named)) } ?? "Not scanned"
        }
    }
}

/// Settings → Duplicates: the location ranking "Select Copies to Remove" follows, "Skip duplicates on import", and the
/// files removed from the library with Include Again.
private struct DuplicateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep copies in").font(.headline)
            Text("Select Copies to Remove keeps the active copy, then the better format (OTF, TTF, TTC, WOFF2, WOFF), then the copy in the location higher in this list. Drag to reorder.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.effectiveLocationRank, id: \.self) { id in
                    if let loc = model.location(id) {
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Text(loc.displayName)
                            Spacer()
                            Text(loc.lastKnownPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .onMove { model.moveLocationRank(from: $0, to: $1) }
            }
            .frame(height: 120)

            Toggle("Skip duplicates on import", isOn: $model.skipDuplicatesOnImport)
            Text("A new file whose content matches a file already in another location is not added. The scan reports how many were skipped.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Excluded files").font(.headline).padding(.top, 4)
            if model.excludedFiles.isEmpty {
                Text("Files removed from the library with Remove from Library are listed here.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.excludedFiles) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.relativePath as NSString).lastPathComponent).lineLimit(1)
                            Text("\(model.location(file.locationID)?.displayName ?? "Unknown location") · \(file.relativePath)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Include Again") { Task { await model.includeAgain(file) } }
                            .controlSize(.small)
                            .help("Deletes the exclusion and rescans the location")
                    }
                }
            }
        }
        .padding()
        .task { await model.loadExcludedFiles() }
    }
}
