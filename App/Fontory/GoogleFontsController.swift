import Foundation
import FontoryCore
import os

enum GooglePhase: Equatable {
    case off, idle, checking, downloading(done: Int, total: Int), paused, offline, error(String)
}

/// Google Fonts download and sync: consent, the daily catalogue check, downloads into the Google Fonts location
/// (`LocationKind.googleFonts`), pause/resume, offline volumes and folder changes. Downloaded fonts are indexed by
/// rescans of that location and are never activated here.
@MainActor @Observable
final class GoogleFontsController {
    private static let log = Logger(subsystem: "local.fontory.app", category: "google")
    static let unreachableMessage = "Couldn't reach Google Fonts"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The location is rescanned after this many completed families, and at the end of a run.
    static let rescanEvery = 25

    var phase: GooglePhase
    /// From the last `loadEstimate()`: the catalogue's family count and total size (nil when no family has a size).
    var estimatedBytes: Int?
    var estimatedFamilies: Int?
    /// Families whose last download failed (retried by `resume()`).
    private(set) var failedFamilies = 0
    private(set) var isEnabled: Bool
    private(set) var isPaused: Bool
    private(set) var lastCheck: Date?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let transport: GoogleTransport
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let minimumFamilies: Int
    @ObservationIgnored private let backoff: [Duration]
    /// The running download, and the last stopped one (a new run waits for it, so two never share the folder).
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var stoppedRun: Task<Void, Never>?
    /// Bumped on every start and stop: a run that ended after being replaced or stopped leaves `phase` alone.
    @ObservationIgnored private var runGeneration = 0
    /// A catalogue check succeeded while a run was going: run again when it finishes (it listed families before).
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var isChecking = false
    /// The last progress read, shown while the next run reads it again.
    @ObservationIgnored private var lastProgress = (done: 0, total: 0)

