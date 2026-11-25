import AppKit
import FontoryCore
import SwiftUI

/// Settings → Google Fonts: the download folder with Change… (Move Files / Leave Them when it holds fonts), status
/// and progress, Pause/Resume, Check for Updates with the last check, the failed families with Retry Failed, Stop
/// Syncing and Remove Google Fonts from Library. Before consent it offers Download Google Fonts… only.
struct GoogleFontsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let google = model.google {
                if google.location == nil && !google.isEnabled {
                    Text("Every Google Fonts family, free and open source, downloaded to a folder you choose.")
                        .fixedSize(horizontal: false, vertical: true)
                    GoogleDownloadButton()
                } else {
                    GoogleFontsSyncSettings(google: google)
                }
            } else {
                Text("Google Fonts are not available.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GoogleFontsSyncSettings: View {
    @Environment(AppModel.self) private var model
    let google: GoogleFontsController

    var body: some View {
        let phase = google.phase
        Text("Folder").font(.headline)
        HStack {
            Text(google.defaultFolder.path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(google.defaultFolder.path)
            Spacer()
            Button("Change…") { changeFolder() }
                .disabled(google.location == nil)
        }

        Text("Status").font(.headline).padding(.top, 4)
        HStack(spacing: 8) {
            Text(statusText(phase))
                .foregroundStyle(phase.isError ? Color.red : Color.secondary)
            Spacer()
            if google.isEnabled {
                if phase == .paused {
                    Button("Resume") { google.resume() }
                } else {
                    Button("Pause") { google.pause() }
                        .disabled(phase == .offline)
                }
            }
        }
        if case .downloading(let done, let total) = phase, total > 0 {
            ProgressView(value: Double(min(done, total)), total: Double(total))
                .progressViewStyle(.linear)
        }

        HStack {
            Text("Last checked: \(google.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Check for Updates") { Task { await google.checkForUpdates(force: true) } }
                .disabled(!google.isEnabled || phase == .checking || phase == .offline)
        }

        HStack {
            let failed = google.failedFamilies
            Text(failed == 0 ? "No failed families" : "\(failed.formatted()) famil\(failed == 1 ? "y" : "ies") failed to download")
                .foregroundStyle(.secondary)
            Spacer()
            // Failed families are downloaded again by the next run.
            Button("Retry Failed") { google.resume() }
                .disabled(!google.isEnabled || failed == 0 || isRunning(phase) || phase == .offline)
        }

        Divider().padding(.vertical, 4)
        HStack {
            if google.isEnabled {
                Button("Stop Syncing") { google.disable() }
                    .help("No more downloads or update checks. The folder and its fonts stay in the library.")
            } else if let location = google.location {
                Button("Start Syncing") {
                    let folder = URL(fileURLWithPath: location.lastKnownPath, isDirectory: true)
                    Task {
                        do { try await google.enable(at: folder) } catch {
                            model.alert = AlertItem(title: "Google Fonts could not be synced", message: error.localizedDescription)
                        }
                    }
                }
            }
            Spacer()
            Button("Remove Google Fonts from Library") { confirmRemove() }
                .disabled(google.location == nil)
        }
        Text("Removing keeps the downloaded files on disk.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func isRunning(_ phase: GooglePhase) -> Bool {
        if case .downloading = phase { return true }
        return phase == .checking
    }

    private func statusText(_ phase: GooglePhase) -> String {
        if let detail = phase.sidebarDetail { return detail }
        switch phase {
        case .checking: return "Checking for updates…"
        case .idle: return "Up to date"
        default: return "Syncing is off"
        }
    }

    /// NSOpenPanel for the new folder; when the current one holds fonts, asks whether to move them there.
    private func changeFolder() {
        guard let location = google.location else { return }
        let current = URL(fileURLWithPath: location.lastKnownPath, isDirectory: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder Google Fonts are downloaded to."
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var moveFiles = false
        if Self.hasFiles(current) {
            let alert = NSAlert()
            alert.messageText = "Move the downloaded Google Fonts to the new folder?"
            alert.informativeText = "Move Files keeps the fonts' activation. Leave Them keeps the files where they are, removes that folder from the library and downloads every family again into the new folder."
            alert.addButton(withTitle: "Move Files")
            alert.addButton(withTitle: "Leave Them")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: moveFiles = true
            case .alertSecondButtonReturn: moveFiles = false
            default: return
            }
        }
        Task {
            do { try await google.changeFolder(to: url, moveFiles: moveFiles) } catch {
                model.alert = AlertItem(title: "The Google Fonts folder could not be changed", message: error.localizedDescription)
            }
        }
    }

    /// The folder holds anything besides hidden items (such as the download's temporary folder).
    private static func hasFiles(_ folder: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return !items.isEmpty
    }

    private func confirmRemove() {
        let path = google.location?.lastKnownPath ?? ""
        model.alert = AlertItem(
            title: "Remove Google Fonts from Library?",
            message: "Syncing stops and the Google Fonts fonts are removed from the library. The files stay in “\(path)”.",
            actionTitle: "Remove", isDestructive: true) { [google, model] in
                Task {
                    do { try await google.removeFromLibrary() } catch {
                        model.alert = AlertItem(title: "Google Fonts could not be removed", message: error.localizedDescription)
                    }
                }
            }
    }
}
