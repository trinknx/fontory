import AppKit
import FontoryCore

/// A file removed from the library by Remove from Library (Settings → Duplicates lists them with Include Again).
struct ExcludedFile: Identifiable, Hashable, Sendable {
    var locationID: Int64
    var relativePath: String
    var id: String { "\(locationID)/\(relativePath)" }
}

/// What Move to Trash did, per file.
struct TrashResult: Sendable {
    struct Failure: Sendable, Hashable {
        var fileID: Int64
        var name: String
        var message: String
    }

    /// Files moved to the Trash (and deleted from the index), and where they are now.
    var recycled: [Int64] = []
    var trashedURLs: [URL] = []
    var failures: [Failure] = []
}

/// The Duplicates view's data, read off the main actor.
struct DuplicateSnapshot: Sendable {
    var groups: [DuplicateGroup]
    var rows: [Int64: FaceRow]
    var files: [Int64: FileRecord]
}

/// A checked file as the store has it now, read just before it is removed or trashed.
struct RemovalCandidate: Sendable {
    var fileID: Int64
    var locationID: Int64
    var name: String
    var url: URL?
    var activeFaceIDs: [Int64]
    /// System or user-installed location, or active outside Fontory: never removed or trashed.
    var isProtected: Bool
    /// Faces with activation, tags, notes or Quick Collection membership (the "N fonts removed" notice).
    var userDataFaces: Int
    /// Faces with tags, a note or Quick Collection membership, which Remove from Library loses (it confirms first).
    var organizedFaces: Int
}

/// Library → Duplicates: the search (hashing, then grouping), the checkboxes and the two removals. Store calls and
/// hashing run off the main actor; hashing is cancelled on unmount and on quit, like the face backfill.
extension AppModel {
    // MARK: Showing

    /// Selecting the Duplicates row: the view replaces the browser and searches.
    func showDuplicates() {
        closeFamilyDetail()
        isShowingDuplicates = true
        isShowingFilters = false  // the view ignores filters (`filtersAvailable`)
        findDuplicates()
        Task { await loadExcludedFiles() }
    }

    /// Back to the browser.
    func closeDuplicates() {
        guard isShowingDuplicates else { return }
        isShowingDuplicates = false
        previewPipeline.cancelAll(lane: .duplicates)
    }

    // MARK: Search

    /// Find Again: hashes the candidate files (equal fingerprints, no hash yet), then groups.
    func findDuplicates() {
        startDuplicateSearch(hashing: true)
    }

    /// Starts a search; without `hashing` only the groups are read (from the hashes stored). Never two at once: a start
    /// while one runs (or while an unmount is handled) runs once more afterwards.
    ///
    /// Hashing never overlaps the face backfill (both read every file): a hashing search asked for while the backfill
    /// runs waits ("Waiting for font details…") and starts when the backfill is idle (`duplicateSearchAfterFaceBackfill`).
    /// Any start meanwhile joins that pending search.
    func startDuplicateSearch(hashing: Bool) {
        guard let backend, !duplicateSearchStopped else { return }
        if isWaitingForFaceBackfill { return }
        if unmountsInProgress > 0 || duplicateTask != nil {
            duplicateRerun = (duplicateRerun ?? false) || hashing
            return
        }
        if hashing && faceBackfillTask != nil {
            isWaitingForFaceBackfill = true
            isFindingDuplicates = true
            return
        }
        duplicateRerun = nil
        duplicateRuns += 1
        isFindingDuplicates = true
        let store = backend.store
        let includeSystem = query.includeSystem
        duplicateTask = Task { [weak self] in
            if hashing {
                // Each batch reads its files in a detached utility task (DuplicateFinder); cancelling this task stops
                // it between files, and the loop ends only once no batch is in flight.
                for await progress in DuplicateFinder(store: store).hashCandidates() {
                    self?.duplicateHashProgressed(progress)
                }
            }
            var snapshot: DuplicateSnapshot?
            if !Task.isCancelled {
                snapshot = await Task.detached(priority: .utility) {
                    try? AppModel.loadDuplicateSnapshot(store: store, includeSystem: includeSystem)
                }.value
            }
            self?.duplicateSearchEnded(snapshot, cancelled: Task.isCancelled)
        }
    }

