import Foundation

public struct ScanDiff: Sendable {
    public var added: [ScannedFile] = []
    public var changed: [(FileRecord, ScannedFile)] = []
    public var moved: [(FileRecord, ScannedFile)] = []
    public var removed: [FileRecord] = []
    public var unchangedCount = 0

    /// Classifies `found` against `indexed`:
    /// 1. Same relative path: unchanged when size and mtime match, otherwise changed.
    /// 2. Each unmatched found file is fingerprinted; a match with an unmatched indexed file is a move
    ///    (that indexed file is consumed, so one record can't absorb two copies).
    /// 3. Leftover found files are added, leftover indexed files removed.
    /// The fingerprint closure runs only for unmatched found files, and not at all when no indexed file is left to match.
    public static func compute(indexed: [FileRecord], found: [ScannedFile],
                               fingerprint: (ScannedFile) throws -> String) rethrows -> ScanDiff {
        var diff = ScanDiff()
        var byPath: [String: FileRecord] = [:]
        byPath.reserveCapacity(indexed.count)
        for record in indexed { byPath[record.relativePath] = record }

        var unmatchedFound: [ScannedFile] = []
        for file in found {
            if let record = byPath.removeValue(forKey: file.relativePath) {
                if record.size == file.size && abs(record.mtime.timeIntervalSince(file.mtime)) < 0.001 {
                    diff.unchangedCount += 1
                } else {
                    diff.changed.append((record, file))
                }
            } else {
                unmatchedFound.append(file)
            }
        }

        // Preserve indexed order for deterministic output.
        var unmatchedIndexed = indexed.filter { byPath[$0.relativePath] != nil }
        guard !unmatchedIndexed.isEmpty else {
            diff.added = unmatchedFound
            return diff
        }
        var byFingerprint: [String: [Int]] = [:]  // fingerprint -> positions in unmatchedIndexed, in order
        for (i, record) in unmatchedIndexed.enumerated() { byFingerprint[record.fingerprint, default: []].append(i) }
        var consumed = Set<Int>()

        for file in unmatchedFound {
            let fp = try fingerprint(file)
            if var queue = byFingerprint[fp], !queue.isEmpty {
                let i = queue.removeFirst()
                byFingerprint[fp] = queue
                consumed.insert(i)
                diff.moved.append((unmatchedIndexed[i], file))
            } else {
                diff.added.append(file)
            }
        }
        for i in unmatchedIndexed.indices where !consumed.contains(i) { diff.removed.append(unmatchedIndexed[i]) }
        unmatchedIndexed.removeAll()
        return diff
    }
}
