import Foundation

public struct LibraryQuery: Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        /// `system`: fonts under /System. `user`: fonts active outside Fontory (read-only here).
        /// `activated`: everything active on the Mac (system + user + Fontory's). `deactivated`: toggleable
        /// library fonts that are active nowhere.
        case all, system, user, activated, deactivated, offline, recentImport
        case location(id: Int64, subfolder: String?)
        case untagged, quickCollection
        case styleClass(StyleClass)
        /// Union of picks; a plain pick includes descendants' faces, an inverted one means faces without it.
        case tags([TagPick])
    }

    public enum Sort: Sendable, Hashable {
        case family, name, weight, dateAdded, lastActivated
        case random(seed: UInt64)
    }

    public var scope: Scope = .all
    public var search: SearchText? = nil
    public var includeSystem: Bool = true
    public var sort: Sort = .family
    public var ascending: Bool = true

    public init(scope: Scope = .all, includeSystem: Bool = true, sort: Sort = .family, ascending: Bool = true) {
        self.scope = scope
        self.includeSystem = includeSystem
        self.sort = sort
        self.ascending = ascending
    }
}

/// SQL for a face query: `columns` selected from faces JOIN files JOIN locations,
/// filtered by scope, ordered by sort. Shared by `faceIDs` and `families`.
extension LibraryQuery {
    static let effectiveFamily = "COALESCE(faces.custom_family, faces.family)"
    /// macOS's private faces (PostScript name starting with ".", e.g. ".SFNS-Regular") in system locations are never
    /// shown or counted. Shared with `FontStore.faceCountGroups`.
    static let publicFaceClause = "NOT (locations.kind = 2 AND substr(faces.postscript_name, 1, 1) = '.')"
    /// Ids of the tag bound as `?` and all its descendants.
    static let descendantsByID = "WITH RECURSIVE d(id) AS (SELECT ? UNION SELECT tags.id FROM tags JOIN d ON tags.parent_id = d.id) SELECT id FROM d"

    /// Active on the Mac: system, registered outside Fontory, or activated by Fontory. Shared by the `.activated`
    /// scope and the smart-tag "Activation" condition.
    static let activatedClause = "(locations.kind = 2 OR files.external_active != 0 OR locations.kind IN (0, 1) AND faces.activation != 0)"

    /// The single place a smart-tag pick is compiled.
    static func compileSmartRule(_ rule: SmartRule) -> (clause: String, bindings: [SQLValue]) {
        let c = rule.sqlClause()
        return (c.sql, c.bindings)
    }

    private static let randomModulus: UInt64 = 1_000_003

    static let fromJoin = "FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id"

    /// `SELECT COUNT(*)` over the same filter as `sql(columns:)`, without ordering.
    func countSQL() -> (sql: String, bindings: [SQLValue]) {
        let f = filter()
        return ("SELECT COUNT(*) \(Self.fromJoin) WHERE " + f.clauses.joined(separator: " AND "), f.bindings)
    }

    func sql(columns: String) -> (sql: String, bindings: [SQLValue]) {
        let (clauses, filterBindings) = filter()
        var bindings = filterBindings

        let dir = ascending ? "ASC" : "DESC"
        let order: String
        switch sort {
        case .family:
            order = "\(Self.effectiveFamily) COLLATE NOCASE \(dir), faces.weight \(dir), faces.width \(dir), faces.slant \(dir), faces.id \(dir)"
        case .name: order = "faces.full_name COLLATE NOCASE \(dir), faces.id \(dir)"
        case .weight: order = "faces.weight \(dir), \(Self.effectiveFamily) COLLATE NOCASE \(dir), faces.id \(dir)"
        case .dateAdded: order = "files.added_at \(dir), faces.id \(dir)"
        case .lastActivated: order = "faces.last_activated IS NULL, faces.last_activated \(dir), faces.id \(dir)"
        case .random(let seed):
            // Reduce the seed first so id * seed stays well inside Int64.
            // Bound, not interpolated, so every reshuffle reuses one cached statement.
            order = "(faces.id * ?) % \(Self.randomModulus) \(dir), faces.id \(dir)"
            bindings.append(.int(Int64(seed % Self.randomModulus)))
        }

        var sql = "SELECT \(columns) \(Self.fromJoin)"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY " + order
        return (sql, bindings)
    }

    /// WHERE clauses (never empty) and their bindings, shared by `sql(columns:)` and `countSQL()`.
    private func filter() -> (clauses: [String], bindings: [SQLValue]) {
        var clauses: [String] = [Self.publicFaceClause]
        var bindings: [SQLValue] = []

        switch scope {
        case .all: break
        // Kind 3 faces count as active only while registered (external_active), like library files.
        // Keep in step with `LibraryCounts.init(groups:includeSystem:)` and `FaceRow.activationStatus`.
        case .system: clauses.append("locations.kind = 2")
        case .user: clauses.append("files.external_active != 0 AND (locations.kind = 3 OR locations.kind IN (0, 1) AND faces.activation = 0)")
        case .activated: clauses.append(Self.activatedClause)
        case .deactivated: clauses.append("faces.activation = 0 AND files.external_active = 0 AND locations.kind IN (0, 1)")
        case .offline: clauses.append("locations.online = 0")
        case .recentImport: clauses.append("files.import_batch = (SELECT MAX(import_batch) FROM files)")
        case .location(let id, let subfolder):
            clauses.append("files.location_id = ?")
            bindings.append(.int(id))
            if let subfolder {
                // Prefix test without LIKE so '%' and '_' in folder names are literal.
                clauses.append("substr(files.relative_path, 1, length(?) + 1) = ? || '/'")
                bindings.append(.text(subfolder))
                bindings.append(.text(subfolder))
            }
        case .untagged:
            // Smart tags don't tag anything: only plain tags count.
            clauses.append("NOT EXISTS (SELECT 1 FROM face_tags JOIN tags ON tags.id = face_tags.tag_id WHERE face_tags.face_id = faces.id AND tags.kind = 0)")
        case .quickCollection: clauses.append("faces.id IN (SELECT face_id FROM quick_collection)")
        case .styleClass(let c):
            clauses.append("faces.style_class = ?")
            bindings.append(.int(Int64(c.rawValue)))
        case .tags(let picks):
            var ors: [String] = []
            for pick in picks {
                var clause: String
                if let rule = pick.rule {
                    let compiled = Self.compileSmartRule(rule)
                    clause = compiled.clause
                    bindings += compiled.bindings
                } else {
                    clause = "faces.id IN (SELECT face_id FROM face_tags WHERE tag_id IN (\(Self.descendantsByID)))"
                    bindings.append(.int(pick.tagID))
                }
                ors.append(pick.inverted ? "NOT (\(clause))" : "(\(clause))")
            }
            clauses.append(ors.isEmpty ? "0" : "(" + ors.joined(separator: " OR ") + ")")
        }
        // The System view itself ignores "show system fonts".
        if !includeSystem && scope != .system { clauses.append("locations.kind != 2") }
        if let search {
            if let match = search.ftsMatch {
                clauses.append("faces.id IN (SELECT rowid FROM faces_fts WHERE faces_fts MATCH ?)")
                bindings.append(.text(match))
            }
            let w = search.whereClauses(effectiveFamily: Self.effectiveFamily)
            clauses += w.clauses
            bindings += w.bindings
        }
        return (clauses, bindings)
    }
}