    /// The Duplicates view's progress line while a search runs.
    var duplicateSearchStatus: String {
        if isWaitingForFaceBackfill { return "Waiting for font details…" }
        if let p = duplicateProgress { return "Comparing files… \(p.done.formatted()) of \(p.total.formatted())" }
        return "Looking for duplicates…"
    }

    /// The face backfill ended (and no rerun started): runs the hashing search that waited for it.
    func duplicateSearchAfterFaceBackfill() {
        guard isWaitingForFaceBackfill, faceBackfillTask == nil else { return }
        isWaitingForFaceBackfill = false
        isFindingDuplicates = duplicateTask != nil
        startDuplicateSearch(hashing: true)
    }

    /// An unmount began: stops hashing (it may read from the volume) without a rerun. The handler calls
    /// `duplicateSearchAfterUnmount` once the volume's locations are offline.
    func cancelDuplicateSearch() {
        duplicateRerun = nil
        duplicateTask?.cancel()
    }

    /// After an unmount: searches again when the view is showing (or a search was asked for meanwhile).
    func duplicateSearchAfterUnmount() {
        guard unmountsInProgress == 0 else { return }
        let pending = duplicateRerun
        guard isShowingDuplicates || pending != nil else { return }
        duplicateRerun = nil
        startDuplicateSearch(hashing: isShowingDuplicates || pending == true)
    }

    /// Quitting: stops the search and waits for it.
    func stopDuplicateSearch() async {
        duplicateSearchStopped = true
        cancelDuplicateSearch()
        await duplicateTask?.value
    }

    private func duplicateHashProgressed(_ progress: BackfillProgress) {
        let shown: BackfillProgress? = progress.total > 0 && progress.done < progress.total ? progress : nil
        if shown != duplicateProgress { duplicateProgress = shown }
    }

    private func duplicateSearchEnded(_ snapshot: DuplicateSnapshot?, cancelled: Bool) {
        duplicateTask = nil
        duplicateProgress = nil
        if cancelled { duplicateRunsCancelled += 1 }
        if let snapshot, !cancelled { apply(snapshot) }
        if let rerun = duplicateRerun, unmountsInProgress == 0, !duplicateSearchStopped {
            duplicateRerun = nil
            startDuplicateSearch(hashing: rerun)
        } else {
            isFindingDuplicates = false
        }
    }

    private func apply(_ snapshot: DuplicateSnapshot) {
        var byFile: [Int64: [FaceRow]] = [:]
        for row in snapshot.rows.values { byFile[row.fileID, default: []].append(row) }
        for key in byFile.keys { byFile[key]?.sort { $0.faceIndex < $1.faceIndex } }
        duplicateGroups = snapshot.groups
        duplicateRows = snapshot.rows
        duplicateFiles = snapshot.files
        duplicateFacesByFile = byFile
        let kept = checkedDuplicateFiles.filter { snapshot.files[$0] != nil && !isProtectedDuplicate($0) }
        if kept != checkedDuplicateFiles { checkedDuplicateFiles = kept }
    }

    /// The groups, every face of their files and the file records.
    nonisolated static func loadDuplicateSnapshot(store: FontStore, includeSystem: Bool) throws -> DuplicateSnapshot {
        let groups = try DuplicateFinder(store: store).groups(includeSystem: includeSystem)
        let listed = Array(Set(groups.flatMap(\.faceIDs)))
        let all = try store.faceIDs(inSameFilesAs: listed)
        let rows = try store.rows(ids: Array(Set(all + listed)))
        let files = try store.fileRecords(ids: Array(Set(groups.flatMap(\.fileIDs))))
        return DuplicateSnapshot(groups: groups, rows: rows, files: files)
    }

