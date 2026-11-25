import AppKit
import FontoryCore
import Foundation
import os
import UniformTypeIdentifiers

/// Restore progress, shown by `RestoreSheet`.
enum RestoreState: Equatable, Sendable {
    case reading
    case addingLocations
    case scanning(done: Int, total: Int)
    case applying
    case finished(RestoreResult)
    case failed(String)
}

extension UTType {
    /// `.fontorybackup`: a ZIP holding `manifest.json` (declared in Info.plist).
    static let fontoryBackup = UTType(exportedAs: "local.fontory.backup", conformingTo: .zip)
}

/// Backups (spec §19): the automatic daily backup at launch and quit, Back Up Now, and restore with a safety backup
/// first. Every store and file access runs off the main actor.
extension AppModel {
    private static let backupLog = Logger(subsystem: "local.fontory.app", category: "backup")
    /// The quit backup's share of the 5 s quit budget; activation shutdown follows it.
    static let quitBackupBudget: Duration = .seconds(3)

    /// `~/Library/Application Support/Fontory/Backups`, computed without creating anything.
    nonisolated static func defaultBackupDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Fontory/Backups", isDirectory: true)
    }

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Snapshots the library and writes it to `url` (creating its folder). Blocking: call off the main actor.
    nonisolated private static func writeBackup(_ store: FontStore, to url: URL, rank: [Int64], skip: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = try store.makeBackupManifest(created: Date(), appVersion: appVersion, locationRank: rank,
                                                    skipDuplicatesOnImport: skip)
        try BackupArchive.write(manifest, to: url)
    }

    // MARK: Automatic and manual backups

    /// Writes today's automatic backup (overwriting an earlier one of today), then deletes backups older than 10 days.
    /// Never throws: failures are logged.
    func writeAutomaticBackup() async {
        guard let backend else { return }
        let files = BackupFiles(directory: backupDirectory)
        let store = backend.store
        let rank = duplicateLocationRank, skip = skipDuplicatesOnImport
        let result = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
            Result {
                let now = Date()
                try AppModel.writeBackup(store, to: files.dailyURL(for: now), rank: rank, skip: skip)
                try files.prune(now: now)
            }
        }.value
        if case .failure(let error) = result {
            Self.backupLog.error("automatic backup failed: \(String(describing: error), privacy: .public)")
        }
        await refreshBackupEntries()
    }

    /// At launch, after the first library load: today's backup when it is missing. Runs behind the launch.
    func scheduleLaunchBackup() {
        let files = BackupFiles(directory: backupDirectory)
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) { !files.hasDaily(for: Date()) }.value
            guard missing else { return }
            await self?.writeAutomaticBackup()
        }
    }

    /// The quit backup, waited for at most `budget` (the write itself keeps going until the app exits).
    func writeAutomaticBackup(within budget: Duration) async {
        await awaitAtMost(budget, Task { await self.writeAutomaticBackup() })
    }

    /// Back Up Now: writes a backup of the library to `url`.
    func backUp(to url: URL) async throws {
        guard let backend else { return }
        await flushNotes()
        await quickCollectionWriteChain?.value
        let store = backend.store
        let rank = duplicateLocationRank, skip = skipDuplicatesOnImport
        try await Task.detached(priority: .userInitiated) {
            try AppModel.writeBackup(store, to: url, rank: rank, skip: skip)
        }.value
        await refreshBackupEntries()
    }

    func refreshBackupEntries() async {
        let files = BackupFiles(directory: backupDirectory)
        let entries = await Task.detached(priority: .utility) { files.list() }.value
        if entries != backupEntries { backupEntries = entries }
    }

    /// "Back Up Now…" / File ▸ Back Up Library…: a save panel, then the backup.
    func showBackUpPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fontoryBackup]
        panel.nameFieldStringValue = BackupFiles(directory: backupDirectory).dailyURL(for: Date()).lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await backUp(to: url)
            } catch {
                alert = AlertItem(title: "The backup could not be written", message: Self.backupMessage(error))
            }
        }
    }

    // MARK: Restore

    /// "Restore from File…": an open panel, then the confirmation with the backup's date (an unreadable file shows the
    /// failure instead, and nothing else happens).
    func showRestorePanel() {
        guard restoreTask == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fontoryBackup]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let read = await Task.detached(priority: .userInitiated) { Result { try BackupArchive.read(url) } }.value
            switch read {
            case .success(let manifest): confirmRestore(from: url, date: manifest.created, showsTime: true)
            case .failure(let error): restoreState = .failed(Self.backupMessage(error))
            }
        }
    }

    /// Every restore asks first.
    func confirmRestore(from url: URL, date: Date, showsTime: Bool) {
        let when = date.formatted(date: .long, time: showsTime ? .shortened : .omitted)
        alert = AlertItem(
            title: "Restore the library from \(when)?",
            message: "Tags, notes, the Quick Collection and family names are replaced. A backup of the current library is made first.",
            actionTitle: "Restore", isDestructive: true,
            action: { [weak self] in
                guard let self else { return }
                let activation = self.restoreActivation
                Task { await self.beginRestore(from: url, restoreActivation: activation) }
            })
    }

    /// Restores the backup at `url`; returns when it has finished, failed or been cancelled. Progress is in
    /// `restoreState`. A backup that cannot be read fails before anything is written.
    func beginRestore(from url: URL, restoreActivation: Bool) async {
        guard let backend, restoreTask == nil else { return }
        restoreCancelled = false
        restoreState = .reading
        let task = Task { await self.runRestore(url, restoreActivation: restoreActivation, backend: backend) }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    /// Cancel (and quitting): stops a restore that has not started applying. Locations already re-added stay.
    func cancelRestore() {
        guard restoreTask != nil, !restoreCancelled else { return }
        switch restoreState {
        case .reading, .addingLocations, .scanning, nil:
            restoreCancelled = true
            restoreState = nil
        case .applying, .finished, .failed:
            return
        }
    }

    /// Closes the sheet after a restore ended (finished or failed).
    func dismissRestore() {
        guard restoreTask == nil else { return }
        restoreState = nil
    }

    /// Sets the progress unless the restore was cancelled (the sheet is gone then).
    private func setRestoreState(_ state: RestoreState) {
        if !restoreCancelled { restoreState = state }
    }

    private func runRestore(_ url: URL, restoreActivation: Bool, backend: LibraryBackend) async {
        let store = backend.store
        // 1. Read the whole backup first: an unreadable one changes nothing.
        let read = await Task.detached(priority: .userInitiated) { Result { try BackupArchive.read(url) } }.value
        let manifest: BackupManifest
        switch read {
        case .success(let m): manifest = m
        case .failure(let error):
            setRestoreState(.failed(Self.backupMessage(error)))
            return
        }
        guard !restoreCancelled else { return }

        // 2. The safety backup, with pending notes and Quick Collection writes in it. Never overwritten: a name taken
        // (two restores within a second) moves on by a second.
        await flushNotes()
        await quickCollectionWriteChain?.value
        let files = BackupFiles(directory: backupDirectory)
        let rank = duplicateLocationRank, skip = skipDuplicatesOnImport
        let safety = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            Result {
                var date = Date()
                while FileManager.default.fileExists(atPath: files.safetyURL(for: date).path) { date += 1 }
                try AppModel.writeBackup(store, to: files.safetyURL(for: date), rank: rank, skip: skip)
                _ = try? files.prune(now: Date())
            }
        }.value
        if case .failure(let error) = safety {
            setRestoreState(.failed("A backup of the current library could not be written, so nothing was restored. \(Self.backupMessage(error))"))
            return
        }
        await refreshBackupEntries()
        guard !restoreCancelled else { return }

        // 3. Re-add the backup's folders and file sets that are missing from the library and reachable.
        setRestoreState(.addingLocations)
        let added = await reAddMissingLocations(manifest, backend: backend)

        // 4. Scan them (file sets import their listed members that exist). Cancel stops waiting; what was added stays.
        let total = added.folders.count + added.fileSets.count
        if total > 0 {
            setRestoreState(.scanning(done: 0, total: total))
            await reloadLocations()
            for id in added.folders { rescan(id) }
            updateWatchers()
            var imported = 0
            for (loc, urls) in added.fileSets where !restoreCancelled {
                scanProgress[loc.id] = ScanProgress(locationID: loc.id, phase: .parsing, total: urls.count)
                let skip = skipDuplicatesOnImport
                let progress = await runBackground { try backend.importFiles(urls, into: loc, skipDuplicates: skip) }
                scanProgress[loc.id] = progress ?? ScanProgress(locationID: loc.id, phase: .aborted(reason: "import failed"))
                imported += 1
                setRestoreState(.scanning(done: imported, total: total))
            }
            if !added.fileSets.isEmpty { await scanFinished() }
            while !restoreCancelled {
                let pending = added.folders.filter(isScanning).count
                setRestoreState(.scanning(done: imported + added.folders.count - pending, total: total))
                if pending == 0 && !holdsScanForSmoke { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !restoreCancelled else { return }

        // 5. Apply, in one transaction.
        setRestoreState(.applying)
        await flushNotes()
        let applied = await Task.detached(priority: .userInitiated) { () -> Result<RestoreResult, Error> in
            Result { try store.restore(manifest, locationMap: try store.locationMap(for: manifest)) }
        }.value
        let result: RestoreResult
        switch applied {
        case .success(let r): result = r
        case .failure(let error):
            restoreState = .failed("The backup could not be applied; the library was not changed. \(Self.backupMessage(error))")
            return
        }
        // Tags, notes and the Quick Collection read before the restore are stale.
        tagWriteEpoch += 1
        // The undo's old names and an open rename sheet's face ids predate the restore.
        familyUndo = nil
        familyNameRequest = nil
        quickCollectionGeneration += 1
        savedNotes = [:]
        pendingNotes = [:]

        // 6. Activation, when asked: saved states back on, faces active now but off in the backup off.
        if restoreActivation { await applyRestoredActivation(result.activations, backend: backend) }

        // 7. Settings (written to `settingsDefaults`, the smoke run's own suite there).
        duplicateLocationRank = result.locationRank
        skipDuplicatesOnImport = result.skipDuplicatesOnImport

        // 8. Tags, counts, the Quick Collection and the browser (family names changed too).
        forgetGlyphs()
        invalidateRows()
        await afterTagChange()
        await loadQuickCollection()
        refreshCounts()
        scheduleRefresh()
        restoreState = .finished(result)
    }

    private var holdsScanForSmoke: Bool {
        #if DEBUG
        holdsRestoreScanForSmoke
        #else
        false
        #endif
    }

    private enum ReAdded: Sendable {
        case folder(Int64)
        case fileSet(LocationRecord, [URL])
    }

    /// Adds the backup's folder and file-set locations that the library lacks and whose folder is reachable (it
    /// resolves by volume, or exists at its last known path). File sets get only their listed members that exist.
    /// Locations that cannot be added stay out of the location map and are reported as unreachable by the restore.
    private func reAddMissingLocations(_ manifest: BackupManifest, backend: LibraryBackend)
        async -> (folders: [Int64], fileSets: [(LocationRecord, [URL])]) {
        let mapped = await runBackground { try backend.store.locationMap(for: manifest) } ?? [:]
        let missing = manifest.locations.filter {
            mapped[$0.index] == nil && ($0.kind == LocationKind.folder.rawValue || $0.kind == LocationKind.fileSet.rawValue
                || $0.kind == LocationKind.googleFonts.rawValue)
        }
        var folders: [Int64] = []
        var fileSets: [(LocationRecord, [URL])] = []
        for loc in missing where !restoreCancelled {
            let readded = await runBackground { () -> ReAdded? in
                guard let dir = AppModel.reachableFolder(loc) else { return nil }
                if loc.kind == LocationKind.folder.rawValue { return .folder(try backend.addFolder(dir).id) }
                if loc.kind == LocationKind.googleFonts.rawValue {
                    // The catalog owns this location (it gets its own sidebar row), so it is restored as-is, not via the overlap checks.
                    let ref = try VolumeIdentity.ref(for: dir)
                    return .folder(try backend.store.upsertLocation(kind: .googleFonts, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                                                    displayName: dir.lastPathComponent, lastKnownPath: dir.standardizedFileURL.path).id)
                }
                let urls = (loc.members ?? []).map { dir.appendingPathComponent($0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty, case .fileSet(let record) = try backend.fileTarget(for: dir) else { return nil }
                return .fileSet(record, urls)
            }
            switch readded ?? nil {
            case .folder(let id): folders.append(id)
            case .fileSet(let record, let urls): fileSets.append((record, urls))
            case nil: break
            }
        }
        return (folders, fileSets)
    }

    nonisolated private static func reachableFolder(_ loc: BackupManifest.Location) -> URL? {
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        if let url = VolumeIdentity.resolve(VolumeRef(volumeUUID: loc.volumeUUID, relativePath: loc.relativePath)), isDirectory(url) {
            return url
        }
        let last = URL(fileURLWithPath: loc.lastKnownPath, isDirectory: true)
        return loc.lastKnownPath.isEmpty || !isDirectory(last) ? nil : last
    }

    /// Deactivates faces active in Fontory now but not in `activations`, then activates the saved ones with their state.
    private func applyRestoredActivation(_ activations: [Int64: Int], backend: LibraryBackend) async {
        let active = await runBackground { try backend.store.activeFiles(states: [.on, .temporary]) } ?? []
        let off = active.flatMap(\.faceIDs).filter { activations[$0] == nil }
        if !off.isEmpty { await setActivation(off, .off) }
        for state in [ActivationState.on, .temporary] {
            let ids = activations.filter { $0.value == state.rawValue }.keys.sorted()
            if !ids.isEmpty { await setActivation(ids, state) }
        }
    }

    nonisolated static func backupMessage(_ error: Error) -> String {
        guard let error = error as? BackupError else { return error.localizedDescription }
        switch error {
        case .notABackup: return "The file is not a Fontory backup."
        case .unsupportedVersion(let version): return "The backup was made by a newer version of Fontory (format \(version))."
        case .unreadable(let detail): return "The backup could not be read: \(detail)"
        }
    }
}
