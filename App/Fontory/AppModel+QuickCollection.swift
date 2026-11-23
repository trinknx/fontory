import AppKit
import FontoryCore

/// Quick Collection actions (⌘J, the context menu, the Font menu, the sidebar row) and the style classification
/// backfill. Store calls run off the main actor.
extension AppModel {
    // MARK: Quick Collection

    /// Reads the collection from the store (off the main actor). A read overtaken by a change made meanwhile is
    /// dropped; that change reads again when written.
    func loadQuickCollection() async {
        guard let backend else { return }
        let generation = quickCollectionGeneration
        guard let ids = await runBackground({ try backend.store.quickCollectionFaceIDs() }),
              generation == quickCollectionGeneration, ids != quickCollectionIDs else { return }
        quickCollectionIDs = ids
    }

    /// Every face of `ids` is in the collection (false for none).
    func isInQuickCollection(_ ids: [Int64]) -> Bool {
        !ids.isEmpty && ids.allSatisfy(quickCollectionIDs.contains)
    }

    /// The menu title for `ids`: Remove when all of them are in the collection, else Add.
    func quickCollectionTitle(for ids: [Int64]) -> String {
        isInQuickCollection(ids) ? "Remove from Quick Collection" : "Add to Quick Collection"
    }

    /// The faces ⌘J acts on (those of `tagPanelTargets`), unordered: cheap enough for the Font menu's title.
    var quickCollectionTargetSet: Set<Int64> {
        detail != nil && !detailSelection.isEmpty ? detailSelection : selection
    }

    /// The Font menu's title for the current targets.
    var quickCollectionMenuTitle: String {
        let targets = quickCollectionTargetSet
        return !targets.isEmpty && targets.isSubset(of: quickCollectionIDs) ? "Remove from Quick Collection" : "Add to Quick Collection"
    }

    /// ⌘J and the menus: when every face of `ids` (default: the selection, as for ⌘T) is in the collection they
    /// all leave it, else they all join it. Decided from the in-memory set, which changes at once, so quick repeats
    /// alternate.
    func toggleQuickCollection(_ ids: [Int64]? = nil) async {
        let targets = ids ?? tagPanelTargets
        guard !targets.isEmpty else { return }
        await setQuickCollection(targets, included: !isInQuickCollection(targets))
    }

    func setQuickCollection(_ ids: [Int64], included: Bool) async {
        guard !ids.isEmpty else { return }
        if included { quickCollectionIDs.formUnion(ids) } else { quickCollectionIDs.subtract(ids) }
        await quickCollectionWrite(included ? "The fonts could not be added to the Quick Collection"
                                            : "The fonts could not be removed from the Quick Collection") {
            try $0.setQuickCollection(ids, included: included, at: Date())
        }
    }

    /// Clear: empties the collection.
    func clearQuickCollection() async {
        quickCollectionIDs = []
        await quickCollectionWrite("The Quick Collection could not be cleared") { try $0.clearQuickCollection() }
    }

    /// Clear…: asks first when the collection has fonts.
    func confirmClearQuickCollection() {
        let count = quickCollectionIDs.count
        guard count > 0 else { return }
        var item = AlertItem(title: "Clear the Quick Collection?",
                             message: "\(count.formatted()) font\(count == 1 ? " leaves" : "s leave") the Quick Collection. The fonts themselves stay in the library.")
        item.actionTitle = "Clear"
        item.isDestructive = true
        item.action = { [weak self] in Task { await self?.clearQuickCollection() } }
        alert = item
    }

    /// Save as Tag…: a new top-level tag named `name` with the faces of the collection. A taken name shows the
    /// usual tag alert and creates nothing; so does an empty collection. Returns the tag's id.
    @discardableResult
    func saveQuickCollectionAsTag(name: String) async -> Int64? {
        await quickCollectionWriteChain?.value
        guard let backend,
              let ids = await runBackground({ try backend.store.quickCollectionFaceIDs() }, failureTitle: "The Quick Collection could not be read"),
              !ids.isEmpty,
              let id = await createTag(name: name, parentID: nil) else { return nil }
        await assignNewTag(id, toFaces: ids.sorted())
        return id
    }