    // MARK: Checkboxes

    /// System and user-installed fonts and fonts active outside Fontory are never removed or trashed.
    nonisolated static func isProtected(_ faces: [FaceRow]) -> Bool {
        faces.contains { $0.locationKind.isReadOnly || $0.externalActive }
    }

    /// True for a protected file, and for one whose faces are unknown.
    func isProtectedDuplicate(_ fileID: Int64) -> Bool {
        guard let faces = duplicateFacesByFile[fileID], !faces.isEmpty else { return true }
        return Self.isProtected(faces)
    }

    func setDuplicateChecked(_ fileID: Int64, _ checked: Bool) {
        guard !isProtectedDuplicate(fileID) else { return }
        if checked { checkedDuplicateFiles.insert(fileID) } else { checkedDuplicateFiles.remove(fileID) }
    }

    /// The checked files that may be removed, in id order.
    var checkedRemovableFiles: [Int64] {
        checkedDuplicateFiles.filter { !isProtectedDuplicate($0) }.sorted()
    }

    /// Total size of the checked removable files.
    var checkedDuplicateSize: Int64 {
        checkedRemovableFiles.reduce(0) { $0 + (duplicateFiles[$1]?.size ?? 0) }
    }

    /// The location ranking as Settings shows it: the stored order (existing locations), then the others.
    var effectiveLocationRank: [Int64] {
        let known = Set(listedLocations.map(\.id))
        let ranked = duplicateLocationRank.filter(known.contains)
        let rankedSet = Set(ranked)
        return ranked + listedLocations.map(\.id).filter { !rankedSet.contains($0) }
    }

    /// Settings → Duplicates: drag to reorder.
    func moveLocationRank(from source: IndexSet, to destination: Int) {
        var rank = effectiveLocationRank
        rank.move(fromOffsets: source, toOffset: destination)
        duplicateLocationRank = rank
    }

    /// Select Copies to Remove: per exact group, every file but the one `KeepPolicy` keeps (protected files never).
    /// Same-font groups are never selected. Replaces the checked set. Which files carry tags, notes or Quick Collection
    /// membership (keep rule 1b) is read from the store off the main actor.
    func selectCopiesToRemove() async {
        guard let backend else { return }
        let exactGroups = duplicateGroups.filter { $0.kind == .exact }
        let fileIDs = exactGroups.flatMap(\.fileIDs)
        guard let userData = await runBackground({ try backend.store.userDataFaceCounts(fileIDs: fileIDs) },
                                                 failureTitle: "The fonts could not be read") else { return }
        let policy = KeepPolicy(locationRank: effectiveLocationRank)
        var checked = Set<Int64>()
        for group in exactGroups {
            var rows: [Int64: FaceRow] = [:]
            for fileID in group.fileIDs {
                for row in duplicateFacesByFile[fileID] ?? [] { rows[row.id] = row }
            }
            let files = duplicateFiles.filter { group.fileIDs.contains($0.key) }
            checked.formUnion(policy.filesToRemove(in: group, rows: rows, files: files, userDataFiles: Set(userData.keys)))
        }
        checkedDuplicateFiles = checked.filter { !isProtectedDuplicate($0) }
    }

    // MARK: Removal

