import AppKit
import FontoryCore
import SwiftUI

/// The browser in the Google Fonts view before consent (`AppModel.showsGoogleEmptyState`).
struct GoogleFontsEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Google Fonts")
                .font(.title2.weight(.semibold))
            Text("Every Google Fonts family, free and open source, downloaded to a folder you choose.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            GoogleDownloadButton()
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Download Google Fonts…": fetches the catalogue for the estimate (only on this click, never on appear) and opens
/// the consent sheet. Shared by the empty state and Settings.
struct GoogleDownloadButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingConsent = false
    @State private var isLoadingEstimate = false

    var body: some View {
        Button("Download Google Fonts…") {
            guard let google = model.google else { return }
            showingConsent = true
            isLoadingEstimate = true
            Task {
                await google.loadEstimate()
                isLoadingEstimate = false
            }
        }
        .disabled(model.google == nil)
        .sheet(isPresented: $showingConsent) {
            if let google = model.google {
                GoogleConsentSheet(google: google, isLoadingEstimate: isLoadingEstimate) { folder in
                    showingConsent = false
                    Task {
                        do { try await google.enable(at: folder) } catch {
                            model.alert = AlertItem(title: "Google Fonts could not be downloaded", message: error.localizedDescription)
                        }
                    }
                } cancel: {
                    showingConsent = false
                }
            }
        }
    }
}

/// "Download all of Google Fonts?": the family count and size from the catalogue, the folder with Change…, and a
/// warning (Download stays enabled) when the folder's volume has less free space than the size plus 20%.
private struct GoogleConsentSheet: View {
    let google: GoogleFontsController
    let isLoadingEstimate: Bool
    let download: (URL) -> Void
    let cancel: () -> Void
    @State private var folder: URL?
    @State private var availableBytes: Int64?

    /// Free space needed: the catalogue's size plus a 20% margin; nil when the size is unknown (no disk check).
    private var neededBytes: Int64? { google.estimatedBytes.map { Int64((Double($0) * 1.2).rounded(.up)) } }

    var body: some View {
        let folder = folder ?? google.defaultFolder
        VStack(alignment: .leading, spacing: 12) {
            Text("Download all of Google Fonts?")
                .font(.headline)
            if isLoadingEstimate {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the Google Fonts catalogue…").foregroundStyle(.secondary)
                }
            } else {
                Text(message(folder: folder))
                    .fixedSize(horizontal: false, vertical: true)
                if google.estimatedFamilies == nil {
                    Text(GoogleFontsController.unreachableMessage)
                        .foregroundStyle(.red)
                }
                if let neededBytes, let availableBytes, availableBytes < neededBytes {
                    Label("Not enough free space on this drive (needs about \(Self.size(neededBytes))).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                Spacer()
                Button("Change…") { chooseFolder(from: folder) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Download") { download(folder) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoadingEstimate)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: folder) {
            let url = folder
            availableBytes = await Task.detached { Self.availableBytes(at: url) }.value
        }
    }

    private func message(folder: URL) -> String {
        let size = google.estimatedBytes.map { Self.size(Int64($0)) } ?? "size unknown"
        guard let families = google.estimatedFamilies else {
            return "Google Fonts families (\(size)) will be downloaded to \(folder.path). They are added to your library turned off; activate the ones you want."
        }
        return "About \(families.formatted()) families (\(size)) will be downloaded to \(folder.path). They are added to your library turned off; activate the ones you want."
    }

    private func chooseFolder(from current: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder Google Fonts are downloaded to."
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Free space on the volume of `url`, or of its nearest existing parent (the folder may not exist yet).
    nonisolated static func availableBytes(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        return try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }
}
