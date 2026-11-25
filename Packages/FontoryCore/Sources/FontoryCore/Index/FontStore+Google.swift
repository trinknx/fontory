import Foundation

public struct GoogleFamilyState: Sendable, Hashable {
    public let family: String
    public let folder: String
    public let lastModified: String
    public let downloadedModified: String?
    public let status: Int
    public let error: String?
    public let withdrawn: Bool
    /// Basenames Fontory installed into the family folder in its last completed download (empty when none known).
    /// Updates delete only these files, never anything else in the folder.
    public let installedFiles: [String]

    public init(family: String, folder: String, lastModified: String, downloadedModified: String?,
                status: Int, error: String?, withdrawn: Bool, installedFiles: [String] = []) {
        self.family = family
        self.folder = folder
        self.lastModified = lastModified
        self.downloadedModified = downloadedModified
        self.status = status
        self.error = error
        self.withdrawn = withdrawn
        self.installedFiles = installedFiles
    }
}

public struct GoogleSyncSummary: Sendable, Equatable {
    public let added: Int
    public let updated: Int
    public let withdrawn: Int

    public init(added: Int, updated: Int, withdrawn: Int) {
        self.added = added
        self.updated = updated
        self.withdrawn = withdrawn
    }
}

/// Google Fonts catalogue state. Status: 0 pending, 1 done, 2 failed. Rows are never deleted; families that
/// leave the catalogue are flagged `withdrawn`. Subsets are stored comma-wrapped (",latin,") for LIKE matching.
extension FontStore {
    /// Reconciles the cached catalogue with a freshly fetched one, in a single transaction.
    public func syncGoogleCatalog(_ families: [GoogleFamily]) throws -> GoogleSyncSummary {
        try database.withLock {
            try database.transaction {
                var existing: [String: (modified: String, withdrawn: Bool)] = [:]
                var taken = Set<String>()
                do {
                    let s = try database.prepare("SELECT family, folder, last_modified, withdrawn FROM google_families")
                    defer { s.reset() }
                    while try s.step() {
                        existing[s.text(0)] = (s.text(2), s.int64(3) != 0)
                        taken.insert(s.text(1).lowercased())
                    }
                }
                let insert = try database.prepare("""
                    INSERT INTO google_families(family, folder, category, subsets, popularity, designers, last_modified)
                    VALUES(?,?,?,?,?,?,?)
                    """)
                defer { insert.reset() }
                let update = try database.prepare("""
                    UPDATE google_families SET category = ?, subsets = ?, popularity = ?, designers = ?, withdrawn = 0
                    WHERE family = ?
                    """)
                defer { update.reset() }
                let changed = try database.prepare("""
                    UPDATE google_families SET last_modified = ?, status = 0, error = NULL WHERE family = ?
                    """)
                defer { changed.reset() }

                var added = 0, updated = 0
                var seen = Set<String>()
                for f in families {
                    guard seen.insert(f.family).inserted else { continue }
                    let subsets: SQLValue = .text("," + f.subsets.joined(separator: ",") + ",")
                    let designers: SQLValue = .text(f.designers.joined(separator: ", "))
                    if let old = existing[f.family] {
                        try update.bind([.text(f.category), subsets, .int(Int64(f.popularity)), designers, .text(f.family)])
                        _ = try update.step()
                        update.reset()
                        if old.modified != f.lastModified {
                            try changed.bind([.text(f.lastModified), .text(f.family)])
                            _ = try changed.step()
                            changed.reset()
                            updated += 1
                        }
                    } else {
                        let folder = GoogleCatalog.folderName(for: f.family, taken: taken)
                        taken.insert(folder.lowercased())
                        try insert.bind([.text(f.family), .text(folder), .text(f.category), subsets,
                                         .int(Int64(f.popularity)), designers, .text(f.lastModified)])
                        _ = try insert.step()
                        insert.reset()
                        added += 1
                    }
                }

                var withdrawn = 0
                let flag = try database.prepare("UPDATE google_families SET withdrawn = 1 WHERE family = ?")
                defer { flag.reset() }
                for (family, old) in existing where !old.withdrawn && !seen.contains(family) {
                    try flag.bind([.text(family)])
                    _ = try flag.step()
                    flag.reset()
                    withdrawn += 1
                }
                return GoogleSyncSummary(added: added, updated: updated, withdrawn: withdrawn)
            }
        }
    }

    public func googleFamiliesNeedingDownload() throws -> [GoogleFamilyState] {
        try reader.withLock {
            let s = try reader.prepare("""
                SELECT family, folder, last_modified, downloaded_modified, status, error, withdrawn, installed_files
                FROM google_families WHERE withdrawn = 0 AND (downloaded_modified IS NULL OR downloaded_modified != last_modified)
                ORDER BY family ASC
                """)
            defer { s.reset() }
            var out: [GoogleFamilyState] = []
            while try s.step() {
                out.append(GoogleFamilyState(family: s.text(0), folder: s.text(1), lastModified: s.text(2),
                                             downloadedModified: s.isNull(3) ? nil : s.text(3), status: Int(s.int64(4)),
                                             error: s.isNull(5) ? nil : s.text(5), withdrawn: s.int64(6) != 0,
                                             installedFiles: s.isNull(7) ? [] : Self.decodeInstalledFiles(s.text(7))))
            }
            return out
        }
    }

    /// `installedFiles`: the basenames this download wrote into the family folder; the next update may delete those
    /// of them the new version no longer lists, and nothing else.
    public func markGoogleFamilyDone(_ family: String, modified: String, installedFiles: [String]) throws {
        let files: SQLValue = installedFiles.isEmpty ? .null : .text(Self.encodeInstalledFiles(installedFiles))
        try database.withLock {
            let s = try database.prepare("""
                UPDATE google_families SET downloaded_modified = ?, status = 1, error = NULL, installed_files = ?
                WHERE family = ?
                """)
            defer { s.reset() }
            try s.bind([.text(modified), files, .text(family)])
            _ = try s.step()
        }
    }

    public func markGoogleFamilyFailed(_ family: String, error: String) throws {
        try database.withLock {
            let s = try database.prepare("UPDATE google_families SET status = 2, error = ? WHERE family = ?")
            defer { s.reset() }
            try s.bind([.text(error), .text(family)])
            _ = try s.step()
        }
    }

    /// Marks every family as never downloaded (the files are elsewhere or gone, e.g. after the folder changed), so the
    /// next run downloads them all again. Nothing is known to be installed in the new folder, so installed files are
    /// cleared too. Withdrawn flags are kept.
    public func resetGoogleDownloads() throws {
        try database.withLock {
            try database.execute("""
                UPDATE google_families SET downloaded_modified = NULL, status = 0, error = NULL, installed_files = NULL
                """)
        }
    }

    static func encodeInstalledFiles(_ names: [String]) -> String {
        (try? JSONEncoder().encode(names)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// Unreadable data means none known, so nothing is deleted.
    static func decodeInstalledFiles(_ text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    public func googleProgress() throws -> (done: Int, total: Int) {
        try reader.withLock {
            let s = try reader.prepare("""
                SELECT COALESCE(SUM(CASE WHEN downloaded_modified = last_modified THEN 1 ELSE 0 END), 0), COUNT(*)
                FROM google_families WHERE withdrawn = 0
                """)
            defer { s.reset() }
            _ = try s.step()
            return (Int(s.int64(0)), Int(s.int64(1)))
        }
    }
}