    /// Fresh rows of the checked files (protection, activation, URL) and their user data, read off the main actor.
    nonisolated static func removalCandidates(store: FontStore, representatives: [Int64]) throws -> [RemovalCandidate] {
        let faceIDs = try store.faceIDs(inSameFilesAs: representatives)
        let rows = try store.rows(ids: faceIDs)
        var order: [Int64] = []
        var byFile: [Int64: [FaceRow]] = [:]
        for id in faceIDs {
            guard let row = rows[id] else { continue }
            if byFile[row.fileID] == nil { order.append(row.fileID) }
            byFile[row.fileID, default: []].append(row)
        }
        let organized = try store.userDataFaceCounts(fileIDs: order)
        return try order.map { fileID in
            let faces = byFile[fileID] ?? []
            return RemovalCandidate(
                fileID: fileID, locationID: faces[0].locationID, name: faces[0].fullName, url: faces[0].fileURL,
                activeFaceIDs: faces.filter { $0.activation != .off }.map(\.id),
                isProtected: isProtected(faces), userDataFaces: try store.userDataFaceCount(fileIDs: [fileID]),
                organizedFaces: organized[fileID] ?? 0)
        }
    }

    private func candidates(for fileIDs: [Int64]) async -> [RemovalCandidate]? {
        guard let backend else { return nil }
        let representatives = fileIDs.compactMap { duplicateFacesByFile[$0]?.first?.id }
        guard !representatives.isEmpty else { return [] }
        return await runBackground({ try AppModel.removalCandidates(store: backend.store, representatives: representatives) },
                                   failureTitle: "The fonts could not be read")
    }

    /// Deactivates the Fontory-active faces of `candidates` first. Returns the files that may go and the failures.
    private func deactivate(_ candidates: [RemovalCandidate]) async -> (ok: [RemovalCandidate], failed: [TrashResult.Failure]) {
        let active = candidates.flatMap(\.activeFaceIDs)
        guard !active.isEmpty, let backend else { return (candidates, []) }
        let report = await backend.activation.set(active, to: .off)
        afterActivationChange()
        var ok: [RemovalCandidate] = []
        var failed: [TrashResult.Failure] = []
        for c in candidates {
            if let message = c.activeFaceIDs.lazy.compactMap({ report.failures[$0] ?? report.failures[-1] }).first {
                failed.append(.init(fileID: c.fileID, name: c.name, message: "It could not be deactivated: \(message)"))
            } else {
                ok.append(c)
            }
        }
        return (ok, failed)
    }

    private static let protectedMessage = "System fonts, installed fonts and fonts active outside Fontory are never removed."

    /// Remove from Library: deactivates the checked files' active faces, then removes the files from the index and
    /// excludes them, so rescans skip them. The files stay on disk. Faces with user data count in the location's
    /// "N fonts removed" notice. When faces of the files have tags, notes or Quick Collection membership, which go with
    /// them, it asks first (`confirmed` is the alert's answer); otherwise it goes ahead.
    func removeCheckedFromLibrary(confirmed: Bool = false) async {
        await removeFromLibrary(checkedRemovableFiles, confirmed: confirmed)
    }

    func removeFromLibrary(_ ids: [Int64], confirmed: Bool) async {
        guard !ids.isEmpty, let backend, !isRemovingDuplicates else { return }
        isRemovingDuplicates = true
        defer { isRemovingDuplicates = false }
        guard let plan = await candidates(for: ids) else { return }
        let organized = plan.filter { !$0.isProtected }.reduce(0) { $0 + $1.organizedFaces }
        if organized > 0 && !confirmed {
            let files = ids.count == 1 ? "1 font file" : "\(ids.count.formatted()) font files"
            alert = AlertItem(
                title: "Remove \(files) from the library?",
                message: "\(organized == 1 ? "1 font" : "\(organized.formatted()) fonts") with tags or notes will lose them "
                    + "(tags, notes and Quick Collection membership). The files stay on disk, and rescans skip them.",
                actionTitle: "Remove", isDestructive: true,
                action: { [weak self] in Task { await self?.removeFromLibrary(ids, confirmed: true) } })
            return
        }
        var failures = plan.filter(\.isProtected).map { TrashResult.Failure(fileID: $0.fileID, name: $0.name, message: Self.protectedMessage) }
        let (ok, failed) = await deactivate(plan.filter { !$0.isProtected })
        failures += failed
        let removed = ok.map(\.fileID)
        if !removed.isEmpty {
            guard await runBackground({ try backend.store.removeFromLibrary(fileIDs: removed) },
                                      failureTitle: "The fonts could not be removed from the library") != nil else { return }
            noteRemovals(ok)
            checkedDuplicateFiles.subtract(removed)
        }
        if !failures.isEmpty { presentFailures(failures, title: "Some fonts were not removed from the library") }
        await afterDuplicateRemoval()
    }

