import Foundation

public struct LibraryQuery: Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        case all, activated, temporary, deactivated, offline, recentImport
        case location(id: Int64, subfolder: String?)
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
    private static let randomModulus: UInt64 = 1_000_003

    func sql(columns: String) -> (sql: String, bindings: [SQLValue]) {
        var clauses: [String] = []
        var bindings: [SQLValue] = []

        switch scope {
        case .all: break
        case .activated: clauses.append("faces.activation = 1")
        case .temporary: clauses.append("faces.activation = 2")
        case .deactivated: clauses.append("faces.activation = 0")
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
        }
        if !includeSystem { clauses.append("locations.kind != 2") }
        if let search {
            if let match = search.ftsMatch {
                clauses.append("faces.id IN (SELECT rowid FROM faces_fts WHERE faces_fts MATCH ?)")
                bindings.append(.text(match))
            }
            let w = search.whereClauses(effectiveFamily: Self.effectiveFamily)
            clauses += w.clauses
            bindings += w.bindings
        }

        let dir = ascending ? "ASC" : "DESC"
        let order: String
        switch sort {
        case .family:
            order = "\(Self.effectiveFamily) COLLATE NOCASE \(dir), faces.weight \(dir), faces.width \(dir), faces.slant \(dir), faces.id \(dir)"
        case .name: order = "faces.full_name COLLATE NOCASE \(dir), faces.id \(dir)"
        case .weight: order = "faces.weight \(dir), \(Self.effectiveFamily) COLLATE NOCASE \(dir), faces.id \(dir)"
        case .dateAdded: order = "files.added_at \(dir), faces.id \(dir)"
        case .lastActivated: order = "faces.last_activated \(dir), faces.id \(dir)"
        case .random(let seed):
            // Reduce the seed first so id * seed stays well inside Int64.
            let s = Int64(seed % Self.randomModulus)
            order = "(faces.id * \(s)) % \(Self.randomModulus) \(dir), faces.id \(dir)"
        }

        var sql = "SELECT \(columns) FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY " + order
        return (sql, bindings)
    }
}
