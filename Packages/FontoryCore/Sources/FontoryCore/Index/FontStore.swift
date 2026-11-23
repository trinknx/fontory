import Foundation

/// Index access. Every method holds a connection lock for its whole statement sequence (statements are cached
/// and shared per SQL string). Writes go to `database`; pure reads go to a second, read-only connection to the
/// same file, so browsing never waits for a scanner transaction (WAL). In-memory databases use one connection.
public final class FontStore: Sendable {
    public let database: Database
    let reader: Database

    public init(database: Database) throws {
        self.database = database
        try Schema.migrate(database)
        let path = database.path
        if path.isEmpty || path == ":memory:" || path.hasPrefix("file::memory:") {
            reader = database
        } else {
            reader = try Database(path: path, readOnly: true)
            // A checkpoint or schema change can briefly lock the file; wait instead of failing a browse query.
            try reader.execute("PRAGMA busy_timeout = 2000")
        }
    }

    /// The read connection's busy timeout in milliseconds. For tests.
    var readerBusyTimeout: Int64 {
        (try? reader.withLock {
            let s = try reader.prepare("PRAGMA busy_timeout")
            defer { s.reset() }
            return try s.step() ? s.int64(0) : 0
        }) ?? 0
    }

    // MARK: Locations

    private static let locationColumns = "id, kind, volume_uuid, relative_path, display_name, last_known_path, online, last_scan, auto_indexed"

    private func location(_ s: Statement) -> LocationRecord {
        LocationRecord(
            id: s.int64(0), kind: LocationKind(rawValue: Int(s.int64(1))) ?? .folder,
            volumeUUID: s.text(2), relativePath: s.text(3), displayName: s.text(4), lastKnownPath: s.text(5),
            online: s.int64(6) != 0, lastScan: s.isNull(7) ? nil : Date(timeIntervalSince1970: s.double(7)),
            autoIndexed: s.int64(8) != 0)
    }

    /// Inserts a location, or updates the one with the same volume reference (its kind and auto-indexed flag too).
    /// A user-owned location is never claimed by an auto-indexed upsert: it is returned unchanged (check `autoIndexed`
    /// on the result). The reverse, a user adding a folder the inventory had auto-indexed, converts it.
    public func upsertLocation(kind: LocationKind, volumeUUID: String, relativePath: String, displayName: String, lastKnownPath: String,
                               autoIndexed: Bool = false) throws -> LocationRecord {
        try database.withLock {
            try database.transaction {
                let up = try database.prepare("""
                INSERT INTO locations(kind, volume_uuid, relative_path, display_name, last_known_path, online, auto_indexed)
                VALUES(?,?,?,?,?,1,?)
                ON CONFLICT(volume_uuid, relative_path) DO UPDATE SET
                  kind = excluded.kind, display_name = excluded.display_name,
                  last_known_path = excluded.last_known_path, online = 1, auto_indexed = excluded.auto_indexed
                WHERE NOT (locations.auto_indexed = 0 AND excluded.auto_indexed != 0)
                """)
                defer { up.reset() }
                try up.bind([.int(Int64(kind.rawValue)), .text(volumeUUID), .text(relativePath), .text(displayName), .text(lastKnownPath),
                             .int(autoIndexed ? 1 : 0)])
                _ = try up.step()
                let sel = try database.prepare("SELECT \(Self.locationColumns) FROM locations WHERE volume_uuid = ? AND relative_path = ?")
                defer { sel.reset() }
                try sel.bind([.text(volumeUUID), .text(relativePath)])
                guard try sel.step() else { throw SQLiteError(code: -1, message: "location vanished after upsert") }
                return location(sel)
            }
        }
    }

    public func locations() throws -> [LocationRecord] {
        try reader.withLock {
            let s = try reader.prepare("SELECT \(Self.locationColumns) FROM locations ORDER BY display_name COLLATE NOCASE, id")
            defer { s.reset() }
            var out: [LocationRecord] = []
            while try s.step() { out.append(location(s)) }
            return out
        }
    }

    public func setLocationOnline(_ id: Int64, online: Bool, lastKnownPath: String?) throws {
        try database.withLock {
            let s = try database.prepare("UPDATE locations SET online = ?, last_known_path = COALESCE(?, last_known_path) WHERE id = ?")
            defer { s.reset() }
            try s.bind([.int(online ? 1 : 0), lastKnownPath.map { .text($0) } ?? .null, .int(id)])
            _ = try s.step()
        }
    }