    /// Move to Trash…: asks first, with the file count and total size.
    func moveCheckedToTrash() {
        let ids = checkedRemovableFiles
        guard !ids.isEmpty else { return }
        let size = ByteCountFormatter.string(fromByteCount: checkedDuplicateSize, countStyle: .file)
        let exact = Set(duplicateGroups.filter { $0.kind == .exact }.flatMap(\.fileIDs))
        let sameFont = ids.filter { !exact.contains($0) }.count
        var message = "\(ids.count.formatted()) file\(ids.count == 1 ? "" : "s"), \(size) in total. "
            + "They can be put back from the Trash. Fonts active in Fontory are deactivated first; their tags and notes are lost."
        if sameFont > 0 {
            message += "\n\n\(sameFont.formatted()) of them \(sameFont == 1 ? "is not an exact copy" : "are not exact copies") (same font, different file)."
        }
        alert = AlertItem(title: "Move \(ids.count == 1 ? "1 font file" : "\(ids.count.formatted()) font files") to the Trash?",
                          message: message, actionTitle: "Move to Trash", isDestructive: true,
                          action: { [weak self] in Task { await self?.trashFiles(ids) } })
    }

    /// Moves the files to the Trash one by one (`NSWorkspace.recycle`) after deactivating their active faces. Only
    /// the files really moved leave the index (deleted, not excluded); the others are listed per file in an alert.
    @discardableResult
    func trashFiles(_ ids: [Int64]) async -> TrashResult {
        var result = TrashResult()
        defer { lastTrashResult = result }
        guard !ids.isEmpty, let backend, !isRemovingDuplicates else { return result }
        isRemovingDuplicates = true
        defer { isRemovingDuplicates = false }
        guard let plan = await candidates(for: ids) else { return result }
        result.failures = plan.filter(\.isProtected).map { .init(fileID: $0.fileID, name: $0.name, message: Self.protectedMessage) }
        // Reachability first: an offline or missing file is reported and left as it is (not deactivated).
        var reachable: [RemovalCandidate] = []
        for c in plan where !c.isProtected {
            guard let url = c.url else {
                result.failures.append(.init(fileID: c.fileID, name: c.name, message: "Its location is offline."))
                continue
            }
            guard await Self.fileExists(url) else {
                result.failures.append(.init(fileID: c.fileID, name: "\(c.name) (\(url.lastPathComponent))", message: "The file is missing."))
                continue
            }
            reachable.append(c)
        }
        let (ok, failed) = await deactivate(reachable)
        result.failures += failed
        var recycled: [RemovalCandidate] = []
        for c in ok {
            guard let url = c.url else { continue }
            let name = "\(c.name) (\(url.lastPathComponent))"
            // Parsed fonts may hold the file open.
            previewRenderer.forgetFonts(under: url)
            let (trashed, error) = await recycleFile(url)
            if let trashed, !(await Self.fileExists(url)) {
                recycled.append(c)
                result.trashedURLs.append(trashed)
            } else {
                let message = error ?? "The file is still there."
                result.failures.append(.init(fileID: c.fileID, name: name,
                                             message: c.activeFaceIDs.isEmpty ? message : message + " (it was deactivated)"))
            }
        }
        let gone = recycled.map(\.fileID)
        if !gone.isEmpty {
            // Gone from disk: deleted from the index, no exclusion. A row the watcher's rescan already deleted (and
            // counted in its own notice) is not counted again.
            if let deleted = await runBackground({ try backend.store.deleteFiles(gone) },
                                                 failureTitle: "The trashed fonts could not be removed from the library") {
                result.recycled = gone
                noteRemovals(recycled.filter { deleted.contains($0.fileID) })
                checkedDuplicateFiles.subtract(gone)
            }
        }
        if !result.failures.isEmpty { presentFailures(result.failures, title: "Some files were not moved to the Trash") }
        await afterDuplicateRemoval()
        return result
    }

