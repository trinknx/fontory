import Foundation

/// Tags, the Quick Collection and notes. All of it is keyed by face id, which survives moves, renames,
/// in-place re-parses (see `replaceFaces`) and unmounts; rows go away only when the face itself is deleted.
extension FontStore {
    // MARK: Tags

    public func tags() throws -> [TagRecord] {
        try reader.withLock {
            let s = try reader.prepare("SELECT id, parent_id, name, kind, rule_json, created_at FROM tags ORDER BY id")
            defer { s.reset() }
            var out: [TagRecord] = []
            while try s.step() {
                out.append(TagRecord(id: s.int64(0), parentID: s.isNull(1) ? nil : s.int64(1), name: s.text(2),
                                     kind: TagKind(rawValue: Int(s.int64(3))) ?? .tag,
                                     ruleJSON: s.isNull(4) ? nil : s.text(4),
                                     createdAt: Date(timeIntervalSince1970: s.double(5))))
            }
            return out
        }
    }

    public func createTag(name: String, parentID: Int64?, kind: TagKind = .tag, ruleJSON: String? = nil) throws -> Int64 {
        let name = try Self.cleanTagName(name)
        return try database.withLock {
            try database.transaction {
                if let parentID { guard try tagLookup(parentID) != nil else { throw TagError.notFound } }
                try checkSiblingName(name, parentID: parentID, excluding: nil)
                let s = try database.prepare("INSERT INTO tags(parent_id, name, kind, rule_json, created_at) VALUES(?,?,?,?,?)")
                defer { s.reset() }
                try s.bind([parentID.map { .int($0) } ?? .null, .text(name), .int(Int64(kind.rawValue)),
                            ruleJSON.map { .text($0) } ?? .null, .double(Date().timeIntervalSince1970)])
                _ = try s.step()
                return database.lastInsertRowID
            }
        }
    }

    public func renameTag(_ id: Int64, to name: String) throws {
        let name = try Self.cleanTagName(name)
        try database.withLock {
            try database.transaction {
                guard let tag = try tagLookup(id) else { throw TagError.notFound }
                try checkSiblingName(name, parentID: tag.parentID, excluding: id)
                let s = try database.prepare("UPDATE tags SET name = ? WHERE id = ?")
                defer { s.reset() }
                try s.bind([.text(name), .int(id)])
                _ = try s.step()
            }
        }
    }

    public func moveTag(_ id: Int64, toParent parentID: Int64?) throws {
        try database.withLock {
            try database.transaction {
                guard let tag = try tagLookup(id) else { throw TagError.notFound }
                if let parentID {
                    guard try tagLookup(parentID) != nil else { throw TagError.notFound }
                    // Walk up from the new parent; meeting `id` means the parent is the tag itself or a descendant.
                    var cursor: Int64? = parentID
                    while let c = cursor {
                        if c == id { throw TagError.cycle }
                        cursor = try tagLookup(c)?.parentID
                    }
                }
                try checkSiblingName(tag.name, parentID: parentID, excluding: id)
                let s = try database.prepare("UPDATE tags SET parent_id = ? WHERE id = ?")
                defer { s.reset() }
                try s.bind([parentID.map { .int($0) } ?? .null, .int(id)])
                _ = try s.step()
            }
        }
    }

    public func setTagRule(_ id: Int64, ruleJSON: String) throws {
        try database.withLock {
            guard try tagLookup(id) != nil else { throw TagError.notFound }
            let s = try database.prepare("UPDATE tags SET rule_json = ? WHERE id = ?")
            defer { s.reset() }
            try s.bind([.text(ruleJSON), .int(id)])
            _ = try s.step()
        }
    }

    /// Cascades to subtags and `face_tags` (foreign keys are on for the write connection). Tag ids can be reused
    /// (no AUTOINCREMENT), so every smart rule naming a deleted tag (the whole subtree) is pointed at
    /// `SmartRule.deletedID` in the same transaction: it keeps matching nothing after a new tag takes the id.
    public func deleteTag(_ id: Int64) throws {
        try database.withLock {
            try database.transaction {
                let d = try database.prepare(LibraryQuery.descendantsByID)
                defer { d.reset() }
                try d.bind([.int(id)])
                var removed = Set<Int64>()
                while try d.step() { removed.insert(d.int64(0)) }
                d.reset()
                let s = try database.prepare("DELETE FROM tags WHERE id = ?")
                defer { s.reset() }
                try s.bind([.int(id)])
                _ = try s.step()
                try tombstoneRuleConditions(field: .tag, ids: removed)
            }
        }
    }