    /// `backoff` is the downloader's retry waits (the smoke run passes none).
    init(model: AppModel, transport: GoogleTransport, defaults: UserDefaults,
         minimumFamilies: Int = GoogleCatalog.minimumFamilies,
         backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]) {
        self.model = model
        self.transport = transport
        self.defaults = defaults
        self.minimumFamilies = minimumFamilies
        self.backoff = backoff
        let enabled = defaults.bool(forKey: SettingsKey.googleFontsEnabled)
        let paused = defaults.bool(forKey: SettingsKey.googleFontsPaused)
        isEnabled = enabled
        isPaused = paused
        lastCheck = defaults.object(forKey: SettingsKey.googleFontsLastCheck) as? Date
        phase = !enabled ? .off : paused ? .paused : .idle
    }

    /// The Google Fonts location (at most one).
    var location: LocationRecord? { model?.locations.first { $0.kind == .googleFonts } }

    /// The current folder; else `<parent of the first user folder>/Google Fonts`; else `~/Fonts/Google Fonts` when
    /// there is no folder location or that path would overlap a location.
    var defaultFolder: URL {
        if let location { return URL(fileURLWithPath: location.lastKnownPath, isDirectory: true) }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Fonts/Google Fonts", isDirectory: true)
        let all = model?.locations ?? []
        guard let first = all.filter({ $0.kind == .folder && !$0.autoIndexed }).min(by: { $0.id < $1.id }) else { return fallback }
        let candidate = URL(fileURLWithPath: first.lastKnownPath).deletingLastPathComponent()
            .appendingPathComponent("Google Fonts", isDirectory: true)
        let path = candidate.standardizedFileURL.path
        let overlaps = all.contains { loc in
            let other = URL(fileURLWithPath: loc.lastKnownPath).standardizedFileURL.path
            return other == path || other.hasPrefix(path + "/") || path.hasPrefix(other == "/" ? "/" : other + "/")
        }
        return overlaps ? fallback : candidate
    }

    // MARK: Launch

    /// At launch: when enabled and not paused, the daily catalogue check, then any pending downloads.
    func launch() async {
        guard isEnabled, location != nil else { phase = .off; return }
        guard !isPaused else { phase = .paused; return }
        await checkForUpdates(force: false)
        if case .error = phase { return }
        resume()
    }

    // MARK: Consent and settings

    /// Adds the Google Fonts location at `folder` (created if missing), turns syncing on and checks for updates.
    /// An existing Google Fonts location elsewhere is replaced (its files stay on disk).
    func enable(at folder: URL) async throws {
        guard let model, let backend = model.backend else { return }
        let previous = location
        let folder = folder.standardizedFileURL
        if previous.map({ URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL.path == folder.path }) != true {
            try await Self.background { try backend.validateGoogleFolder(folder, ignoring: previous?.id) }
            stopRun()
            await stoppedRun?.value
            let loc = try await Self.addLocation(at: folder, backend: backend, ignoring: previous?.id)
            if let previous, previous.id != loc.id { await model.removeLocation(previous.id).value }
            // The families were downloaded elsewhere, if at all: everything is fetched again into this folder.
            try await Self.background { try backend.store.resetGoogleDownloads() }
            await model.reloadLocations()
            model.updateWatchers()
        }
        setEnabled(true)
        setPaused(false)
        await checkForUpdates(force: true)
    }

    /// "Stop Syncing": no downloads or checks until enabled again. The location and the files stay.
    func disable() {
        stopRun()
        setEnabled(false)
        setPaused(false)
        phase = .off
    }

    /// "Remove Google Fonts from Library": stops syncing and removes the location; the files stay on disk.
    func removeFromLibrary() async throws {
        disable()
        await stoppedRun?.value
        guard let model, let loc = location else { return }
        await model.removeLocation(loc.id).value
        phase = .off
    }

    /// Changes the download folder. `moveFiles`: the folder is moved there (copied, then deleted, across volumes)
    /// and the location relinked, keeping activation. Otherwise the old location is removed from the library (its
    /// files stay) and every family is downloaded again into `url`. `url` must be new or an empty folder for a move.
    func changeFolder(to url: URL, moveFiles: Bool) async throws {
        guard let model, let backend = model.backend, let old = location else { return }
        let target = url.standardizedFileURL
        let oldURL = URL(fileURLWithPath: old.lastKnownPath, isDirectory: true).standardizedFileURL
        guard target.path != oldURL.path else { return }
        try await Self.background { try backend.validateGoogleFolder(target, ignoring: old.id) }
        if moveFiles, !old.online { throw LibraryError.locationOffline(old.displayName) }

        stopRun()
        await stoppedRun?.value
        do {
            if moveFiles {
                try await Self.background { try Self.moveFolder(from: oldURL, to: target) }
                await model.relink(old.id, to: target)
            } else {
                let loc = try await Self.addLocation(at: target, backend: backend, ignoring: old.id)
                if loc.id != old.id { await model.removeLocation(old.id).value }
                try await Self.background { try backend.store.resetGoogleDownloads() }
                await model.reloadLocations()
                model.updateWatchers()
            }
        } catch {
            restartIfActive()
            throw error
        }
        restartIfActive()
    }

    // MARK: Checks and downloads

    /// Fetches the catalogue and records what changed, then resumes downloading. Without `force`, skipped when the
    /// last check is less than 24 h old. A failure shows "Couldn't reach Google Fonts" and changes nothing else.
    func checkForUpdates(force: Bool) async {
        guard isEnabled, !isChecking, let model, let backend = model.backend, let loc = location else { return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        isChecking = true
        defer { isChecking = false }
        if runTask == nil { phase = .checking }
        let downloader = makeDownloader(store: backend.store, root: loc.lastKnownPath)
        do {
            _ = try await downloader.refreshCatalog()
        } catch {
            Self.log.error("Google Fonts catalogue check failed: \(String(describing: error), privacy: .public)")
            phase = .error(Self.unreachableMessage)
            return
        }
        setLastCheck(Date())
        if runTask != nil { rerunRequested = true }
        resume()
    }

    /// Starts (or continues) downloading every family that needs it, the failed ones included.
    func resume() {
        guard isEnabled else { return }
        setPaused(false)
        startRun()
    }

    func pause() {
        guard isEnabled else { return }
        setPaused(true)
        stopRun()
        phase = .paused
    }

    /// Fetches the catalogue only, for the consent sheet's family count and size. Nothing is stored.
    func loadEstimate() async {
        let transport = transport
        let minimum = minimumFamilies
        guard let families = try? await Task.detached(operation: {
            try GoogleCatalog.parseCatalog(try await transport.data(from: GoogleCatalog.catalogURL), minimumFamilies: minimum)
        }).value else { return }
        estimatedFamilies = families.count
        let sizes = families.compactMap(\.size)
        estimatedBytes = sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    // MARK: Volumes and quitting

    /// The location's volume went away: the run stops and the folder shows as offline.
    func volumeUnmounted(_ ids: [Int64]) {
        guard let loc = location, ids.contains(loc.id) else { return }
        stopRun()
        if isEnabled { phase = .offline }
    }

    /// The location's volume came back: downloading resumes unless syncing is off or paused.
    func volumeMounted(_ ids: [Int64]) {
        guard let loc = location, ids.contains(loc.id) else { return }
        if isEnabled && !isPaused { resume() } else { phase = restingPhase() }
    }

    func stopForQuit() {
        stopRun()
    }

    // MARK: Private

    private func makeDownloader(store: FontStore, root: String) -> GoogleFontsDownloader {
        GoogleFontsDownloader(store: store, root: URL(fileURLWithPath: root, isDirectory: true), transport: transport,
                              backoff: backoff, minimumFamilies: minimumFamilies)
    }

    /// The phase when nothing runs.
    private func restingPhase() -> GooglePhase {
        guard isEnabled, let loc = location else { return .off }
        if isPaused { return .paused }
        return loc.online ? .idle : .offline
    }

    private func restartIfActive() {
        if isEnabled && !isPaused { startRun() } else { phase = restingPhase() }
    }

    private func startRun() {
        guard runTask == nil else { return }
        guard let backend = model?.backend, let loc = location else { phase = restingPhase(); return }
        guard loc.online else { phase = .offline; return }
        runGeneration += 1
        let generation = runGeneration
        let previous = stoppedRun
        if case .downloading = phase {} else { phase = .downloading(done: lastProgress.done, total: lastProgress.total) }
        runTask = Task { [weak self] in
            await previous?.value
            await self?.run(backend: backend, location: loc, generation: generation)
        }
    }

    private func stopRun() {
        runGeneration += 1
        rerunRequested = false
        guard let runTask else { return }
        runTask.cancel()
        stoppedRun = runTask
        self.runTask = nil
    }

    private func run(backend: LibraryBackend, location loc: LocationRecord, generation: Int) async {
        let store = backend.store
        var progress = (try? await Self.background { try store.googleProgress() }) ?? (done: 0, total: 0)
        lastProgress = progress
        if generation == runGeneration { phase = .downloading(done: progress.done, total: progress.total) }

        let downloader = makeDownloader(store: store, root: loc.lastKnownPath)
        // `run` returns without an event when another run holds the downloader or the store cannot be read: the
        // stream ends when it returns, so this never waits for an event that will not come.
        let (events, continuation) = AsyncStream.makeStream(of: GoogleRunEvent.self)
        let worker = Task.detached {
            await downloader.run { continuation.yield($0) }
            continuation.finish()
        }
        var sinceRescan = 0
        var unavailable = false
        await withTaskCancellationHandler {
            for await event in events {
                switch event {
                case .familyDone:
                    progress.done += 1
                    sinceRescan += 1
                    if sinceRescan >= Self.rescanEvery {
                        sinceRescan = 0
                        model?.rescan(loc.id)
                    }
                    if generation == runGeneration { phase = .downloading(done: progress.done, total: progress.total) }
                case .familyFailed(let family, let message):
                    Self.log.error("Google Fonts family \(family, privacy: .public) failed: \(message, privacy: .public)")
                case .rootUnavailable:
                    unavailable = true
                case .finished:
                    break
                }
            }
        } onCancel: {
            worker.cancel()
        }
        await worker.value

        lastProgress = progress
        let present = model?.location(loc.id) != nil
        // Families written since the last rescan are indexed now (also after a pause; not when the folder is gone).
        if sinceRescan > 0, !unavailable, model?.location(loc.id)?.online == true { model?.rescan(loc.id) }
        if present {
            failedFamilies = (try? await Self.background {
                try store.googleFamiliesNeedingDownload().filter { $0.status == 2 }.count
            }) ?? failedFamilies
        }
        guard generation == runGeneration else { return }
        runTask = nil
        if !present {
            phase = restingPhase()
        } else if unavailable {
            phase = .offline
        } else if rerunRequested {
            rerunRequested = false
            startRun()
        } else if case .error = phase {
            // A failed check during the run stays visible.
        } else {
            phase = restingPhase()
        }
    }

    /// Creates `folder` (and missing parents) when needed, then adds the location; folders created here are removed
    /// again (only while empty) when that fails.
    private static func addLocation(at folder: URL, backend: LibraryBackend, ignoring: Int64?) async throws -> LocationRecord {
        try await background {
            let fm = FileManager.default
            var created: [URL] = []
            var probe = folder
            while !fm.fileExists(atPath: probe.path), probe.path != "/" {
                created.append(probe)
                probe = probe.deletingLastPathComponent()
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                return try backend.addGoogleLocation(folder, ignoring: ignoring)
            } catch {
                for dir in created { rmdir(dir.path) }
                throw error
            }
        }
    }

    /// Moves the folder `from` to `to` (a new path or an empty folder). Across volumes, copies and then deletes the
    /// original; a failed copy removes only the partial copy it made.
    nonisolated static func moveFolder(from: URL, to: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: to.path, isDirectory: &isDir) {
            guard isDir.boolValue, (try fm.contentsOfDirectory(atPath: to.path)).isEmpty else {
                throw LibraryError.folderNotEmpty(to.lastPathComponent)
            }
            guard rmdir(to.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { throw error }
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                try? fm.removeItem(at: to)
                throw error
            }
            try fm.removeItem(at: from)
        }
    }

    private func setEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: SettingsKey.googleFontsEnabled)
    }

    private func setPaused(_ value: Bool) {
        isPaused = value
        defaults.set(value, forKey: SettingsKey.googleFontsPaused)
    }

    private func setLastCheck(_ date: Date) {
        lastCheck = date
        defaults.set(date, forKey: SettingsKey.googleFontsLastCheck)
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
