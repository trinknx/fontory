import AppKit
import CoreText
import FontoryCore
import Observation
import os

enum ViewMode: String, CaseIterable, Sendable {
    case grid, list
}

enum PreviewAlignment: String, CaseIterable, Sendable {
    case left, center, right

    var ctAlignment: CTTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }

    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

struct PreviewSettings: Equatable {
    var text = "The quick brown fox jumps over the lazy dog"
    /// nil: the size follows the zoom level.
    var pointSizeOverride: Double?
    var tracking: Double = 0
    var foreground = CGColor(gray: 0, alpha: 1)
    var background = CGColor(gray: 1, alpha: 1)
    var alignment: PreviewAlignment = .left
    var smoothing = true
    var autoSize = false
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var actionTitle: String?
    var isDestructive = false
    var action: (@MainActor () -> Void)?
}

enum SettingsKey {
    static let restoreOnLaunch = "restoreOnLaunch"
    static let keepRunningInMenuBar = "keepRunningInMenuBar"
    static let showSystemFonts = "showSystemFonts"

    static func register() {
        UserDefaults.standard.register(defaults: [
            restoreOnLaunch: true, keepRunningInMenuBar: true, showSystemFonts: true,
            "zoom.grid": 0.25, "zoom.list": 0.25,
        ])
    }
}

/// Main-actor façade over the core services. All database, scanning and activation work runs off the main
/// actor (detached tasks or the core actors); this type only publishes results.
@Observable @MainActor
final class AppModel {
    private static let log = Logger(subsystem: "local.fontory.app", category: "model")
    private static let refreshDelay: Duration = .milliseconds(80)
    private static let folderEventDelay: Duration = .seconds(5)

    // MARK: Browsing state

    var query: LibraryQuery {
        didSet {
            guard query != oldValue else { return }
            if query.includeSystem != oldValue.includeSystem {
                UserDefaults.standard.set(query.includeSystem, forKey: SettingsKey.showSystemFonts)
                refreshCounts()
            }
            scheduleRefresh()
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { updateSearch() } } }
    var searchScope: Set<SearchText.Field> = Set(SearchText.Field.allCases) { didSet { if searchScope != oldValue { updateSearch() } } }
    var viewMode: ViewMode = .grid {
        didSet {
            guard viewMode != oldValue else { return }
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
            if viewMode == .list { scheduleRefresh(delay: .zero) }
        }
    }
    var zoom: [ViewMode: Double] {
        didSet { for mode in ViewMode.allCases { UserDefaults.standard.set(zoom[mode], forKey: "zoom.\(mode.rawValue)") } }
    }
    var preview = PreviewSettings()
    private(set) var presets: [Preset] = []
    /// Drives the "save preset" name prompt.
    var isNamingPreset = false

    // MARK: Results

    /// Matching faces in sort order. Refreshed off-main, debounced 80 ms after any query change.
    private(set) var faceIDs: [Int64] = []
    /// Matching faces grouped by family. Computed only while the list view is showing.
    private(set) var families: [FamilyGroup] = []
    private(set) var counts = LibraryCounts()
    /// Bumped whenever cached rows change (activation, rescans), so views reading `row(_:)` update.
    private(set) var rowsVersion = 0
    var selection: Set<Int64> = []

    // MARK: Locations

    private(set) var locations: [LocationRecord] = []
    private(set) var scanProgress: [Int64: ScanProgress] = [:]
    var alert: AlertItem?
    private(set) var isReady = false

    // MARK: Private