    public func addTag(_ tagID: Int64, toFaces faceIDs: [Int64]) throws {
        try database.withLock {
            try database.transaction {
                guard try tagLookup(tagID) != nil else { throw TagError.notFound }
                let s = try database.prepare("INSERT OR IGNORE INTO face_tags(face_id, tag_id) SELECT id, ? FROM faces WHERE id = ?")
                defer { s.reset() }
                for face in faceIDs {
                    try s.bind([.int(tagID), .int(face)])
                    _ = try s.step()
                    s.reset()
                }
            }
        }
    }

    public func removeTag(_ tagID: Int64, fromFaces faceIDs: [Int64]) throws {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("DELETE FROM face_tags WHERE tag_id = ? AND face_id = ?")
                defer { s.reset() }
                for face in faceIDs {
                    try s.bind([.int(tagID), .int(face)])
                    _ = try s.step()
                    s.reset()
                }
            }
        }
    }

    /// Direct tags per face; faces without tags are absent from the result.
    public func tagIDs(forFaces faceIDs: [Int64]) throws -> [Int64: Set<Int64>] {
        try reader.withLock {
            let s = try reader.prepare("SELECT tag_id FROM face_tags WHERE face_id = ?")
            defer { s.reset() }
            var out: [Int64: Set<Int64>] = [:]
            for face in faceIDs {
                try s.bind([.int(face)])
                var set = Set<Int64>()
                while try s.step() { set.insert(s.int64(0)) }
                s.reset()
                if !set.isEmpty { out[face] = set }
            }
            return out
        }
    }

    // MARK: Quick Collection

    public func setQuickCollection(_ faceIDs: [Int64], included: Bool, at date: Date) throws {
        try database.withLock {
            try database.transaction {
                let sql = included
                    ? "INSERT OR IGNORE INTO quick_collection(face_id, added_at) SELECT id, ? FROM faces WHERE id = ?"
                    : "DELETE FROM quick_collection WHERE face_id = ?"
                let s = try database.prepare(sql)
                defer { s.reset() }
                for face in faceIDs {
                    try s.bind(included ? [.double(date.timeIntervalSince1970), .int(face)] : [.int(face)])
                    _ = try s.step()
                    s.reset()
                }
            }
        }
    }

    public func quickCollectionFaceIDs() throws -> Set<Int64> {
        try reader.withLock {
            let s = try reader.prepare("SELECT face_id FROM quick_collection")
            defer { s.reset() }
            var out = Set<Int64>()
            while try s.step() { out.insert(s.int64(0)) }
            return out
        }
    }

    public func clearQuickCollection() throws {
        try database.withLock { try database.execute("DELETE FROM quick_collection") }
    }

    // MARK: Counts

    /// Sidebar counts for tags, styles, untagged and the Quick Collection. Each equals the matching
    /// `LibraryQuery.Scope` result size for the same `includeSystem`.
    public func organizationCounts(includeSystem: Bool) throws -> OrganizationCounts {
        let join = "FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id"
        let visible = LibraryQuery.publicFaceClause + (includeSystem ? "" : " AND locations.kind != 2")
        return try reader.withLock {
            var out = OrganizationCounts()
            func scalar(_ extra: String) throws -> Int {
                let s = try reader.prepare("SELECT COUNT(*) \(join) WHERE \(visible) AND \(extra)")
                defer { s.reset() }
                _ = try s.step()
                return Int(s.int64(0))
            }
            out.untagged = try scalar("NOT EXISTS (SELECT 1 FROM face_tags JOIN tags ON tags.id = face_tags.tag_id WHERE face_tags.face_id = faces.id AND tags.kind = 0)")
            out.quickCollection = try scalar("faces.id IN (SELECT face_id FROM quick_collection)")

            out.perStyle = try styleCounts(includeSystem: includeSystem)

            // One pass over the visible assignments: each face counts once for every tag it carries or inherits.
            var parent: [Int64: Int64?] = [:]
            for t in try tags() { parent[t.id] = t.parentID; if t.kind == .tag { out.perTag[t.id] = 0 } }
            let pairs = try reader.prepare("SELECT face_tags.face_id, face_tags.tag_id \(join.replacingOccurrences(of: "FROM faces", with: "FROM face_tags JOIN faces ON faces.id = face_tags.face_id")) WHERE \(visible) ORDER BY face_tags.face_id")
            defer { pairs.reset() }
            var currentFace: Int64? = nil
            var seen = Set<Int64>()
            while try pairs.step() {
                let face = pairs.int64(0)
                if face != currentFace { currentFace = face; seen.removeAll(keepingCapacity: true) }
                var cursor: Int64? = pairs.int64(1)
                while let c = cursor, seen.insert(c).inserted {
                    if out.perTag[c] != nil { out.perTag[c]! += 1 }
                    cursor = parent[c] ?? nil
                }
            }
            return out
        }
    }

    /// Faces per style class (`OrganizationCounts.perStyle` alone), for reloads that follow the style backfill.
    public func styleCounts(includeSystem: Bool) throws -> [StyleClass: Int] {
        let visible = LibraryQuery.publicFaceClause + (includeSystem ? "" : " AND locations.kind != 2")
        return try reader.withLock {
            let styles = try reader.prepare("SELECT faces.style_class, COUNT(*) \(LibraryQuery.fromJoin) WHERE \(visible) GROUP BY 1")
            defer { styles.reset() }
            var out: [StyleClass: Int] = [:]
            while try styles.step() {
                if let c = StyleClass(rawValue: Int(styles.int64(0))) { out[c] = Int(styles.int64(1)) }
            }
            return out
        }
    }

    // MARK: Notes

    /// nil or blank clears the note. The `faces_au` trigger keeps the FTS index in sync.
    public func setNote(_ note: String?, faceID: Int64) throws {
        let value: SQLValue = (note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? .null : .text(note!)
        try database.withLock {
            let s = try database.prepare("UPDATE faces SET note = ? WHERE id = ?")
            defer { s.reset() }
            try s.bind([value, .int(faceID)])
            _ = try s.step()
        }
    }

    // MARK: Helpers (call inside `database.withLock`)

    /// Rewrites every smart rule condition on `field` whose value names one of `ids` to `SmartRule.deletedID`.
    /// Rules that do not decode (from a newer version) are left as they are. Call inside a write transaction.
    func tombstoneRuleConditions(field: SmartRule.Field, ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }
        let sel = try database.prepare("SELECT id, rule_json FROM tags WHERE kind = 1 AND rule_json IS NOT NULL")
        defer { sel.reset() }
        var updates: [(Int64, String)] = []
        while try sel.step() {
            guard var rule = SmartRule.decode(sel.text(1)) else { continue }
            var changed = false
            for i in rule.conditions.indices where rule.conditions[i].field == field {
                if case .int(let v) = rule.conditions[i].value, ids.contains(v) {
                    rule.conditions[i].value = .int(SmartRule.deletedID)
                    changed = true
                }
            }
            if changed { updates.append((sel.int64(0), rule.encoded())) }
        }
        sel.reset()
        let up = try database.prepare("UPDATE tags SET rule_json = ? WHERE id = ?")
        defer { up.reset() }
        for (id, json) in updates {
            try up.bind([.text(json), .int(id)])
            _ = try up.step()
            up.reset()
        }
    }

    private static func cleanTagName(_ name: String) throws -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw TagError.emptyName }
        return t
    }

    private func tagLookup(_ id: Int64) throws -> (parentID: Int64?, name: String)? {
        let s = try database.prepare("SELECT parent_id, name FROM tags WHERE id = ?")
        defer { s.reset() }
        try s.bind([.int(id)])
        guard try s.step() else { return nil }
        return (s.isNull(0) ? nil : s.int64(0), s.text(1))
    }

    /// SQLite's NOCASE is ASCII-only, so siblings are compared after Unicode case folding in Swift.
    private func checkSiblingName(_ name: String, parentID: Int64?, excluding: Int64?) throws {
        let s = try database.prepare("SELECT name FROM tags WHERE parent_id IS ? AND id != ?")
        defer { s.reset() }
        try s.bind([parentID.map { .int($0) } ?? .null, .int(excluding ?? -1)])
        let folded = TagName.fold(name)
        while try s.step() {
            if TagName.fold(s.text(0)) == folded { throw TagError.duplicateName }
        }
    }
}