    /// Runs Quick Collection writes in order, then confirms the set from the store and refreshes the counts (and the
    /// browser when it shows the collection).
    private func quickCollectionWrite(_ title: String, _ work: @escaping @Sendable (FontStore) throws -> Void) async {
        quickCollectionGeneration += 1
        quickCollectionWritesPending += 1
        defer { quickCollectionWritesPending -= 1 }
        let previous = quickCollectionWriteChain
        let write = Task { [weak self] in
            await previous?.value
            _ = await self?.tagWrite(title, work)
        }
        quickCollectionWriteChain = write
        await write.value
        guard quickCollectionWriteChain == write else { return }  // a newer write follows and reloads
        quickCollectionWriteChain = nil
        await loadQuickCollection()
        await reloadOrganization()
        if query.scope == .quickCollection { scheduleRefresh() }
    }

    // MARK: Face backfill

    /// Fills in the style class and metadata (coverage, features, figures) of faces indexed under older versions, in
    /// the background. Runs after launch, every
    /// mount and every scan. Never two at once: a start while one runs makes it run once more when it ends.
    func startFaceBackfill() {
        guard let backend, !faceBackfillStopped else { return }
        // During an unmount the handler starts it afterwards.
        if unmountsInProgress > 0 { return }
        if faceBackfillTask != nil {
            faceBackfillRerun = true
            return
        }
        faceBackfillRerun = false
        faceBackfillRuns += 1
        faceBackfillRunning += 1
        faceBackfillMaxRunning = max(faceBackfillMaxRunning, faceBackfillRunning)
        let store = backend.store
        faceBackfillTask = Task { [weak self] in
            // Each batch reads its files in a detached utility task (FaceBackfill), never on the main actor;
            // this loop only publishes progress, and ends only when no work of the run is left in flight.
            for await progress in FaceBackfill(store: store).run() {
                self?.faceBackfillProgressed(progress)
            }
            self?.faceBackfillEnded()
        }
    }

    /// Stops the running backfill (between two faces) without a rerun; on unmount, before the volume's
    /// locations are marked offline. The caller starts it again afterwards.
    func cancelFaceBackfill() {
        faceBackfillRerun = false
        faceBackfillTask?.cancel()
    }

    /// Quitting: stops the backfill and waits for it.
    func stopFaceBackfill() async {
        faceBackfillStopped = true
        cancelFaceBackfill()
        await faceBackfillTask?.value
    }

    private func faceBackfillProgressed(_ progress: BackfillProgress) {
        let shown: BackfillProgress? = progress.total > 0 && progress.done < progress.total ? progress : nil
        if shown != faceBackfillProgress { faceBackfillProgress = shown }
        if progress.done > 0 { scheduleStyleCountsReload() }
    }

    private func faceBackfillEnded() {
        faceBackfillTask = nil
        faceBackfillRunning -= 1
        faceBackfillProgress = nil
        if faceBackfillRerun { startFaceBackfill() }
    }

    static let styleCountsInterval: Duration = .seconds(1)

    /// The Style counts (and a view depending on styles) follow the backfill, at most once a second; the last
    /// batch's change is reloaded too.
    private func scheduleStyleCountsReload() {
        guard styleCountsReloadTask == nil else { return }
        let clock = ContinuousClock()
        let wait = lastStyleCountsReload.map { max(.zero, Self.styleCountsInterval - (clock.now - $0)) } ?? .zero
        styleCountsReloadTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self else { return }
            self.lastStyleCountsReload = clock.now
            self.styleCountsReloadTask = nil
            // Only what the backfill can change: Style counts and smart tags testing the style.
            await self.reloadOrganization(.styles)
            if self.viewDependsOnStyles { self.scheduleRefresh() }
        }
    }

    #if DEBUG
    /// Smoke hook: waits for the Quick Collection writes in flight.
    func waitForQuickCollectionWritesForSmoke() async {
        while quickCollectionWritesPending > 0 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Smoke hook: waits until no backfill runs and none is pending.
    func waitForFaceBackfillForSmoke() async {
        while let task = faceBackfillTask { await task.value }
        await styleCountsReloadTask?.value
    }
    #endif
}