    public func markScanned(_ id: Int64, at date: Date) throws {
        try database.withLock {
            let s = try database.prepare("UPDATE locations SET last_scan = ? WHERE id = ?")
            defer { s.reset() }
            try s.bind([.double(date.timeIntervalSince1970), .int(id)])
            _ = try s.step()
        }
    }

    /// Smart rules naming the location are pointed at `SmartRule.deletedID` (location ids can be reused).
    public func deleteLocation(_ id: Int64) throws {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("DELETE FROM locations WHERE id = ?")
                defer { s.reset() }
                try s.bind([.int(id)])
                _ = try s.step()
                try tombstoneRuleConditions(field: .location, ids: [id])
            }
        }
    }

    // MARK: Files

    public func files(in locationID: Int64) throws -> [FileRecord] {
        try database.withLock {
            let s = try database.prepare("SELECT id, location_id, relative_path, size, mtime, format, fingerprint FROM files WHERE location_id = ? ORDER BY relative_path")
            defer { s.reset() }
            try s.bind([.int(locationID)])
            var out: [FileRecord] = []
            while try s.step() {
                out.append(FileRecord(id: s.int64(0), locationID: s.int64(1), relativePath: s.text(2), size: s.int64(3),
                                      mtime: Date(timeIntervalSince1970: s.double(4)), format: s.text(5), fingerprint: s.text(6)))
            }
            return out
        }
    }

    public func nextImportBatch() throws -> Int64 {
        try database.withLock {
            let s = try database.prepare("SELECT COALESCE(MAX(import_batch), 0) + 1 FROM files")
            defer { s.reset() }
            _ = try s.step()
            return s.int64(0)
        }
    }

    public func insertFile(_ file: FileRecord, faces: [ParsedFace], importBatch: Int64) throws -> Int64 {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("""
                INSERT INTO files(location_id, relative_path, size, mtime, format, fingerprint, added_at, import_batch)
                VALUES(?,?,?,?,?,?,?,?)
                """)
                defer { s.reset() }
                try s.bind([.int(file.locationID), .text(file.relativePath), .int(file.size),
                            .double(file.mtime.timeIntervalSince1970), .text(file.format), .text(file.fingerprint),
                            .double(Date().timeIntervalSince1970), .int(importBatch)])
                _ = try s.step()
                let fileID = database.lastInsertRowID
                for face in faces { try insertFace(face, fileID: fileID) }
                return fileID
            }
        }
    }

    private static let faceColumns = """
    file_id, face_index, postscript_name, family, style, full_name, weight, width, slant, is_italic, is_variable,
    axes_json, vendor, designer, version, glyph_count, scripts_bitmask, units_per_em, ascender, descender,
    cap_height, x_height, fs_type, outline_type, is_color, is_bitmap, has_gsub, has_gpos, style_class, class_version
    """

    private func faceValues(_ f: ParsedFace, fileID: Int64) -> [SQLValue] {
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        func flag(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
        return [
            .int(fileID), .int(Int64(f.faceIndex)), .text(f.postScriptName), .text(f.family), .text(f.style), .text(f.fullName),
            .double(f.weight), .double(f.width), .double(f.slant), flag(f.isItalic), flag(f.isVariable),
            opt(f.axesJSON), opt(f.vendor), opt(f.designer), opt(f.version), .int(Int64(f.glyphCount)), .int(f.scriptsBitmask),
            .int(Int64(f.metrics.unitsPerEm)), .double(f.metrics.ascender), .double(f.metrics.descender),
            .double(f.metrics.capHeight), .double(f.metrics.xHeight), f.fsType.map { .int(Int64($0)) } ?? .null,
            .text(f.outlineType.rawValue), flag(f.isColor), flag(f.isBitmap), flag(f.hasGSUB), flag(f.hasGPOS),
            .int(Int64(f.styleClass.rawValue)), .int(Int64(StyleClassifier.version)),
        ]
    }

    private func insertFace(_ f: ParsedFace, fileID: Int64) throws {
        try database.withLock {
            let marks = Array(repeating: "?", count: 30).joined(separator: ",")
            let s = try database.prepare("INSERT INTO faces(\(Self.faceColumns)) VALUES(\(marks))")
            defer { s.reset() }
            try s.bind(faceValues(f, fileID: fileID))
            _ = try s.step()
        }
    }

    /// Re-parses a file's faces in place. Faces whose PostScript name survives keep their
    /// row id (so activation, note, tags, Quick Collection membership, last_activated, custom family and representative prefs persist).
    public func replaceFaces(fileID: Int64, size: Int64, mtime: Date, fingerprint: String, faces: [ParsedFace]) throws {
        try database.withLock {
            try database.transaction {
                let f = try database.prepare("UPDATE files SET size = ?, mtime = ?, fingerprint = ? WHERE id = ?")
                defer { f.reset() }
                try f.bind([.int(size), .double(mtime.timeIntervalSince1970), .text(fingerprint), .int(fileID)])
                _ = try f.step()

                let old = try database.prepare("SELECT id, postscript_name FROM faces WHERE file_id = ? ORDER BY face_index")
                defer { old.reset() }
                try old.bind([.int(fileID)])
                var oldByName: [String: [Int64]] = [:]
                var oldIDs: [Int64] = []
                while try old.step() {
                    oldByName[old.text(1), default: []].append(old.int64(0))
                    oldIDs.append(old.int64(0))
                }
                old.reset()

                var matched: [(id: Int64, face: ParsedFace)] = []
                var fresh: [ParsedFace] = []
                for face in faces {
                    if let id = oldByName[face.postScriptName]?.first {
                        oldByName[face.postScriptName]?.removeFirst()
                        matched.append((id, face))
                    } else {
                        fresh.append(face)
                    }
                }
                let keep = Set(matched.map(\.id))
                for id in oldIDs where !keep.contains(id) {
                    let d = try database.prepare("DELETE FROM faces WHERE id = ?")
                    defer { d.reset() }
                    try d.bind([.int(id)])
                    _ = try d.step()
                }
                // Park surviving rows on unique negative indices so reindexing can't collide.
                try database.execute("UPDATE faces SET face_index = -id - 1 WHERE file_id = \(fileID)")
                let sets = Self.faceColumns.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + " = ?" }.joined(separator: ", ")
                for (id, face) in matched {
                    let u = try database.prepare("UPDATE faces SET \(sets) WHERE id = ?")
                    defer { u.reset() }
                    try u.bind(faceValues(face, fileID: fileID) + [.int(id)])
                    _ = try u.step()
                }
                for face in fresh { try insertFace(face, fileID: fileID) }
            }
        }
    }

    public func moveFile(fileID: Int64, toRelativePath: String, mtime: Date) throws {
        try database.withLock {
            let s = try database.prepare("UPDATE files SET relative_path = ?, mtime = ? WHERE id = ?")
            defer { s.reset() }
            try s.bind([.text(toRelativePath), .double(mtime.timeIntervalSince1970), .int(fileID)])
            _ = try s.step()
        }
    }

    public func deleteFiles(_ ids: [Int64]) throws {
        try database.withLock {
            try database.transaction {
                for id in ids {
                    let s = try database.prepare("DELETE FROM files WHERE id = ?")
                    defer { s.reset() }
                    try s.bind([.int(id)])
                    _ = try s.step()
                }
            }
        }
    }

    /// Number of faces in the given files carrying user data (a note, a tag, Quick Collection membership, or activation other than off).
    public func userDataFaceCount(fileIDs: [Int64]) throws -> Int {
        try database.withLock {
            var total = 0
            for id in fileIDs {
                let s = try database.prepare("SELECT COUNT(*) FROM faces WHERE file_id = ? AND (note IS NOT NULL OR activation != 0 OR EXISTS(SELECT 1 FROM face_tags WHERE face_id = faces.id) OR EXISTS(SELECT 1 FROM quick_collection WHERE face_id = faces.id))")
                defer { s.reset() }
                try s.bind([.int(id)])
                if try s.step() { total += Int(s.int64(0)) }
            }
            return total
        }
    }

    // MARK: Queries

    public func faceIDs(for query: LibraryQuery) throws -> [Int64] {
        try reader.withLock {
            let (sql, bindings) = query.sql(columns: "faces.id")
            let s = try reader.prepare(sql)
            defer { s.reset() }
            try s.bind(bindings)
            var out: [Int64] = []
            out.reserveCapacity(1024)
            while try s.step() { out.append(s.int64(0)) }
            return out
        }
    }

    /// `faceIDs(for:).count` without building the list: one `COUNT(*)` with no ORDER BY (sort is ignored).
    public func count(for query: LibraryQuery) throws -> Int {
        try reader.withLock {
            let (sql, bindings) = query.countSQL()
            let s = try reader.prepare(sql)
            defer { s.reset() }
            try s.bind(bindings)
            return try s.step() ? Int(s.int64(0)) : 0
        }
    }

    public func faceIDs(state: ActivationState) throws -> [Int64] {
        try reader.withLock {
            let s = try reader.prepare("SELECT id FROM faces WHERE activation = ? ORDER BY id")
            defer { s.reset() }
            try s.bind([.int(Int64(state.rawValue))])
            var out: [Int64] = []
            while try s.step() { out.append(s.int64(0)) }
            return out
        }
    }

    /// The given faces plus every other face stored in the same files (registration is per file).
    public func faceIDs(inSameFilesAs ids: [Int64]) throws -> [Int64] {
        try reader.withLock {
            let rowsByID = try rows(ids: ids)
            var fileIDs: [Int64] = []
            var seen = Set<Int64>()
            for id in ids {
                if let row = rowsByID[id], seen.insert(row.fileID).inserted { fileIDs.append(row.fileID) }
            }
            var out: [Int64] = []
            out.reserveCapacity(fileIDs.count)
            let s = try reader.prepare("SELECT id FROM faces WHERE file_id = ? ORDER BY face_index")
            defer { s.reset() }
            for fileID in fileIDs {
                s.reset()
                try s.bind([.int(fileID)])
                while try s.step() { out.append(s.int64(0)) }
            }
            return out
        }
    }

    /// For each PostScript name of a face currently on or temporary, the ids of the files holding such a face.
    public func activeFileIDsByPostScriptName() throws -> [String: Set<Int64>] {
        try reader.withLock {
            let s = try reader.prepare("SELECT DISTINCT postscript_name, file_id FROM faces WHERE activation != 0")
            defer { s.reset() }
            var out: [String: Set<Int64>] = [:]
            while try s.step() { out[s.text(0), default: []].insert(s.int64(1)) }
            return out
        }
    }

    /// Files holding at least one face in `states`, optionally limited to some locations.
    /// The URL is built from the location's last known path whether or not it is online.
    public func activeFiles(states: [ActivationState], locationIDs: [Int64]? = nil) throws -> [ActiveFile] {
        try reader.withLock {
            let sql = """
            SELECT files.id, faces.id, faces.activation, locations.id, locations.online, locations.last_known_path, files.relative_path
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE faces.activation != 0 ORDER BY files.id, faces.face_index
            """
            let s = try reader.prepare(sql)
            defer { s.reset() }
            let wanted = Set(states)
            let locs = locationIDs.map(Set.init)
            var byFile: [Int64: ActiveFile] = [:]
            var order: [Int64] = []
            while try s.step() {
                let loc = s.int64(3)
                if let locs, !locs.contains(loc) { continue }
                let fileID = s.int64(0)
                let activation = ActivationState(rawValue: Int(s.int64(2))) ?? .off
                if var f = byFile[fileID] {
                    f.faceIDs.append(s.int64(1)); f.states.insert(activation)
                    byFile[fileID] = f
                } else {
                    let base = URL(fileURLWithPath: s.text(5))
                    let rel = s.text(6)
                    byFile[fileID] = ActiveFile(fileID: fileID, locationID: loc, online: s.int64(4) != 0,
                                                url: rel.isEmpty ? base : base.appendingPathComponent(rel),
                                                faceIDs: [s.int64(1)], states: [activation])
                    order.append(fileID)
                }
            }
            return order.compactMap { byFile[$0] }.filter { !$0.states.isDisjoint(with: wanted) }
        }
    }

    private struct FamilyMember {
        var id: Int64
        var weight: Double, width: Double, slant: Double
        var isItalic: Bool
        var order: Int
    }

    public func families(for query: LibraryQuery) throws -> [FamilyGroup] {
        try reader.withLock {
            let eff = LibraryQuery.effectiveFamily
            let (sql, bindings) = query.sql(columns: "faces.id, \(eff), faces.weight, faces.width, faces.slant, faces.is_italic")
            let s = try reader.prepare(sql)
            defer { s.reset() }
            try s.bind(bindings)
            var order: [String] = []
            var names: [String: String] = [:]
            var members: [String: [FamilyMember]] = [:]
            var n = 0
            while try s.step() {
                let name = s.text(1)
                let key = name.lowercased()
                if names[key] == nil { names[key] = name; order.append(key) }
                members[key, default: []].append(
                    FamilyMember(id: s.int64(0), weight: s.double(2), width: s.double(3), slant: s.double(4), isItalic: s.int64(5) != 0, order: n))
                n += 1
            }

            var prefs: [String: Int64] = [:]
            let p = try reader.prepare("SELECT family_key, representative_face_id FROM family_prefs WHERE representative_face_id IS NOT NULL")
            defer { p.reset() }
            while try p.step() { prefs[p.text(0)] = p.int64(1) }

            return order.map { key in
                let faces = members[key]!.sorted {
                    ($0.weight, $0.width, $0.slant, $0.order) < ($1.weight, $1.width, $1.slant, $1.order)
                }
                let ids = faces.map(\.id)
                let rep: Int64
                if let pref = prefs[key], ids.contains(pref) {
                    rep = pref
                } else {
                    rep = faces.min { Self.score($0) < Self.score($1) }!.id
                }
                return FamilyGroup(id: key, name: names[key]!, faceIDs: ids, representativeID: rep)
            }
        }
    }

    /// Lower is better: upright first, then nearest weight 400, then nearest width 5.
    private static func score(_ m: FamilyMember) -> (Int, Double, Double) {
        (m.isItalic ? 1 : 0, abs(m.weight - 400), abs(m.width - 5))
    }

    /// Fixed chunk size so `rows(ids:)` uses a single cached statement; the last chunk is
    /// padded by repeating its final id (duplicates in `IN` are harmless).
    private static let rowsChunk = 500

    public func rows(ids: [Int64]) throws -> [Int64: FaceRow] {
        try reader.withLock {
            var out: [Int64: FaceRow] = [:]
            out.reserveCapacity(ids.count)
            let marks = Array(repeating: "?", count: Self.rowsChunk).joined(separator: ",")
            var start = 0
            while start < ids.count {
                var chunk = Array(ids[start..<min(start + Self.rowsChunk, ids.count)])
                start += chunk.count
                chunk += Array(repeating: chunk[chunk.count - 1], count: Self.rowsChunk - chunk.count)
                let s = try reader.prepare("""
                SELECT faces.id, faces.file_id, faces.face_index, faces.postscript_name, \(LibraryQuery.effectiveFamily), faces.style,
                  faces.full_name, faces.weight, faces.is_variable, files.format, faces.vendor, faces.version, faces.glyph_count,
                  faces.activation, faces.last_activated, locations.online, locations.last_known_path, files.relative_path, locations.id,
                  faces.scripts_bitmask, files.external_active, locations.kind
                FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
                WHERE faces.id IN (\(marks))
                """)
                defer { s.reset() }
                try s.bind(chunk.map { .int($0) })
                while try s.step() {
                    let online = s.int64(15) != 0
                    var url: URL?
                    if online {
                        let base = URL(fileURLWithPath: s.text(16))
                        let rel = s.text(17)
                        url = rel.isEmpty ? base : base.appendingPathComponent(rel)
                    }
                    let row = FaceRow(
                        id: s.int64(0), fileID: s.int64(1), faceIndex: Int(s.int64(2)), postScriptName: s.text(3),
                        family: s.text(4), style: s.text(5), fullName: s.text(6), weight: s.double(7),
                        isVariable: s.int64(8) != 0, format: s.text(9),
                        vendor: s.isNull(10) ? nil : s.text(10), version: s.isNull(11) ? nil : s.text(11),
                        glyphCount: Int(s.int64(12)), activation: ActivationState(rawValue: Int(s.int64(13))) ?? .off,
                        lastActivated: s.isNull(14) ? nil : Date(timeIntervalSince1970: s.double(14)),
                        online: online, fileURL: url, locationID: s.int64(18), scriptsBitmask: s.int64(19),
                        externalActive: s.int64(20) != 0, locationKind: LocationKind(rawValue: Int(s.int64(21))) ?? .folder)
                    out[row.id] = row
                }
            }
            return out
        }
    }

    /// The family named `family`: the faces that `families(for:)` groups with it (effective family names equal
    /// after Swift's `lowercased()`, compared with canonical equivalence, so case differences outside ASCII and
    /// NFC/NFD spellings match), in family order (weight, width, slant), and its representative, chosen as in
    /// `families(for:)`. Private system faces are left out, like everywhere else; system faces too unless
    /// `includeSystem`. Nil when no face matches.
    public func family(named family: String, includeSystem: Bool) throws -> FamilyGroup? {
        try reader.withLock {
            let key = family.lowercased()
            // SQLite's NOCASE folds ASCII only and compares bytes: find the matching spellings in Swift.
            let n = try reader.prepare("SELECT DISTINCT \(LibraryQuery.effectiveFamily) FROM faces")
            defer { n.reset() }
            var spellings: [String] = []
            while try n.step() {
                let name = n.text(0)
                if name.lowercased() == key { spellings.append(name) }
            }
            n.reset()
            guard !spellings.isEmpty else { return nil }

            let s = try reader.prepare("""
            SELECT faces.id, \(LibraryQuery.effectiveFamily), faces.weight, faces.width, faces.slant, faces.is_italic
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE \(LibraryQuery.effectiveFamily) = ?1 AND \(LibraryQuery.publicFaceClause) AND (?2 != 0 OR locations.kind != 2)
            """)
            defer { s.reset() }
            var members: [(member: FamilyMember, name: String)] = []
            for spelling in spellings {
                s.reset()
                try s.bind([.text(spelling), .int(includeSystem ? 1 : 0)])
                while try s.step() {
                    members.append((FamilyMember(id: s.int64(0), weight: s.double(2), width: s.double(3), slant: s.double(4),
                                                 isItalic: s.int64(5) != 0, order: 0), s.text(1)))
                }
            }
            members.sort { ($0.member.weight, $0.member.width, $0.member.slant, $0.member.id)
                < ($1.member.weight, $1.member.width, $1.member.slant, $1.member.id) }
            guard let first = members.first,
                  let best = members.min(by: { Self.score($0.member) < Self.score($1.member) }) else { return nil }
            let ids = members.map(\.member.id)

            // Preferences are keyed by a lowercased spelling; compare them like the list does (Swift equality).
            let p = try reader.prepare("SELECT family_key, representative_face_id FROM family_prefs WHERE representative_face_id IS NOT NULL")
            defer { p.reset() }
            var rep = best.member.id
            while try p.step() {
                // The last matching row wins, as in the dictionary `families(for:)` builds.
                if p.text(0) == key { rep = ids.contains(p.int64(1)) ? p.int64(1) : best.member.id }
            }
            return FamilyGroup(id: first.name.lowercased(), name: first.name, faceIDs: ids, representativeID: rep)
        }
    }

    /// Every indexed column of one face, for the Info tab. Nil when the face no longer exists.
    public func faceInfo(id: Int64) throws -> FaceInfo? {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT faces.id, faces.face_index, faces.postscript_name, faces.full_name, \(LibraryQuery.effectiveFamily), faces.family,
              faces.style, faces.version, faces.vendor, faces.designer, files.format, locations.last_known_path, files.relative_path,
              locations.online, files.size, files.added_at, faces.glyph_count, faces.weight, faces.width, faces.slant, faces.is_italic,
              faces.units_per_em, faces.ascender, faces.descender, faces.cap_height, faces.x_height, faces.fs_type, faces.outline_type,
              faces.is_color, faces.is_bitmap, faces.is_variable, faces.axes_json, faces.has_gsub, faces.has_gpos, faces.note,
              faces.activation, faces.last_activated, locations.kind, files.external_active
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE faces.id = ?
            """)
            defer { s.reset() }
            try s.bind([.int(id)])
            guard try s.step() else { return nil }
            func optText(_ col: Int32) -> String? { s.isNull(col) ? nil : s.text(col) }
            func optDate(_ col: Int32) -> Date? { s.isNull(col) ? nil : Date(timeIntervalSince1970: s.double(col)) }
            let base = URL(fileURLWithPath: s.text(11))
            let rel = s.text(12)
            return FaceInfo(
                id: s.int64(0), faceIndex: Int(s.int64(1)), postScriptName: s.text(2), fullName: s.text(3),
                family: s.text(4), fontFamily: s.text(5), style: s.text(6),
                version: optText(7), vendor: optText(8), designer: optText(9), format: s.text(10),
                fileURL: rel.isEmpty ? base : base.appendingPathComponent(rel), online: s.int64(13) != 0,
                fileSize: s.int64(14), addedAt: optDate(15), glyphCount: Int(s.int64(16)),
                weight: s.double(17), width: s.double(18), slant: s.double(19), isItalic: s.int64(20) != 0,
                metrics: FaceMetrics(unitsPerEm: Int(s.int64(21)), ascender: s.double(22), descender: s.double(23),
                                     capHeight: s.double(24), xHeight: s.double(25)),
                fsType: s.isNull(26) ? nil : Int(s.int64(26)),
                outlineType: OutlineType(rawValue: s.text(27)) ?? .unknown,
                isColor: s.int64(28) != 0, isBitmap: s.int64(29) != 0, isVariable: s.int64(30) != 0,
                axes: VariationAxis.decode(json: optText(31)), hasGSUB: s.int64(32) != 0, hasGPOS: s.int64(33) != 0,
                note: optText(34), activation: ActivationState(rawValue: Int(s.int64(35))) ?? .off,
                lastActivated: optDate(36), locationKind: LocationKind(rawValue: Int(s.int64(37))) ?? .folder,
                externalActive: s.int64(38) != 0)
        }
    }

    // MARK: Mutations

    /// Activating also clears the file's external flag: a file Fontory registered is Fontory's own.
    public func setActivation(faceIDs: [Int64], state: ActivationState, at date: Date) throws {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("UPDATE faces SET activation = ?1, last_activated = CASE WHEN ?1 != 0 THEN ?2 ELSE last_activated END WHERE id = ?3")
                defer { s.reset() }
                for id in faceIDs {
                    s.reset()
                    try s.bind([.int(Int64(state.rawValue)), .double(date.timeIntervalSince1970), .int(id)])
                    _ = try s.step()
                }
                guard state != .off else { return }
                let x = try database.prepare("UPDATE files SET external_active = 0 WHERE external_active != 0 AND id = (SELECT file_id FROM faces WHERE id = ?)")
                defer { x.reset() }
                for id in faceIDs {
                    x.reset()
                    try x.bind([.int(id)])
                    _ = try x.step()
                }
            }
        }
    }

    // MARK: External activity

    /// Sets or clears the "registered by someone other than Fontory" flag of files. Setting it skips, in the same
    /// statement, any file with a face Fontory has on: Fontory's own registrations are never external, even when
    /// an activation lands between the inventory's read and this write.
    public func setExternalActive(fileIDs: [Int64], _ active: Bool) throws {
        try database.withLock {
            try database.transaction {
                let sql = active
                    ? "UPDATE files SET external_active = 1 WHERE id = ? AND NOT EXISTS (SELECT 1 FROM faces WHERE faces.file_id = files.id AND faces.activation != 0)"
                    : "UPDATE files SET external_active = 0 WHERE id = ?"
                let s = try database.prepare(sql)
                defer { s.reset() }
                for id in fileIDs {
                    s.reset()
                    try s.bind([.int(id)])
                    _ = try s.step()
                }
            }
        }
    }

    /// Every indexed file with what the inventory needs to match it against the registered fonts.
    public func inventoryFiles() throws -> [InventoryFile] {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT files.id, files.location_id, files.relative_path, files.external_active,
              EXISTS(SELECT 1 FROM faces WHERE faces.file_id = files.id AND faces.activation != 0)
            FROM files ORDER BY files.id
            """)
            defer { s.reset() }
            var out: [InventoryFile] = []
            while try s.step() {
                out.append(InventoryFile(fileID: s.int64(0), locationID: s.int64(1), relativePath: s.text(2),
                                         externalActive: s.int64(3) != 0, fontoryActive: s.int64(4) != 0))
            }
            return out
        }
    }

    /// Deletes auto-indexed locations that hold no file any more. Returns how many were deleted.
    @discardableResult
    public func deleteEmptyAutoLocations() throws -> Int {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("""
                DELETE FROM locations WHERE auto_indexed != 0 AND NOT EXISTS (SELECT 1 FROM files WHERE files.location_id = locations.id)
                RETURNING id
                """)
                defer { s.reset() }
                var removed = Set<Int64>()
                while try s.step() { removed.insert(s.int64(0)) }
                s.reset()
                try tombstoneRuleConditions(field: .location, ids: removed)
                return removed.count
            }
        }
    }

    public func setRepresentative(familyKey: String, faceID: Int64?) throws {
        try database.withLock {
            let s = try database.prepare("""
            INSERT INTO family_prefs(family_key, representative_face_id) VALUES(?,?)
            ON CONFLICT(family_key) DO UPDATE SET representative_face_id = excluded.representative_face_id
            """)
            defer { s.reset() }
            try s.bind([.text(familyKey), faceID.map { .int($0) } ?? .null])
            _ = try s.step()
        }
    }

    /// Distinct next path component under `parent` (nil = location root), sorted case-insensitively.
    public func subfolders(locationID: Int64, parent: String?) throws -> [String] {
        try reader.withLock {
            let s: Statement
            if let parent {
                s = try reader.prepare("""
                SELECT DISTINCT substr(rest, 1, instr(rest, '/') - 1) AS name FROM (
                  SELECT substr(relative_path, length(?1) + 2) AS rest FROM files
                  WHERE location_id = ?2 AND substr(relative_path, 1, length(?1) + 1) = ?1 || '/')
                WHERE instr(rest, '/') > 0 ORDER BY name COLLATE NOCASE
                """)
                try s.bind([.text(parent), .int(locationID)])
            } else {
                s = try reader.prepare("""
                SELECT DISTINCT substr(relative_path, 1, instr(relative_path, '/') - 1) AS name FROM files
                WHERE location_id = ? AND instr(relative_path, '/') > 0 ORDER BY name COLLATE NOCASE
                """)
                try s.bind([.int(locationID)])
            }
            defer { s.reset() }
            var out: [String] = []
            while try s.step() { out.append(s.text(0)) }
            return out
        }
    }

    // MARK: App support

    /// Points a location at a new place. Its files keep their ids (and activation) where relative paths match.
    public func relinkLocation(_ id: Int64, volumeUUID: String, relativePath: String, displayName: String, lastKnownPath: String) throws {
        try database.withLock {
            let s = try database.prepare("""
            UPDATE locations SET volume_uuid = ?, relative_path = ?, display_name = ?, last_known_path = ?, online = 1 WHERE id = ?
            """)
            defer { s.reset() }
            try s.bind([.text(volumeUUID), .text(relativePath), .text(displayName), .text(lastKnownPath), .int(id)])
            _ = try s.step()
        }
    }

    /// Face counts grouped by activation, online state, location and whether the file is in the latest import.
    public func faceCountGroups() throws -> [FaceCountGroup] {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT faces.activation, locations.online, files.location_id, locations.kind,
              files.import_batch = (SELECT MAX(import_batch) FROM files), COUNT(*), files.external_active != 0
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE \(LibraryQuery.publicFaceClause)
            GROUP BY 1, 2, 3, 4, 5, 7
            """)
            defer { s.reset() }
            var out: [FaceCountGroup] = []
            while try s.step() {
                out.append(FaceCountGroup(
                    activation: ActivationState(rawValue: Int(s.int64(0))) ?? .off, online: s.int64(1) != 0,
                    locationID: s.int64(2), kind: LocationKind(rawValue: Int(s.int64(3))) ?? .folder,
                    inLatestImport: s.int64(4) != 0, count: Int(s.int64(5)), externalActive: s.int64(6) != 0))
            }
            return out
        }
    }
}

public struct FaceCountGroup: Sendable, Hashable {
    public var activation: ActivationState
    public var online: Bool
    public var locationID: Int64
    public var kind: LocationKind
    public var inLatestImport: Bool
    public var count: Int
    public var externalActive: Bool = false
}

/// An indexed file as `SystemFontInventory` sees it.
public struct InventoryFile: Sendable, Hashable {
    public var fileID: Int64
    public var locationID: Int64
    public var relativePath: String
    public var externalActive: Bool
    /// At least one face is on (or temporary) in Fontory: the file's registration is Fontory's own.
    public var fontoryActive: Bool
}