// MARK: Style classes

extension FontStore {
    /// Online faces classified under an older classifier version (or never), oldest id first, with ids above
    /// `afterID`. Faces on an offline location are left alone until it comes back.
    public func facesNeedingClassification(limit: Int, afterID: Int64 = 0) throws -> [(faceID: Int64, url: URL, faceIndex: Int)] {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT faces.id, locations.last_known_path, files.relative_path, faces.face_index
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE faces.class_version < ? AND locations.online = 1 AND faces.id > ? ORDER BY faces.id LIMIT ?
            """)
            defer { s.reset() }
            try s.bind([.int(Int64(StyleClassifier.version)), .int(afterID), .int(Int64(limit))])
            var out: [(faceID: Int64, url: URL, faceIndex: Int)] = []
            while try s.step() {
                let base = URL(fileURLWithPath: s.text(1))
                let rel = s.text(2)
                out.append((s.int64(0), rel.isEmpty ? base : base.appendingPathComponent(rel), Int(s.int64(3))))
            }
            return out
        }
    }

    public func countFacesNeedingClassification() throws -> Int {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT COUNT(*) FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE faces.class_version < ? AND locations.online = 1
            """)
            defer { s.reset() }
            try s.bind([.int(Int64(StyleClassifier.version))])
            return try s.step() ? Int(s.int64(0)) : 0
        }
    }

    /// Writes classes and their classifier version in one transaction.
    public func setStyleClasses(_ classes: [(faceID: Int64, styleClass: StyleClass)], version: Int) throws {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("UPDATE faces SET style_class = ?, class_version = ? WHERE id = ?")
                defer { s.reset() }
                for item in classes {
                    try s.bind([.int(Int64(item.styleClass.rawValue)), .int(Int64(version)), .int(item.faceID)])
                    _ = try s.step()
                    s.reset()
                }
            }
        }
    }
}

