import Foundation

/// A face of a duplicate candidate, as `DuplicateFinder.groups` reads it.
struct DuplicateCandidateFace {
    var faceID: Int64
    var fileID: Int64
    var postScriptName: String
    var contentHash: String?
}

// MARK: Duplicates and exclusions

extension FontStore {
    // MARK: Content hashes

    /// Online files that share their fingerprint with another indexed file and have no full-file hash yet, in id order,
    /// after `afterID`. The URL is built from the location's last known path; the file itself may be gone.
    public func filesNeedingHash(limit: Int, afterID: Int64) throws -> [(fileID: Int64, url: URL)] {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT files.id, locations.last_known_path, files.relative_path FROM files JOIN locations ON locations.id = files.location_id
            WHERE files.content_hash IS NULL AND locations.online != 0 AND files.id > ?1
              AND EXISTS (SELECT 1 FROM files AS other WHERE other.fingerprint = files.fingerprint AND other.id != files.id)
            ORDER BY files.id LIMIT ?2
            """)
            defer { s.reset() }
            try s.bind([.int(afterID), .int(Int64(limit))])
            var out: [(fileID: Int64, url: URL)] = []
            while try s.step() {
                let base = URL(fileURLWithPath: s.text(1))
                let rel = s.text(2)
                out.append((s.int64(0), rel.isEmpty ? base : base.appendingPathComponent(rel)))
            }
            return out
        }
    }

    public func countFilesNeedingHash() throws -> Int {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT COUNT(*) FROM files JOIN locations ON locations.id = files.location_id
            WHERE files.content_hash IS NULL AND locations.online != 0
              AND EXISTS (SELECT 1 FROM files AS other WHERE other.fingerprint = files.fingerprint AND other.id != files.id)
            """)
            defer { s.reset() }
            return try s.step() ? Int(s.int64(0)) : 0
        }
    }

    /// Stores full-file SHA-256 hashes (lowercase hex), in one transaction.
    public func setContentHashes(_ hashes: [(fileID: Int64, hash: String)]) throws {
        guard !hashes.isEmpty else { return }
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("UPDATE files SET content_hash = ? WHERE id = ?")
                defer { s.reset() }
                for (fileID, hash) in hashes {
                    s.reset()
                    try s.bind([.text(hash), .int(fileID)])
                    _ = try s.step()
                }
            }
        }
    }

    /// Drops the full-file hashes of files whose content changed (or may have), in one transaction.
    public func clearContentHashes(fileIDs: [Int64]) throws {
        guard !fileIDs.isEmpty else { return }
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("UPDATE files SET content_hash = NULL WHERE id = ? AND content_hash IS NOT NULL")
                defer { s.reset() }
                for id in fileIDs {
                    s.reset()
                    try s.bind([.int(id)])
                    _ = try s.step()
                }
            }
        }
    }

    /// The file's stored full-file hash. For tests.
    func contentHash(fileID: Int64) throws -> String? {
        try reader.withLock {
            let s = try reader.prepare("SELECT content_hash FROM files WHERE id = ?")
            defer { s.reset() }
            try s.bind([.int(fileID)])
            return try s.step() && !s.isNull(0) ? s.text(0) : nil
        }
    }

    /// File records by id (with `addedAt`); unknown ids are left out.
    public func fileRecords(ids: [Int64]) throws -> [Int64: FileRecord] {
        try reader.withLock {
            let s = try reader.prepare("SELECT \(Self.fileColumns) FROM files WHERE id = ?")
            defer { s.reset() }
            var out: [Int64: FileRecord] = [:]
            out.reserveCapacity(ids.count)
            for id in ids {
                s.reset()
                try s.bind([.int(id)])
                if try s.step() { out[id] = Self.fileRecord(s) }
            }
            return out
        }
    }

    // MARK: Candidates

    /// Public faces (and, unless `includeSystem`, none in system locations) whose file has a full-file hash shared
    /// with another file, or whose PostScript name appears in more than one file. Ordered by file id, then face index.
    func duplicateCandidateFaces(includeSystem: Bool) throws -> [DuplicateCandidateFace] {
        try reader.withLock {
            let visible = LibraryQuery.publicFaceClause + (includeSystem ? "" : " AND locations.kind != 2")
            let s = try reader.prepare("""
            SELECT faces.id, faces.file_id, faces.postscript_name, files.content_hash
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE \(visible) AND (
              files.content_hash IN (SELECT content_hash FROM files WHERE content_hash IS NOT NULL GROUP BY content_hash HAVING COUNT(*) > 1)
              OR faces.postscript_name IN (SELECT postscript_name FROM faces GROUP BY postscript_name HAVING COUNT(DISTINCT file_id) > 1))
            ORDER BY faces.file_id, faces.face_index
            """)
            defer { s.reset() }
            var out: [DuplicateCandidateFace] = []
            while try s.step() {
                out.append(DuplicateCandidateFace(faceID: s.int64(0), fileID: s.int64(1), postScriptName: s.text(2),
                                                  contentHash: s.isNull(3) ? nil : s.text(3)))
            }
            return out
        }
    }

    /// Which of `fingerprints` an indexed file outside `locationID` has. A match whose file is no longer at its path in an
    /// online location does not count: it was moved away (to the location being scanned, say) and its own location's
    /// next scan drops it. A file in an offline location counts (it is not checked). `fileExists` is a test seam.
    public func fingerprintsIndexed(_ fingerprints: [String], outside locationID: Int64,
                                    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> Set<String> {
        guard !fingerprints.isEmpty else { return [] }
        // Read under the lock, check the disk after it.
        let matches: [String: [(online: Bool, url: URL)]] = try reader.withLock {
            let s = try reader.prepare("""
            SELECT locations.online, locations.last_known_path, files.relative_path
            FROM files JOIN locations ON locations.id = files.location_id
            WHERE files.fingerprint = ? AND files.location_id != ?
            """)
            defer { s.reset() }
            var out: [String: [(online: Bool, url: URL)]] = [:]
            for fp in Set(fingerprints) {
                s.reset()
                try s.bind([.text(fp), .int(locationID)])
                while try s.step() {
                    let base = URL(fileURLWithPath: s.text(1))
                    let rel = s.text(2)
                    out[fp, default: []].append((s.int64(0) != 0, rel.isEmpty ? base : base.appendingPathComponent(rel)))
                }
            }
            return out
        }
        return Set(matches.compactMap { fp, files in files.contains { !$0.online || fileExists($0.url) } ? fp : nil })
    }

    /// Per file, the number of its faces with tags, a note or Quick Collection membership (activation not counted);
    /// files without any are left out. Keep rule 1b and the Remove from Library confirmation.
    public func userDataFaceCounts(fileIDs: [Int64]) throws -> [Int64: Int] {
        guard !fileIDs.isEmpty else { return [:] }
        return try reader.withLock {
            let s = try reader.prepare("""
            SELECT COUNT(*) FROM faces WHERE file_id = ? AND (note IS NOT NULL
              OR EXISTS(SELECT 1 FROM face_tags WHERE face_id = faces.id) OR EXISTS(SELECT 1 FROM quick_collection WHERE face_id = faces.id))
            """)
            defer { s.reset() }
            var out: [Int64: Int] = [:]
            for id in Set(fileIDs) {
                s.reset()
                try s.bind([.int(id)])
                if try s.step(), s.int64(0) > 0 { out[id] = Int(s.int64(0)) }
            }
            return out
        }
    }

    // MARK: Exclusions

    /// Removes the files from the index (their faces with tags, notes and Quick Collection membership go too) and records
    /// them in `excluded_files` with their fingerprint, so a rescan skips them. One transaction. The files stay on disk.
    public func removeFromLibrary(fileIDs: [Int64]) throws {
        guard !fileIDs.isEmpty else { return }
        try database.withLock {
            try database.transaction {
                let read = try database.prepare("SELECT location_id, relative_path, fingerprint FROM files WHERE id = ?")
                defer { read.reset() }
                let insert = try database.prepare(
                    "INSERT OR REPLACE INTO excluded_files(location_id, relative_path, fingerprint) VALUES(?, ?, ?)")
                defer { insert.reset() }
                let delete = try database.prepare("DELETE FROM files WHERE id = ?")
                defer { delete.reset() }
                for id in fileIDs {
                    read.reset()
                    try read.bind([.int(id)])
                    guard try read.step() else { continue }
                    let values: [SQLValue] = [.int(read.int64(0)), .text(read.text(1)), .text(read.text(2))]
                    read.reset()
                    insert.reset()
                    try insert.bind(values)
                    _ = try insert.step()
                    delete.reset()
                    try delete.bind([.int(id)])
                    _ = try delete.step()
                }
            }
        }
    }

    public func excludedFiles() throws -> [(locationID: Int64, relativePath: String, fingerprint: String)] {
        try reader.withLock {
            let s = try reader.prepare("SELECT location_id, relative_path, fingerprint FROM excluded_files ORDER BY location_id, relative_path")
            defer { s.reset() }
            var out: [(locationID: Int64, relativePath: String, fingerprint: String)] = []
            while try s.step() { out.append((s.int64(0), s.text(1), s.text(2))) }
            return out
        }
    }

    /// The exclusions of one location: excluded relative path -> the fingerprint the file had.
    public func exclusions(locationID: Int64) throws -> [String: String] {
        try reader.withLock {
            let s = try reader.prepare("SELECT relative_path, fingerprint FROM excluded_files WHERE location_id = ?")
            defer { s.reset() }
            try s.bind([.int(locationID)])
            var out: [String: String] = [:]
            while try s.step() { out[s.text(0)] = s.text(1) }
            return out
        }
    }

    /// Drops stale exclusions of a location (a path now holding an indexed file), in one transaction.
    func deleteExclusions(locationID: Int64, relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try database.withLock {
            try database.transaction {
                for path in relativePaths { try includeAgain(locationID: locationID, relativePath: path) }
            }
        }
    }

    /// Deletes the exclusion; the caller rescans the location to index the file again.
    public func includeAgain(locationID: Int64, relativePath: String) throws {
        try database.withLock {
            let s = try database.prepare("DELETE FROM excluded_files WHERE location_id = ? AND relative_path = ?")
            defer { s.reset() }
            try s.bind([.int(locationID), .text(relativePath)])
            _ = try s.step()
        }
    }
}
