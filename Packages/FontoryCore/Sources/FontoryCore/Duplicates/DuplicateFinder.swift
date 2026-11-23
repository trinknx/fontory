import CryptoKit
import Foundation

public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case exact, sameFont }
    public var id: String                 // content hash or postscript name
    public var kind: Kind
    public var faceIDs: [Int64]           // one representative face per file for exact groups
    public var fileIDs: [Int64]

    public init(id: String, kind: Kind, faceIDs: [Int64], fileIDs: [Int64]) {
        self.id = id
        self.kind = kind
        self.faceIDs = faceIDs
        self.fileIDs = fileIDs
    }
}

/// Finds duplicate files and faces in the index.
///
/// - Exact groups: files whose full-file SHA-256 (`files.content_hash`) is equal. Only files sharing a fingerprint
///   with another file are hashed (`hashCandidates`), so the cost stays small.
/// - Same-font groups: faces with the same PostScript name in different files that are not exact copies; each
///   distinct content is listed once (the first file of an exact group stands for its copies).
/// Private system faces are never listed; system faces only with `includeSystem`.
public final class DuplicateFinder: Sendable {
    static let batchSize = 20
    static let chunkSize = 1 << 20

    let store: FontStore
    /// Full-file hash of a file, nil when unreadable or cancelled (`isCancelled` is checked while reading). A test seam.
    let hashFile: @Sendable (URL, _ isCancelled: () -> Bool) -> String?

    public convenience init(store: FontStore) {
        self.init(store: store, hashFile: { DuplicateFinder.sha256(url: $0, isCancelled: $1) })
    }

    init(store: FontStore, hashFile: @escaping @Sendable (URL, _ isCancelled: () -> Bool) -> String?) {
        self.store = store
        self.hashFile = hashFile
    }

    /// Lowercase hex SHA-256 of the whole file, streamed in 1 MiB chunks. Nil when the file cannot be read, or when
    /// `isCancelled` says so between chunks.
    static func sha256(url: URL, isCancelled: () -> Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
                chunk = data
            } catch {
                return nil
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Hashing

    /// Hashes candidate files (equal fingerprints, content_hash missing) off-main in small batches, storing
    /// files.content_hash; unreachable files are skipped and get no hash. Cancellable between files.
    ///
    /// Files are read one at a time, in id order, in a detached `.utility` task per batch of 20 that the iterating
    /// task awaits. Each batch's hashes are written in one transaction, including a batch cut short by cancellation
    /// (the file being read when it came is not written). Offline locations are not candidates; a file that cannot be
    /// read counts as done but keeps no hash, so a later run tries it again.
    public func hashCandidates() -> AsyncStream<BackfillProgress> {
        let state = RunState(store: store, hashFile: hashFile)
        return AsyncStream(unfolding: { await state.next() })
    }

    private final class RunState: @unchecked Sendable {
        let store: FontStore
        let hashFile: @Sendable (URL, () -> Bool) -> String?
        var total: Int?
        var done = 0
        var cursor: Int64 = 0
        var finished = false

        init(store: FontStore, hashFile: @escaping @Sendable (URL, () -> Bool) -> String?) {
            self.store = store
            self.hashFile = hashFile
        }

        func next() async -> BackfillProgress? {
            if finished || Task.isCancelled { return nil }
            let store = store
            let hashFile = hashFile
            guard let total else {
                let count = await Self.detached { try store.countFilesNeedingHash() } ?? 0
                total = count
                if count == 0 || Task.isCancelled { finished = true; return nil }
                return BackfillProgress(done: 0, total: count)
            }
            let cursor = cursor
            let step = await Self.detached { () -> (count: Int, lastID: Int64, cancelled: Bool)? in
                let batch = try store.filesNeedingHash(limit: DuplicateFinder.batchSize, afterID: cursor)
                guard !batch.isEmpty else { return nil }
                var hashes: [(fileID: Int64, hash: String)] = []
                var processed = 0
                var lastID = cursor
                var cancelled = false
                for item in batch {
                    if Task.isCancelled { cancelled = true; break }
                    let hash = hashFile(item.url) { Task.isCancelled }
                    if Task.isCancelled { cancelled = true; break }  // possibly partial: not kept
                    if let hash { hashes.append((item.fileID, hash)) }
                    processed += 1
                    lastID = item.fileID
                }
                try store.setContentHashes(hashes)
                return (processed, lastID, cancelled)
            } ?? nil
            // A store failure, an empty batch or cancellation ends the run; the files left are picked up next time.
            guard let step, !step.cancelled, !Task.isCancelled else { finished = true; return nil }
            self.cursor = step.lastID
            done += step.count
            return BackfillProgress(done: done, total: max(total, done))
        }

        private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
            let task = Task.detached(priority: .utility) { try work() }
            return await withTaskCancellationHandler { try? await task.value } onCancel: { task.cancel() }
        }
    }

    // MARK: Groups

    /// Exact groups first (by the PostScript name of their first face, then hash), then same-font groups (by name).
    public func groups(includeSystem: Bool) throws -> [DuplicateGroup] {
        let faces = try store.duplicateCandidateFaces(includeSystem: includeSystem)

        // Exact: one representative face (the first public one) per file, files in id order.
        var exactOrder: [String] = []
        var exactFiles: [String: [(fileID: Int64, faceID: Int64, name: String)]] = [:]
        var lastFile: Int64?
        for face in faces where face.fileID != lastFile {
            lastFile = face.fileID
            guard let hash = face.contentHash else { continue }
            if exactFiles[hash] == nil { exactOrder.append(hash) }
            exactFiles[hash, default: []].append((face.fileID, face.faceID, face.postScriptName))
        }
        var exact: [(name: String, group: DuplicateGroup)] = []
        var exactHashes = Set<String>()
        for hash in exactOrder {
            guard let members = exactFiles[hash], members.count > 1 else { continue }
            exactHashes.insert(hash)
            exact.append((members[0].name, DuplicateGroup(id: hash, kind: .exact, faceIDs: members.map(\.faceID), fileIDs: members.map(\.fileID))))
        }
        exact.sort { ($0.name, $0.group.id) < ($1.name, $1.group.id) }

        // Same font: per name, the first face of each file, one file per distinct content.
        var names: [String: [(fileID: Int64, faceID: Int64, content: String)]] = [:]
        for face in faces {
            var members = names[face.postScriptName] ?? []
            if members.last?.fileID == face.fileID { continue }  // a second face of that name in the same file
            let content = face.contentHash.flatMap { exactHashes.contains($0) ? $0 : nil } ?? "file:\(face.fileID)"
            if members.contains(where: { $0.content == content }) { continue }
            members.append((face.fileID, face.faceID, content))
            names[face.postScriptName] = members
        }
        let sameFont = names.compactMap { name, members -> DuplicateGroup? in
            members.count > 1 ? DuplicateGroup(id: name, kind: .sameFont, faceIDs: members.map(\.faceID), fileIDs: members.map(\.fileID)) : nil
        }.sorted { $0.id < $1.id }

        return exact.map(\.group) + sameFont
    }
}
