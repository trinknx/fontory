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

    /// Cascades to subtags and `face_tags` (foreign keys are on for the write connection).
    public func deleteTag(_ id: Int64) throws {
        try database.withLock {
            let s = try database.prepare("DELETE FROM tags WHERE id = ?")
            defer { s.reset() }
            try s.bind([.int(id)])
            _ = try s.step()
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

    private func checkSiblingName(_ name: String, parentID: Int64?, excluding: Int64?) throws {
        let s = try database.prepare("SELECT 1 FROM tags WHERE parent_id IS ? AND name = ? COLLATE NOCASE AND id != ? LIMIT 1")
        defer { s.reset() }
        try s.bind([parentID.map { .int($0) } ?? .null, .text(name), .int(excluding ?? -1)])
        if try s.step() { throw TagError.duplicateName }
    }
}
