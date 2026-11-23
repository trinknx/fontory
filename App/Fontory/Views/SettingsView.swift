import FontoryCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LocationSettings()
                .tabItem { Label("Locations", systemImage: "folder") }
        }
        .frame(width: 560, height: 380)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.restoreOnLaunch) private var restoreOnLaunch = true
    @AppStorage(SettingsKey.keepRunningInMenuBar) private var keepRunningInMenuBar = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginNote: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Restore activated fonts on launch", isOn: $restoreOnLaunch)
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
        .modelAlert(model, inSettings: true)
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
