import AppKit
import FontoryCore
import Foundation
import os

/// Cancel request shared with the copying thread.
final class ExportCancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// Export fonts (spec §19): the distinct files of some faces copied to a chosen folder, optionally by family and/or
/// zipped. Store access and copying run off the main actor.
extension AppModel {
    /// Exports of more than this many files show a progress sheet with Cancel.
    static let exportProgressThreshold = 50

    /// The Font menu's target: the selection (on the family page, its selected styles).
    func exportSelection() async {
        await exportFonts(faceIDs: tagPanelTargets, suggestedName: "Fonts")
    }

    func exportTag(_ id: Int64) async {
        guard let backend, let name = tag(id)?.name else { return }
        let query = LibraryQuery(scope: .tags([tagPick(id)]), includeSystem: query.includeSystem)
        guard let ids = await runBackground({ try backend.store.faceIDs(for: query) }, failureTitle: "The fonts could not be exported"),
              !ids.isEmpty else { return }
        await exportFonts(faceIDs: ids, suggestedName: name)
    }

    func exportQuickCollection() async {
        await exportFonts(faceIDs: quickCollectionIDs.sorted(), suggestedName: "Quick Collection")
    }

    func exportFamily(_ detail: FamilyDetail) async {
        await exportFonts(faceIDs: detail.faceIDs, suggestedName: detail.family)
    }

    /// "<N> fonts are on a drive that isn't connected." plus the question unless everything is offline.
    static func offlineMessage(_ count: Int, askingToContinue: Bool = true) -> String {
        let noun = count == 1 ? "font is" : "fonts are"
        return "\(count.formatted()) \(noun) on a drive that isn't connected." + (askingToContinue ? " Export the others?" : "")
    }

    /// The whole flow: files, the offline question, the folder panel, the copy, the result.
    func exportFonts(faceIDs: [Int64], suggestedName: String) async {
        guard let backend, !faceIDs.isEmpty, exportProgress == nil else { return }
        guard let files = await runBackground({ try backend.store.exportFiles(faceIDs: faceIDs) },
                                              failureTitle: "The fonts could not be exported"),
              !files.isEmpty else { return }
        let offline = files.filter { $0.url == nil }.count
        if offline == files.count {
            alert = AlertItem(title: "The fonts are offline", message: Self.offlineMessage(offline, askingToContinue: false))
            return
        }
        if offline > 0 {
            if let answer = exportOfflineAnswer {
                guard answer(offline) else { return }
            } else if exportDestinationOverride == nil {
                alert = AlertItem(title: "Some fonts are offline", message: Self.offlineMessage(offline),
                                  actionTitle: "Export") { [weak self] in
                    guard let self else { return }
                    Task { await self.chooseAndExport(files, suggestedName: suggestedName) }
                }
                return
            }
        }
        await chooseAndExport(files, suggestedName: suggestedName)
    }

    private func chooseAndExport(_ files: [ExportFile], suggestedName: String) async {
        let folder: URL
        let options: ExportOptions
        if let override = exportDestinationOverride {
            folder = override
            let o = exportOptionsOverride ?? (byFamily: false, zip: false)
            options = ExportOptions(byFamily: o.byFamily, zip: o.zip, archiveName: suggestedName)
        } else {
            guard let (url, byFamily, zip) = Self.runExportPanel() else { return }
            folder = url
            options = ExportOptions(byFamily: byFamily, zip: zip, archiveName: suggestedName)
        }
        exportCancel = ExportCancelFlag()
        let cancel = exportCancel
        if files.count > Self.exportProgressThreshold { exportProgress = (0, files.count) }
        let showsProgress = exportProgress != nil
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ExportResult, Error> in
            Result {
                try FontExporter.export(files, to: folder, options: options, progress: { done, total in
                    guard showsProgress else { return }
                    Task { @MainActor [weak self] in
                        if self?.exportProgress != nil { self?.exportProgress = (done, total) }
                    }
                }, isCancelled: { cancel.isCancelled })
            }
        }.value
        exportProgress = nil
        switch result {
        case .success(let r):
            lastExportResult = r
            if exportDestinationOverride == nil { showExportResult(r) }
        case .failure(let error):
            lastExportResult = nil
            if error is CancellationError { return }
            if exportDestinationOverride == nil {
                alert = AlertItem(title: "The fonts could not be exported", message: error.localizedDescription)
            }
        }
    }

    /// Cancel on the progress sheet: a folder export keeps what was copied; a ZIP export writes nothing.
    func cancelExport() { exportCancel.cancel() }

    private func showExportResult(_ r: ExportResult) {
        let title = r.copied == 1 ? "Exported 1 file" : "Exported \(r.copied.formatted()) files"
        let skipped = r.skipped == 0 ? "" : r.skipped == 1 ? " 1 file was skipped." : " \(r.skipped.formatted()) files were skipped."
        alert = AlertItem(title: title, message: "Saved to \(r.output.lastPathComponent).\(skipped)",
                          actionTitle: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([r.output])
        }
    }

    /// A folder panel with the two option checkboxes as its accessory view; nil when cancelled.
    private static func runExportPanel() -> (URL, Bool, Bool)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose where to export the fonts."
        let family = NSButton(checkboxWithTitle: "Folders by family", target: nil, action: nil)
        let zip = NSButton(checkboxWithTitle: "Compress as ZIP", target: nil, action: nil)
        let stack = NSStackView(views: [family, zip])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        panel.accessoryView = stack
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, family.state == .on, zip.state == .on)
    }
}
