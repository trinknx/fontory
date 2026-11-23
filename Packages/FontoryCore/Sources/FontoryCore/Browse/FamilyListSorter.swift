import Foundation

/// A precomputed per-face sort value for the family list's in-memory column sorts.
public enum FamilySortKey: Sendable, Hashable {
    case number(Double)
    /// Compared in natural (Finder) order. Empty text counts as missing.
    case text(String)
    /// No value: always sorted last.
    case none
}

/// Sorts a family list by a column the query cannot order: the faces of every family by their key, then the
/// families by their first face's key. Pure and nonisolated, so it runs off the main actor. Both sorts are
/// stable, and faces without a key sort last in either direction.
public enum FamilyListSorter {
    public static func sorted(_ groups: [FamilyGroup], keys: [Int64: FamilySortKey], ascending: Bool) -> [FamilyGroup] {
        func key(_ id: Int64) -> FamilySortKey {
            guard let k = keys[id] else { return .none }
            if case .text(let s) = k, s.isEmpty { return .none }
            return k
        }
        /// Strict "comes before"; ties are broken by the original position by the callers.
        func before(_ a: FamilySortKey, _ b: FamilySortKey) -> Bool {
            switch (a, b) {
            case (.none, _): return false
            case (_, .none): return true
            case let (.number(x), .number(y)): return ascending ? x < y : x > y
            case let (.text(x), .text(y)):
                let r = x.localizedStandardCompare(y)
                return ascending ? r == .orderedAscending : r == .orderedDescending
            // Mixed kinds do not occur within one column; keep numbers first for a total order.
            case (.number, .text): return true
            case (.text, .number): return false
            }
        }
        func stableSort<T>(_ items: [T], by k: (T) -> FamilySortKey) -> [T] {
            let keyed = items.enumerated().map { (offset: $0.offset, key: k($0.element), item: $0.element) }
            return keyed.sorted { x, y in
                if before(x.key, y.key) { return true }
                if before(y.key, x.key) { return false }
                return x.offset < y.offset
            }.map(\.item)
        }

        let facesSorted = groups.map { g -> FamilyGroup in
            var g = g
            g.faceIDs = stableSort(g.faceIDs, by: key)
            return g
        }
        return stableSort(facesSorted) { $0.faceIDs.first.map(key) ?? .none }
    }
}
