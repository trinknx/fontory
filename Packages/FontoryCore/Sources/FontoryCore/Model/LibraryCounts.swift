import Foundation

/// Face counts for the sidebar and the menu bar. Each count equals the number of faces the matching
/// `LibraryQuery.Scope` returns with the same `includeSystem`.
public struct LibraryCounts: Sendable, Equatable {
    public var all = 0
    public var system = 0
    public var user = 0
    public var activated = 0
    public var deactivated = 0
    /// Faces Fontory itself activated.
    public var fontoryActive = 0
    public var offline = 0
    public var lastImport = 0
    public var perLocation: [Int64: Int] = [:]

    public init() {}

    public init(groups: [FaceCountGroup], includeSystem: Bool) {
        for g in groups {
            perLocation[g.locationID, default: 0] += g.count
            let isSystem = g.kind == .system
            // The System view ignores "show system fonts" (as `LibraryQuery` does).
            if isSystem { system += g.count }
            if !includeSystem && isSystem { continue }
            let toggleable = g.kind == .folder || g.kind == .fileSet
            all += g.count
            if g.externalActive && (g.kind == .userInstalled || toggleable && g.activation == .off) { user += g.count }
            if isSystem || g.externalActive || toggleable && g.activation != .off { activated += g.count }
            if toggleable && g.activation == .off && !g.externalActive { deactivated += g.count }
            if toggleable && g.activation != .off { fontoryActive += g.count }
            if !g.online { offline += g.count }
            if g.inLatestImport { lastImport += g.count }
        }
    }
}
