import Foundation

/// Family-name overrides (`faces.custom_family`). Font files are never touched; the override only changes how
/// Fontory groups and shows the face. Family keys are the lowercased effective name, as in `families(for:)`.
extension FontStore {
    /// Sets (or clears) the custom family of the given faces and returns each face's previous value, for undo.
    /// Per face, nil, a blank name or a name equal to the face's own `family` stores NULL. Representatives that
    /// moved into a family without one follow the rename.
    @discardableResult
    public func setCustomFamily(_ name: String?, faceIDs: [Int64]) throws -> [Int64: String?] {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try database.withLock {
            try database.transaction {
                var previous: [Int64: String?] = [:]
                var updates: [Int64: String?] = [:]
                var changesAnything = false
                for id in Set(faceIDs).sorted() {
                    guard let (family, custom) = try familyColumns(id) else { continue }
                    previous[id] = custom
                    let new: String? = (trimmed.isEmpty || trimmed == family) ? nil : trimmed
                    updates[id] = new
                    if new != custom { changesAnything = true }
                }
                // A no-op returns nothing, so the caller keeps its previous undo.
                guard changesAnything else { return [:] }
                try applyCustomFamilies(updates)
                return previous
            }
        }
    }

    /// Puts back the values returned by `setCustomFamily` / `clearCustomFamilies` (one-level undo).
    public func restoreCustomFamilies(_ previous: [Int64: String?]) throws {
        try database.withLock {
            try database.transaction {
                try applyCustomFamilies(previous)
            }
        }
    }

    /// Clears the override of every given face that has one; faces without an override are left alone.
    /// Returns the previous values of the faces it changed.
    @discardableResult
    public func clearCustomFamilies(faceIDs: [Int64]) throws -> [Int64: String?] {
        try database.withLock {
            try database.transaction {
                var previous: [Int64: String?] = [:]
                var updates: [Int64: String?] = [:]
                for id in Set(faceIDs).sorted() {
                    guard let (_, custom) = try familyColumns(id), let custom else { continue }
                    previous[id] = custom
                    updates[id] = .some(nil)
                }
                try applyCustomFamilies(updates)
                return previous
            }
        }
    }

    /// Faces outside `excluding` whose effective family equals `name` (trimmed, case-insensitive): the clash check.
    public func existingFamilyFaceIDs(named name: String, excluding faceIDs: Set<Int64>) throws -> [Int64] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        return try reader.withLock {
            let s = try reader.prepare("SELECT id, \(LibraryQuery.effectiveFamily) FROM faces ORDER BY id")
            defer { s.reset() }
            var out: [Int64] = []
            while try s.step() {
                let id = s.int64(0)
                if !faceIDs.contains(id), s.text(1).lowercased() == key { out.append(id) }
            }
            return out
        }
    }

    /// Distinct original `family` values of those faces that carry a custom name, sorted.
    public func originalFamilies(faceIDs: [Int64]) throws -> [String] {
        try reader.withLock {
            let s = try reader.prepare("SELECT family FROM faces WHERE id = ? AND custom_family IS NOT NULL")
            defer { s.reset() }
            var out = Set<String>()
            for id in Set(faceIDs) {
                s.reset()
                try s.bind([.int(id)])
                if try s.step() { out.insert(s.text(0)) }
            }
            return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    /// Every edited family: its key (the lowercased custom name) mapped to the distinct original `family` values of
    /// the faces carrying that custom name, sorted. Drives the "edited" mark on cards and the family page.
    public func editedFamilies() throws -> [String: [String]] {
        try reader.withLock {
            let s = try reader.prepare("SELECT custom_family, family FROM faces WHERE custom_family IS NOT NULL")
            defer { s.reset() }
            var out: [String: Set<String>] = [:]
            while try s.step() { out[s.text(0).lowercased(), default: []].insert(s.text(1)) }
            return out.mapValues { $0.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
        }
    }

    // MARK: Private (call inside `database.withLock` + a transaction)

    private func familyColumns(_ id: Int64) throws -> (String, String?)? {
        let s = try database.prepare("SELECT family, custom_family FROM faces WHERE id = ?")
        defer { s.reset() }
        try s.bind([.int(id)])
        guard try s.step() else { return nil }
        return (s.text(0), s.isNull(1) ? nil : s.text(1))
    }

    private func effectiveKey(_ id: Int64) throws -> String? {
        let s = try database.prepare("SELECT \(LibraryQuery.effectiveFamily) FROM faces WHERE id = ?")
        defer { s.reset() }
        try s.bind([.int(id)])
        return try s.step() ? s.text(0).lowercased() : nil
    }

    /// Writes the new values and then moves representatives that left their family.
    private func applyCustomFamilies(_ updates: [Int64: String?]) throws {
        var oldKeys = Set<String>()
        for id in updates.keys { if let k = try effectiveKey(id) { oldKeys.insert(k) } }
        let set = try database.prepare("UPDATE faces SET custom_family = ? WHERE id = ?")
        for (id, value) in updates {
            set.reset()
            try set.bind([value.map { .text($0) } ?? .null, .int(id)])
            _ = try set.step()
            set.reset()
        }
        let pref = try database.prepare("SELECT representative_face_id FROM family_prefs WHERE family_key = ?")
        for key in oldKeys.sorted() {
            pref.reset()
            try pref.bind([.text(key)])
            let rep: Int64? = try pref.step() && !pref.isNull(0) ? pref.int64(0) : nil
            pref.reset()
            guard let rep, let newKey = try effectiveKey(rep), newKey != key else { continue }
            let has = try database.prepare("SELECT 1 FROM family_prefs WHERE family_key = ? AND representative_face_id IS NOT NULL")
            try has.bind([.text(newKey)])
            let taken = try has.step()
            has.reset()
            if !taken {
                let up = try database.prepare("""
                INSERT INTO family_prefs(family_key, representative_face_id) VALUES(?,?)
                ON CONFLICT(family_key) DO UPDATE SET representative_face_id = excluded.representative_face_id
                """)
                try up.bind([.text(newKey), .int(rep)])
                _ = try up.step()
                up.reset()
            }
            // The old family no longer contains that face.
            let del = try database.prepare("DELETE FROM family_prefs WHERE family_key = ?")
            try del.bind([.text(key)])
            _ = try del.step()
            del.reset()
        }
    }
}