// MARK: Face backfill

extension FontStore {
    private static let backfillWhere = "(faces.class_version < ? OR faces.meta_version < ?) AND locations.online = 1"

    private var backfillVersions: [SQLValue] { [.int(Int64(StyleClassifier.version)), .int(Int64(FaceMetadata.version))] }

    /// Online faces whose style class or metadata is older than the current version (or missing), oldest id first,
    /// with ids above `afterID`. Faces on an offline location wait until it comes back.
    public func facesNeedingBackfill(limit: Int, afterID: Int64) throws -> [(faceID: Int64, url: URL, faceIndex: Int)] {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT faces.id, locations.last_known_path, files.relative_path, faces.face_index
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE \(Self.backfillWhere) AND faces.id > ? ORDER BY faces.id LIMIT ?
            """)
            defer { s.reset() }
            try s.bind(backfillVersions + [.int(afterID), .int(Int64(limit))])
            var out: [(faceID: Int64, url: URL, faceIndex: Int)] = []
            while try s.step() {
                let base = URL(fileURLWithPath: s.text(1))
                let rel = s.text(2)
                out.append((s.int64(0), rel.isEmpty ? base : base.appendingPathComponent(rel), Int(s.int64(3))))
            }
            return out
        }
    }

    public func countFacesNeedingBackfill() throws -> Int {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT COUNT(*) FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE \(Self.backfillWhere)
            """)
            defer { s.reset() }
            try s.bind(backfillVersions)
            return try s.step() ? Int(s.int64(0)) : 0
        }
    }

    /// Writes each face's style class and metadata, stamped with the current versions, in one transaction.
    public func setBackfillResults(_ results: [(faceID: Int64, styleClass: StyleClass, metadata: FaceMetadata)]) throws {
        try database.withLock {
            try database.transaction {
                let s = try database.prepare("""
                UPDATE faces SET style_class = ?, class_version = ?, features = ?, figure_style = ?, meta_version = ? WHERE id = ?
                """)
                defer { s.reset() }
                for item in results {
                    try s.bind([.int(Int64(item.styleClass.rawValue)), .int(Int64(StyleClassifier.version)),
                                .text(FaceMetadata.featuresText(item.metadata.features)), .int(Int64(item.metadata.figureStyle.rawValue)),
                                .int(Int64(FaceMetadata.version)), .int(item.faceID)])
                    _ = try s.step()
                    s.reset()
                    try writeCoverage(faceID: item.faceID, item.metadata)
                }
            }
        }
    }
}