    private nonisolated static func fileExists(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) { FileManager.default.fileExists(atPath: url.path) }.value
    }

    /// The default `recycleFile`: `NSWorkspace.recycle` of one file, giving its URL in the Trash or the error's description.
    /// Never reached by the smoke run, which replaces `recycleFile` (it would change the user's Trash).
    static func workspaceRecycle(_ url: URL) async -> (trashedURL: URL?, error: String?) {
        #if DEBUG
        precondition(!CommandLine.arguments.contains(OrganizationSmoke.argument),
                     "the smoke run must not recycle into the user's Trash")
        #endif
        return await withCheckedContinuation { (continuation: CheckedContinuation<(URL?, String?), Never>) in
            NSWorkspace.shared.recycle([url]) { moved, error in
                if let trashed = moved.values.first {
                    continuation.resume(returning: (trashed, nil))
                } else {
                    continuation.resume(returning: (nil, error?.localizedDescription ?? "The file could not be moved to the Trash."))
                }
            }
        }
    }

    private func noteRemovals(_ removed: [RemovalCandidate]) {
        for c in removed where c.userDataFaces > 0 { removalNotices[c.locationID, default: 0] += c.userDataFaces }
    }

    private func presentFailures(_ failures: [TrashResult.Failure], title: String) {
        var lines = failures.prefix(15).map { "• \($0.name): \($0.message)" }
        if failures.count > 15 { lines.append("…and \(failures.count - 15) more") }
        alert = AlertItem(title: title, message: lines.joined(separator: "\n"))
    }

    private func afterDuplicateRemoval() async {
        invalidateRows()
        refreshCounts()
        scheduleRefresh()
        tagAssignmentVersion += 1
        await loadQuickCollection()
        await loadExcludedFiles()
        startDuplicateSearch(hashing: false)
    }

    // MARK: Excluded files

    func loadExcludedFiles() async {
        guard let backend else { return }
        guard let list = await runBackground({ try backend.store.excludedFiles() }) else { return }
        let files = list.map { ExcludedFile(locationID: $0.locationID, relativePath: $0.relativePath) }
        if files != excludedFiles { excludedFiles = files }
    }

    /// Include Again: deletes the exclusion and rescans the location (a file set imports the file again).
    func includeAgain(_ file: ExcludedFile) async {
        guard let backend else { return }
        guard await runBackground({ try backend.store.includeAgain(locationID: file.locationID, relativePath: file.relativePath) },
                                  failureTitle: "The file could not be included again") != nil else { return }
        await loadExcludedFiles()
        guard let loc = location(file.locationID), loc.online else { return }
        if loc.kind == .fileSet {
            let url = URL(fileURLWithPath: loc.lastKnownPath).appendingPathComponent(file.relativePath)
            _ = await runBackground({ try backend.importFiles([url], into: loc) }, failureTitle: "The file could not be imported")
            await scanFinished()
        } else {
            rescan(loc.id)
        }
    }

    #if DEBUG
    /// Smoke hook: waits until no search runs and none is pending (one waiting for the face backfill included).
    func waitForDuplicateSearchForSmoke() async {
        while true {
            if let task = duplicateTask {
                await task.value
            } else if isWaitingForFaceBackfill, let backfill = faceBackfillTask {
                await backfill.value
                if isWaitingForFaceBackfill && faceBackfillTask == backfill { return }  // a stand-in task (smoke)
            } else {
                return
            }
        }
    }
    #endif
}