    @ObservationIgnored private var backend: LibraryBackend?
    @ObservationIgnored private var presetStore: PresetStore?
    @ObservationIgnored private let rowCache = LRUCache<Int64, FaceRow>(limit: 4000)
    @ObservationIgnored private var indexByID: [Int64: Int] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var scanTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [Int64: FolderWatcher] = [:]
    @ObservationIgnored private var folderEventTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        SettingsKey.register()
        let defaults = UserDefaults.standard
        query = LibraryQuery(includeSystem: defaults.bool(forKey: SettingsKey.showSystemFonts))
        zoom = [.grid: defaults.double(forKey: "zoom.grid"), .list: defaults.double(forKey: "zoom.list")]
        viewMode = defaults.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:)) ?? .grid
    }

    // MARK: Startup

    func start() async {
        guard !started else { return }
        started = true
        // 1. Open the database.
        do {
            let (backend, presetStore) = try await Task.detached(priority: .userInitiated) {
                let dir = try LibraryBackend.dataDirectory()
                return (try LibraryBackend(databaseURL: dir.appendingPathComponent("library.sqlite")),
                        PresetStore(url: dir.appendingPathComponent("presets.json")))
            }.value
            self.backend = backend
            self.presetStore = presetStore
            presets = await Task.detached { presetStore.load() }.value
        } catch {
            alert = AlertItem(title: "The font library could not be opened", message: error.localizedDescription)
            return
        }
        guard let backend else { return }

        // The existing index is browsable right away; everything below runs behind it.
        await reloadLocations()
        refreshCounts()
        await refreshNow()
        isReady = true

        // 4. Online/offline must be known before anything builds file URLs from last_known_path.
        await runBackground { _ = try backend.refreshOnlineState() }
        // 6. Subscribe to mounts early so none are missed while restoring.
        startVolumeMonitor()
        // 2. System folders are indexed once.
        let newSystem = await runBackground { try backend.ensureSystemLocations() } ?? []
        await reloadLocations()
        // 3. Restore activated fonts.
        if UserDefaults.standard.bool(forKey: SettingsKey.restoreOnLaunch) {
            let report = await backend.activation.restoreOnLaunch()
            present(report, state: .on, context: "Restoring activated fonts")
            invalidateRows()
        }
        // 5. Incremental background rescan of the online user locations (and the system folders added just now).
        for loc in locations where loc.online && (loc.kind != .system || newSystem.contains(loc.id)) {
            rescan(loc.id)
        }
        // 7. Watch online folders.
        updateWatchers()
        refreshCounts()
        scheduleRefresh()
    }

    func prepareForQuit() async {
        await backend?.activation.prepareForQuit()
    }

    // MARK: Query

    private func updateSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.search = trimmed.isEmpty ? nil : SearchText(trimmed, scope: searchScope)
    }

    /// Choosing the active sort again inverts the order; random always reshuffles.
    func chooseSort(_ sort: LibraryQuery.Sort) {
        switch (sort, query.sort) {
        case (.random, _):
            query.sort = .random(seed: UInt64.random(in: 1...UInt64(UInt32.max)))
        case let (new, current) where new == current:
            query.ascending.toggle()
        default:
            query.sort = sort
            query.ascending = true
        }
    }

    func scheduleRefresh(delay: Duration = AppModel.refreshDelay) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refreshNow()
        }
    }

    private func refreshNow() async {
        guard let backend else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let query = query
        let wantFamilies = viewMode == .list
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([Int64], [Int64: Int], [FamilyGroup]), Error> in
            Result {
                let ids = try backend.store.faceIDs(for: query)
                var index: [Int64: Int] = [:]
                index.reserveCapacity(ids.count)
                for (i, id) in ids.enumerated() { index[id] = i }
                let families = wantFamilies ? try backend.store.families(for: query) : []
                return (ids, index, families)
            }
        }.value
        guard generation == refreshGeneration else { return }
        switch result {
        case .success(let (ids, index, families)):
            rowCache.removeAll()
            indexByID = index
            if ids != faceIDs { faceIDs = ids }
            if wantFamilies { self.families = families }
            let kept = selection.filter { index[$0] != nil }
            if kept.count != selection.count { selection = kept }
            rowsVersion &+= 1
        case .failure(let error):
            Self.log.error("query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshCounts() {
        guard let backend else { return }
        let includeSystem = query.includeSystem
        countsTask?.cancel()
        countsTask = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) { try? backend.counts(includeSystem: includeSystem) }.value
            guard !Task.isCancelled, let counts else { return }
            self?.counts = counts
        }
    }

    /// The row for a face, from a small cache filled in batches around the requested position.
    func row(_ id: Int64) -> FaceRow? {
        _ = rowsVersion
        if let row = rowCache[id] { return row }
        guard let backend else { return nil }
        var batch = [id]
        if let i = indexByID[id] {
            let lo = max(0, i - 100), hi = min(faceIDs.count, i + 200)
            batch = Array(faceIDs[lo..<hi])
        }
        guard let rows = try? backend.store.rows(ids: batch) else { return nil }
        for (key, value) in rows { rowCache[key] = value }
        return rows[id]
    }

    private func invalidateRows() {
        rowCache.removeAll()
        rowsVersion &+= 1
    }

    // MARK: Locations

    var userLocations: [LocationRecord] { locations.filter { $0.kind != .system } }
    var systemLocations: [LocationRecord] { locations.filter { $0.kind == .system } }

    func location(_ id: Int64) -> LocationRecord? { locations.first { $0.id == id } }

    /// System fonts are read-only: their activation cannot be changed.
    func isActivationLocked(_ row: FaceRow) -> Bool {
        location(row.locationID)?.kind == .system
    }

    func reloadLocations() async {
        guard let backend else { return }
        if let locs = await runBackground({ try backend.store.locations() }) { locations = locs }
    }

    func addLocation(url: URL) async {
        guard let backend else { return }
        guard let loc = await runBackground({ try backend.addFolder(url) }, failureTitle: "The folder could not be added") else { return }
        await reloadLocations()
        query.scope = .location(id: loc.id, subfolder: nil)
        rescan(loc.id)
        updateWatchers()
    }

    /// Indexes individual files: one `.fileSet` location per parent folder, or a rescan of the folder location
    /// that already contains them.
    func addFiles(urls: [URL]) async {
        guard let backend else { return }
        let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent().standardizedFileURL }
        for (folder, files) in byFolder {
            let covering = await runBackground { try backend.coveringLocation(of: folder) }
            if let covering = covering ?? nil {
                rescan(covering.id)
                continue
            }
            guard let loc = await runBackground({ try backend.fileSetLocation(for: folder) },
                                                failureTitle: "The fonts could not be added") else { continue }
            await reloadLocations()
            scanProgress[loc.id] = ScanProgress(locationID: loc.id, phase: .parsing, total: files.count)
            let progress = await runBackground { try backend.importFiles(files, into: loc) }
            scanProgress[loc.id] = progress ?? ScanProgress(locationID: loc.id, phase: .aborted(reason: "import failed"))
        }
        query.scope = .recentImport
        await scanFinished()
    }

    /// Imports whatever was dropped: folders become locations, files are added individually.
    func importDropped(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !folders.contains($0) }
        Task {
            for folder in folders { await addLocation(url: folder) }
            if !files.isEmpty { await addFiles(urls: files) }
        }
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose font folders or font files. Fonts stay where they are."
        guard panel.runModal() == .OK else { return }
        importDropped(panel.urls)
    }

    func rescan(_ id: Int64) {
        guard let backend, let loc = location(id) else { return }
        guard loc.online else {
            scanProgress[id] = ScanProgress(locationID: id, phase: .aborted(reason: "The location is offline."))
            return
        }
        scanTasks[id]?.cancel()
        if loc.kind == .fileSet {
            scanProgress[id] = ScanProgress(locationID: id, phase: .parsing)
            scanTasks[id] = Task { [weak self] in
                let progress = await Task.detached(priority: .utility) { try? backend.refreshFileSet(loc) }.value
                guard let self, !Task.isCancelled else { return }
                self.scanProgress[id] = progress ?? ScanProgress(locationID: id, phase: .aborted(reason: "rescan failed"))
                await self.scanFinished()
            }
            return
        }
        scanTasks[id] = Task { [weak self] in
            let stream = await backend.scanner.scan(locationID: id)
            var lastRefresh = ContinuousClock.now
            for await progress in stream {
                guard let self else { return }
                self.scanProgress[id] = progress
                // Let the counts and the browser grow while a large import runs.
                if ContinuousClock.now - lastRefresh > .seconds(1) {
                    lastRefresh = .now
                    self.refreshCounts()
                    self.scheduleRefresh()
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.scanFinished()
        }
    }

    private func scanFinished() async {
        await reloadLocations()
        refreshCounts()
        scheduleRefresh()
    }

    func relink(_ id: Int64, to url: URL) async {
        guard let backend else { return }
        await backend.scanner.cancel(locationID: id)
        guard await runBackground({ try backend.relink(id, to: url) }, failureTitle: "The location could not be relinked") != nil else { return }
        await reloadLocations()
        let report = await backend.activation.volumeMounted(locationIDs: [id])
        present(report, state: .on, context: "Re-activating fonts")
        rescan(id)
        updateWatchers()
        invalidateRows()
    }

    func removeLocation(_ id: Int64) {
        guard let backend else { return }
        scanTasks[id]?.cancel()
        scanTasks[id] = nil
        watchers.removeValue(forKey: id)?.stop()
        scanProgress[id] = nil
        Task {
            await backend.scanner.cancel(locationID: id)
            await backend.activation.volumeUnmounted(locationIDs: [id])
            _ = await runBackground({ try backend.store.deleteLocation(id) }, failureTitle: "The location could not be removed")
            if case .location(let loc, _) = query.scope, loc == id { query.scope = .all }
            await scanFinished()
        }
    }

    func confirmRemoveLocation(_ id: Int64) {
        guard let loc = location(id) else { return }
        alert = AlertItem(
            title: "Remove “\(loc.displayName)” from the library?",
            message: "Its fonts are deactivated and forgotten by Fontory. The files on disk are not touched.",
            actionTitle: "Remove", isDestructive: true, action: { [weak self] in self?.removeLocation(id) })
    }

    func subfolders(of locationID: Int64, parent: String?) async -> [String] {
        guard let backend else { return [] }
        return await runBackground { try backend.store.subfolders(locationID: locationID, parent: parent) } ?? []
    }

    func revealLocation(_ id: Int64) {
        guard let loc = location(id), loc.online else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: loc.lastKnownPath)])
    }

    // MARK: Folder watching

    private func updateWatchers() {
        let wanted = Dictionary(locations.filter { $0.kind == .folder && $0.online }.map { ($0.id, $0.lastKnownPath) },
                                uniquingKeysWith: { a, _ in a })
        for (id, watcher) in watchers where wanted[id] != watcher.path {
            watcher.stop()
            watchers[id] = nil
        }
        for (id, path) in wanted where watchers[id] == nil {
            watchers[id] = FolderWatcher(path: path) { [weak self] in self?.folderChanged(id) }
        }
    }

    private func folderChanged(_ id: Int64) {
        folderEventTasks[id]?.cancel()
        folderEventTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: AppModel.folderEventDelay)
            guard !Task.isCancelled else { return }
            self?.folderEventTasks[id] = nil
            self?.rescan(id)
        }
    }

    // MARK: Volumes

    private func startVolumeMonitor() {
        monitorTask = Task { [weak self] in
            for await event in VolumeMonitor().events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: VolumeEvent) async {
        guard let backend else { return }
        switch event {
        case .mounted(_, let uuid):
            let ids: [Int64]
            if let uuid {
                ids = await runBackground { try backend.markMounted(volumeUUID: uuid) } ?? []
            } else {
                ids = await runBackground { try backend.refreshOnlineState() } ?? []
            }
            guard !ids.isEmpty else { return }
            // last_known_path is current now, so volumeMounted builds the right URLs.
            await reloadLocations()
            let report = await backend.activation.volumeMounted(locationIDs: ids)
            present(report, state: .on, context: "Re-activating fonts on the mounted volume")
            for id in ids where location(id)?.kind != .system { rescan(id) }
            updateWatchers()
            invalidateRows()
            refreshCounts()
            scheduleRefresh()

        case .unmounted(let volumeURL):
            // Sent twice per unmount (will + did): the first event marks the locations offline locally,
            // so the second finds nothing to do.
            let root = volumeURL.standardizedFileURL.path
            let ids = locations.filter { $0.online && ($0.lastKnownPath == root || $0.lastKnownPath.hasPrefix(root + "/")) }.map(\.id)
            guard !ids.isEmpty else { return }
            for i in locations.indices where ids.contains(locations[i].id) { locations[i].online = false }
            for id in ids {
                scanTasks.removeValue(forKey: id)?.cancel()
                folderEventTasks.removeValue(forKey: id)?.cancel()
                watchers.removeValue(forKey: id)?.stop()
                await backend.scanner.cancel(locationID: id)
            }
            await backend.activation.volumeUnmounted(locationIDs: ids)
            _ = await runBackground { try backend.markOffline(ids) }
            await reloadLocations()
            invalidateRows()
            refreshCounts()
            scheduleRefresh()
        }
    }

    // MARK: Activation

    func setActivation(_ ids: [Int64], _ state: ActivationState, force: Bool = false) async {
        guard let backend else { return }
        let allowed = ids.filter { id in row(id).map { !isActivationLocked($0) } ?? false }
        guard !allowed.isEmpty else { return }
        let report = await backend.activation.set(allowed, to: state, force: force)
        afterActivationChange()
        present(report, state: state, context: nil)
    }

    func clearTemporary() async {
        guard let backend else { return }
        let report = await backend.activation.clearTemporary()
        afterActivationChange()
        present(report, state: .off, context: "Clearing temporary fonts")
    }

    private func afterActivationChange() {
        invalidateRows()
        refreshCounts()
        switch query.scope {
        case .activated, .temporary, .deactivated: scheduleRefresh()
        default: if query.sort == .lastActivated { scheduleRefresh() }
        }
    }

    private func displayName(_ id: Int64) -> String {
        row(id)?.fullName ?? "Font #\(id)"
    }

    /// Turns an activation report into one alert: conflicts (with "Activate Anyway") and failures.
    private func present(_ report: ActivationReport, state: ActivationState, context: String?) {
        guard !report.conflicts.isEmpty || !report.failures.isEmpty else { return }
        var lines: [String] = []
        if let general = report.failures[-1] { lines.append("Error: \(general)") }
        let failures = report.failures.filter { $0.key != -1 }.sorted { $0.key < $1.key }
        if !failures.isEmpty {
            lines.append("\(failures.count) font\(failures.count == 1 ? "" : "s") failed:")
            lines += failures.prefix(15).map { "• \(displayName($0.key)): \($0.value)" }
            if failures.count > 15 { lines.append("…and \(failures.count - 15) more") }
        }
        let conflicts = report.conflicts.sorted { $0.key < $1.key }
        if !conflicts.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("\(conflicts.count) font\(conflicts.count == 1 ? " has" : "s have") the same PostScript name as a font already installed:")
            lines += conflicts.prefix(15).map { "• \($0.value)" }
            if conflicts.count > 15 { lines.append("…and \(conflicts.count - 15) more") }
        }
        let title = context.map { "\($0): some fonts need attention" }
            ?? (conflicts.isEmpty ? "Some fonts could not be changed" : "Some fonts conflict with installed fonts")
        var item = AlertItem(title: title, message: lines.joined(separator: "\n"))
        if !conflicts.isEmpty {
            let ids = conflicts.map(\.key)
            item.actionTitle = "Activate Anyway"
            item.action = { [weak self] in
                Task { await self?.setActivation(ids, state, force: true) }
            }
        }
        alert = item
    }

    // MARK: Actions on faces

    func revealInFinder(_ ids: [Int64]) {
        let urls = ids.compactMap { row($0)?.fileURL }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(Set(urls)))
    }

    func copyDetails(_ ids: [Int64]) {
        let text = ids.compactMap(row).map { r in
            [r.postScriptName, r.family, r.style, r.version ?? "", r.fileURL?.path ?? "(offline)"].joined(separator: "\t")
        }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets = PresetStore.upserting(Preset(name: trimmed, text: preview.text), into: presets)
        persistPresets()
    }

    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.name == preset.name }
        persistPresets()
    }

    private func persistPresets() {
        guard let presetStore else { return }
        let presets = presets
        Task {
            await runBackground({ try presetStore.save(presets) }, failureTitle: "Presets could not be saved")
        }
    }

    // MARK: Helpers

    /// Runs `work` off the main actor. On error, logs it and (with a title) shows an alert; returns nil.
    @discardableResult
    private func runBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T, failureTitle: String? = nil) async -> T? {
        let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            Self.log.error("\(failureTitle ?? "background work", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if let failureTitle { alert = AlertItem(title: failureTitle, message: error.localizedDescription) }
            return nil
        }
    }
}
