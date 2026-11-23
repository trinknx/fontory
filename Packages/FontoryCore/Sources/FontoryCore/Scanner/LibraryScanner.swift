import Foundation

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case enumerating, parsing, applying, done
        case aborted(reason: String)
    }

    public var locationID: Int64
    public var phase: Phase
    public var total: Int
    public var processed: Int
    public var failed: Int
    public var removedWithUserData: Int
    /// Relative paths the scan could not read (capped at 50; see `unreadableCount` for the total).
    public var unreadablePaths: [String]
    public var unreadableCount: Int
    /// Records that were not removed this run because part of the tree was unreadable.
    public var skippedRemovals: Int

    public init(locationID: Int64, phase: Phase, total: Int = 0, processed: Int = 0, failed: Int = 0, removedWithUserData: Int = 0,
                unreadablePaths: [String] = [], unreadableCount: Int = 0, skippedRemovals: Int = 0) {
        self.unreadablePaths = unreadablePaths
        self.unreadableCount = unreadableCount
        self.skippedRemovals = skippedRemovals
        self.locationID = locationID
        self.phase = phase
        self.total = total
        self.processed = processed
        self.failed = failed
        self.removedWithUserData = removedWithUserData
    }
}

/// Incremental, move-aware scanner for one location at a time.
///
/// Data safety: index rows (and the activation and notes attached to them) are deleted only after the
/// whole tree was enumerated without error, the listing is plausible, and the root still exists immediately
/// before the removals run. Any doubt aborts the scan and removes nothing.
public actor LibraryScanner {
    private static let batchSize = 500
    private static let progressInterval: Duration = .milliseconds(100)

    private let store: FontStore
    private let rootURL: @Sendable (LocationRecord) -> URL?
    private let parallelism: Int
    private let onPhase: (@Sendable (ScanProgress.Phase) -> Void)?
    private var runs: [Int64: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var nextToken: UInt64 = 0

    /// `onPhase` is a test hook, called synchronously on every phase transition (never throttled).
    public init(store: FontStore, rootURL: @escaping @Sendable (LocationRecord) -> URL?,
                parallelism: Int = ProcessInfo.processInfo.activeProcessorCount,
                onPhase: (@Sendable (ScanProgress.Phase) -> Void)? = nil) {
        self.store = store
        self.rootURL = rootURL
        self.parallelism = max(1, parallelism)
        self.onPhase = onPhase
    }

    /// Starts a scan (cancelling any scan already running for the location). The stream always ends with `.done` or `.aborted`.
    public func scan(locationID: Int64) -> AsyncStream<ScanProgress> {
        let previous = runs[locationID]?.task
        previous?.cancel()
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        nextToken += 1
        let token = nextToken
        let task = Task {
            // A restarted scan must not overlap the run it cancelled: that run may still be applying a batch.
            await previous?.value
            await self.run(locationID: locationID, continuation: continuation)
            continuation.finish()
            self.finishRun(locationID, token: token)
        }
        runs[locationID] = (token, task)
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel(locationID: Int64) {
        runs[locationID]?.task.cancel()
    }

    private func finishRun(_ locationID: Int64, token: UInt64) {
        if runs[locationID]?.token == token { runs[locationID] = nil }
    }

    // MARK: Run

    private struct Abort: Error { var reason: String }

    private struct Job: Sendable {
        var file: ScannedFile
        var record: FileRecord?  // non-nil: changed file being re-parsed
        var fingerprint: String?  // already computed by the diff
    }

    private struct Parsed: Sendable {
        var job: Job
        var fingerprint: String
        var faces: [ParsedFace]
    }

    private func run(locationID: Int64, continuation: AsyncStream<ScanProgress>.Continuation) async {
        var progress = ScanProgress(locationID: locationID, phase: .enumerating)
        var lastEmit = ContinuousClock.now - Self.progressInterval
        var announced: ScanProgress.Phase?
        func emit(_ phase: ScanProgress.Phase, force: Bool = false) {
            let changedPhase = announced != phase
            announced = phase
            progress.phase = phase
            if changedPhase { onPhase?(phase) }
            let now = ContinuousClock.now
            if force || changedPhase || now - lastEmit >= Self.progressInterval {
                lastEmit = now
                continuation.yield(progress)
            }
        }
        func abort(_ reason: String) {
            progress.phase = .aborted(reason: reason)
            onPhase?(progress.phase)
            continuation.yield(progress)
        }

        do {
            guard let location = try store.locations().first(where: { $0.id == locationID }) else {
                throw Abort(reason: "unknown location")
            }
            guard let root = rootURL(location) else { throw Abort(reason: "location is not reachable") }
            guard Self.directoryExists(root) else { throw Abort(reason: "location root does not exist") }

            // Enumerate. Any error means the listing is unreliable: apply nothing.
            emit(.enumerating, force: true)
            var found: [ScannedFile] = []
            let report = EnumerationReport()
            do {
                for try await file in FontFileEnumerator.enumerate(root: root, report: report) {
                    found.append(file)
                    progress.total = found.count
                    emit(.enumerating)
                }
            } catch {
                throw Abort(reason: "enumeration failed: \(error.localizedDescription)")
            }
            try Self.checkNotCancelled()

            let indexed = try store.files(in: locationID)
            // A mounted-but-empty directory (e.g. a volume's mount point) must not wipe a populated index.
            if found.isEmpty && !indexed.isEmpty { throw Abort(reason: "root is empty but the index is not") }

            var fingerprints: [String: String] = [:]
            var unfingerprintable: [String] = []
            let diff = ScanDiff.compute(indexed: indexed, found: found) { file in
                if let fp = try? Fingerprint.compute(url: file.url, size: file.size) {
                    fingerprints[file.relativePath] = fp
                    return fp
                }
                unfingerprintable.append(file.relativePath)
                return "unreadable:\(file.relativePath)"  // never equals a real fingerprint
            }

            let jobs = diff.changed.map { Job(file: $0.1, record: $0.0, fingerprint: fingerprints[$0.1.relativePath]) }
                + diff.added.map { Job(file: $0, record: nil, fingerprint: fingerprints[$0.relativePath]) }
            progress.total = jobs.count
            progress.processed = 0
            emit(.parsing, force: true)

            try applyMoves(diff.moved, locationID: locationID)
            try await parseAndApply(jobs: jobs, locationID: locationID) { failed in
                progress.processed += 1
                if failed { progress.failed += 1 }
                emit(.parsing)
            }

            // Any unreadable subtree or file means the listing is incomplete: report it, and keep every indexed record.
            let unreadableCount = report.count + unfingerprintable.count
            progress.unreadableCount = unreadableCount
            progress.unreadablePaths = Array((report.paths + unfingerprintable).prefix(50))

            // Removals last, only if everything above went cleanly and the root is still there.
            emit(.applying, force: true)
            try Self.checkNotCancelled()
            guard Self.directoryExists(root) else { throw Abort(reason: "location root disappeared during scan") }
            if unreadableCount > 0 {
                progress.skippedRemovals = diff.removed.count
                try store.markScanned(locationID, at: Date())
                emit(.done, force: true)
                return
            }
            let removedIDs = diff.removed.map(\.id)
            progress.removedWithUserData = try store.userDataFaceCount(fileIDs: removedIDs)
            try store.deleteFiles(removedIDs)
            try store.markScanned(locationID, at: Date())
            emit(.done, force: true)
        } catch let a as Abort {
            abort(a.reason)
        } catch {
            abort("\(error.localizedDescription)")
        }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func checkNotCancelled() throws {
        if Task.isCancelled { throw Abort(reason: "cancelled") }
    }

    private func applyMoves(_ moves: [(FileRecord, ScannedFile)], locationID: Int64) throws {
        var start = 0
        while start < moves.count {
            let end = min(start + Self.batchSize, moves.count)
            try store.database.transaction {
                for (record, file) in moves[start..<end] {
                    try store.moveFile(fileID: record.id, toRelativePath: file.relativePath, mtime: file.mtime)
                }
            }
            start = end
        }
    }

    /// Parses jobs concurrently (at most `parallelism` in flight) and applies results in transactions of 500 files.
    /// No transaction is open while parsing. A parse failure counts as failed and leaves the index untouched for that file.
    private func parseAndApply(jobs: [Job], locationID: Int64, report: (_ failed: Bool) -> Void) async throws {
        guard !jobs.isEmpty else { return }
        let importBatch = try store.nextImportBatch()
        let limit = parallelism
        let wasCancelled = try await withThrowingTaskGroup(of: Parsed?.self, returning: Bool.self) { group in
            var pending: [Parsed] = []
            var next = 0
            var inFlight = 0
            var cancelled = false
            while next < jobs.count && inFlight < limit {
                let job = jobs[next]
                group.addTask { Self.parse(job) }
                next += 1
                inFlight += 1
            }
            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1
                if let parsed = result {
                    pending.append(parsed)
                    if pending.count >= Self.batchSize {
                        try apply(pending, locationID: locationID, importBatch: importBatch)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                report(result == nil)
                if Task.isCancelled {
                    cancelled = true
                    group.cancelAll()
                } else if next < jobs.count {
                    let job = jobs[next]
                    group.addTask { Self.parse(job) }
                    next += 1
                    inFlight += 1
                }
            }
            try apply(pending, locationID: locationID, importBatch: importBatch)
            return cancelled
        }
        if wasCancelled { throw Abort(reason: "cancelled") }
    }

    private func apply(_ batch: [Parsed], locationID: Int64, importBatch: Int64) throws {
        guard !batch.isEmpty else { return }
        try store.database.transaction {
            for item in batch {
                if let record = item.job.record {
                    try store.replaceFaces(fileID: record.id, size: item.job.file.size, mtime: item.job.file.mtime,
                                           fingerprint: item.fingerprint, faces: item.faces)
                } else {
                    let file = FileRecord(locationID: locationID, relativePath: item.job.file.relativePath,
                                          size: item.job.file.size, mtime: item.job.file.mtime,
                                          format: item.job.file.format, fingerprint: item.fingerprint)
                    _ = try store.insertFile(file, faces: item.faces, importBatch: importBatch)
                }
            }
        }
    }

    private nonisolated static func parse(_ job: Job) -> Parsed? {
        guard !Task.isCancelled else { return nil }
        do {
            let faces = try FontParser.parse(url: job.file.url)
            let fp = try job.fingerprint ?? Fingerprint.compute(url: job.file.url, size: job.file.size)
            return Parsed(job: job, fingerprint: fp, faces: faces)
        } catch {
            return nil
        }
    }
}
